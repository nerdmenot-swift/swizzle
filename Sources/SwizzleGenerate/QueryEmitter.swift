import Foundation
import SwizzleCore

/// A query file's declaration joined to what the database said about it.
public struct ResolvedQuery: Sendable {
    public var declaration: ParsedQuery
    public var signature: QuerySignature
}

/// Emits Swift for analysed queries.
///
/// Emission is plain string building, following the `swizzle migrate embed`
/// precedent. swift-syntax would be the obvious alternative and is deliberately
/// not a dependency: it is a large build-time cost for a package already
/// sensitive to compile time, and generated code is written once and read often —
/// the shape is fixed, so there is nothing an AST buys here.
public struct QueryEmitter: Sendable {
    public struct Options: Sendable {
        public var accessLevel: String
        public var typeName: String
        /// The dialect the queries were generated against, rendered as its Swift
        /// type — `SQLite`, `Postgres`, `MySQL`, `MariaDB`.
        public var dialect: String
        public var imports: [String]

        public init(
            accessLevel: String = "public",
            typeName: String = "Queries",
            dialect: String,
            imports: [String] = ["SwizzleCore"]
        ) {
            self.accessLevel = accessLevel
            self.typeName = typeName
            self.dialect = dialect
            self.imports = imports
        }
    }

    let options: Options

    public init(options: Options) { self.options = options }

    public func emit(_ queries: [ResolvedQuery]) -> String {
        var out = SchemaEmitter.header.replacingOccurrences(
            of: "swizzle generate schema", with: "swizzle generate queries"
        )
        for name in options.imports.sorted() { out += "import \(name)\n" }
        out += "\n"

        for query in queries where rowStructIsNeeded(query) {
            out += rowStruct(for: query)
            out += "\n"
        }

        out += container()
        out += "\n"

        let streaming = queries.filter { $0.signature.cardinality == .stream }
        let direct = queries.filter { $0.signature.cardinality != .stream }

        out += "extension \(options.typeName) {\n"
        for query in direct { out += function(for: query) }
        out += "}\n"

        if !streaming.isEmpty {
            out += "\n"
            out += """
                // Streaming needs more of an executor than running does, so these live
                // behind the tighter constraint: a query declared `:stream` simply does
                // not exist on a backend that cannot stream, rather than failing when
                // it is called.
                extension \(options.typeName) where Executor: SQLStreamingExecutor {

                """
            for query in streaming { out += function(for: query) }
            out += "}\n"
        }
        return out
    }

    // MARK: - The container

    func container() -> String {
        """
        /// Every query in the directory, bound to one connection.
        ///
        /// Generic over the executor and pinned to the dialect these queries were
        /// analysed against, so handing them a connection to a different engine is a
        /// compile error rather than a syntax error from a server.
        \(options.accessLevel) struct \(options.typeName)<Executor: SQLExecutor>: Sendable
        where Executor.Dialect == \(options.dialect) {
            \(options.accessLevel) let executor: Executor

            \(options.accessLevel) init(_ executor: Executor) {
                self.executor = executor
            }
        }

        """
    }

    // MARK: - Row structs

    /// Whether this query needs a named row type at all.
    ///
    /// A single **non-optional** column is returned bare — `count()` rather than
    /// `count()?.n` — because there is nothing a wrapper would add. The
    /// non-optional part is load-bearing: for an optional column, `T?` would
    /// collapse "no row" and "a row holding null" into one value, so those keep
    /// their struct and stay distinguishable.
    func rowStructIsNeeded(_ query: ResolvedQuery) -> Bool {
        switch query.signature.cardinality {
        case .exec: false
        case .one, .many, .stream: !isBareScalar(query)
        }
    }

    func isBareScalar(_ query: ResolvedQuery) -> Bool {
        query.signature.columns.count == 1 && !query.signature.columns[0].isOptional
    }

    func rowTypeName(_ query: ResolvedQuery) -> String {
        SwiftNames.typeName(query.declaration.name) + "Row"
    }

    func rowStruct(for query: ResolvedQuery) -> String {
        let name = rowTypeName(query)
        var out = """
        /// One row of `\(query.declaration.name)`.
        \(options.accessLevel) struct \(name): Sendable {

        """
        for column in query.signature.columns {
            out += "    \(options.accessLevel) let \(SwiftNames.memberName(column.name)): "
            out += "\(typeText(column))\n"
        }

        out += "\n    \(options.accessLevel) init(row: SQLRow) throws {\n"
        for (index, column) in query.signature.columns.enumerated() {
            out += "        self.\(SwiftNames.memberName(column.name)) = "
            out += "try \(typeText(column))(sqlValue: row.values[\(index)])\n"
        }
        out += "    }\n}\n"
        return out
    }

    func typeText(_ column: ColumnInfo) -> String {
        column.swiftType.sourceText + (column.isOptional ? "?" : "")
    }

    // MARK: - Functions

    func function(for query: ResolvedQuery) -> String {
        let name = SwiftNames.memberName(query.declaration.name)
        let arguments = query.declaration.parameters
            .map { "\(SwiftNames.memberName($0.name)): \($0.type)" }
            .joined(separator: ", ")
        let bindings = query.declaration.parameters
            .map { "\(SwiftNames.memberName($0.name)).sqlValue" }
            .joined(separator: ", ")

        var out = "\n    /// `\(query.declaration.file)` — \(documentedShape(query))\n"
        out += "    \(options.accessLevel) func \(name)(\(arguments)) async throws -> "
        out += "\(returnType(query)) {\n"
        out += "        let bindings: [SQLValue] = [\(bindings)]\n"

        switch query.signature.cardinality {
        case .exec:
            out += "        return try await executor.executeUpdate(\n"
            out += "            sql: \(literal(query.signature.sql)), bindings: bindings\n        )\n"
        case .one:
            out += "        let rows = try await executor.execute(\n"
            out += "            sql: \(literal(query.signature.sql)), bindings: bindings\n        )\n"
            out += "        guard let row = rows.first else { return nil }\n"
            out += "        return \(decodeExpression(query, row: "row"))\n"
        case .many:
            out += "        let rows = try await executor.execute(\n"
            out += "            sql: \(literal(query.signature.sql)), bindings: bindings\n        )\n"
            out += "        return try rows.map { row in \(decodeExpression(query, row: "row")) }\n"
        case .stream:
            out += "        let rows = try await executor.stream(\n"
            out += "            sql: \(literal(query.signature.sql)), bindings: bindings\n        )\n"
            out += "        return rows.map { row in \(decodeExpression(query, row: "row")) }\n"
        }
        out += "    }\n"
        return out
    }

    func documentedShape(_ query: ResolvedQuery) -> String {
        switch query.signature.cardinality {
        case .one: "at most one row"
        case .many: "every matching row"
        case .stream: "rows as they arrive, in bounded memory"
        case .exec: "rows affected"
        }
    }

    func returnType(_ query: ResolvedQuery) -> String {
        switch query.signature.cardinality {
        case .exec:
            return "Int"
        case .one:
            return isBareScalar(query)
                ? "\(typeText(query.signature.columns[0]))?"
                : "\(rowTypeName(query))?"
        case .many:
            return isBareScalar(query)
                ? "[\(typeText(query.signature.columns[0]))]"
                : "[\(rowTypeName(query))]"
        case .stream:
            let element = isBareScalar(query)
                ? typeText(query.signature.columns[0])
                : rowTypeName(query)
            // The concrete type `map` returns, rather than an opaque
            // `some AsyncSequence<…>`.
            //
            // This emitted `some AsyncSequence<\(element), any Error>` until the
            // generated code was put in front of a compiler for the first time,
            // and that does not build on this package's own floor: `Failure` is
            // the typed-throws associated type, `@available(macOS 15)`, while the
            // package targets macOS 14. Dropping to one parameter does not work
            // either — under Swift 6 `AsyncSequence` has two primary associated
            // types and a constrained existential must supply both — so the
            // opaque form is simply unavailable below macOS 15.
            //
            // Nothing caught it because the only test compared the emitter's
            // output to a string, which tests that the emitter agrees with
            // itself. `AsyncThrowingMapSequence` is what the body already
            // produces, it is as old as `AsyncSequence`, and it still does not
            // name the driver's type — `Executor.RowSequence` stays abstract.
            return "AsyncThrowingMapSequence<Executor.RowSequence, \(element)>"
        }
    }

    func decodeExpression(_ query: ResolvedQuery, row: String) -> String {
        isBareScalar(query)
            ? "try \(typeText(query.signature.columns[0]))(sqlValue: \(row).values[0])"
            : "try \(rowTypeName(query))(row: \(row))"
    }

    /// A raw string literal with enough hashes to hold the SQL, however many
    /// quotes it contains. Lifted from the `migrate embed` emitter, which had the
    /// same problem first.
    func literal(_ text: String) -> String {
        var hashes = 1
        while text.contains("\"" + String(repeating: "#", count: hashes)) { hashes += 1 }
        let pad = String(repeating: "#", count: hashes)
        return "\(pad)\"\"\"\n        \(text.replacingOccurrences(of: "\n", with: "\n        "))\n        \"\"\"\(pad)"
    }
}
