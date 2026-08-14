import Foundation
import SwizzleCore

/// Joins what the author declared to what the database reported.
///
/// The analyzers deliberately know nothing about query files — they take SQL and
/// return a shape. Everything that comes from the file rather than the server
/// lands here: the query's name, its cardinality, its parameter declarations, and
/// the `NotNull`/`Nullable` overrides. Keeping that split means the analyzers stay
/// testable against raw SQL, which is how the SQLite one got shaken out before any
/// of this existed.
public struct QueryGenerator: Sendable {
    let analyzer: any QueryAnalyzer

    public init(analyzer: any QueryAnalyzer) {
        self.analyzer = analyzer
    }

    public func resolve(_ queries: [ParsedQuery]) async throws -> [ResolvedQuery] {
        defer { Task { await analyzer.finish() } }

        var resolved: [ResolvedQuery] = []
        for query in queries {
            var signature: QuerySignature
            do {
                signature = try await analyzer.analyze(query.sql)
            } catch let error as QueryAnalysisError {
                // Re-thrown with the file and line, because "cannot describe
                // query" without one is useless in a directory of thirty.
                throw QueryParseError(
                    file: query.file, line: query.line,
                    reason: "\(query.name): \(error.reason)"
                )
            }

            signature.name = query.name
            signature.cardinality = query.cardinality
            signature.parameters = try Self.merge(
                declared: query.parameters, discovered: signature.parameters, query: query
            )
            signature.columns = try Self.applyOverrides(to: signature.columns, from: query)
            resolved.append(ResolvedQuery(declaration: query, signature: signature))
        }
        return resolved
    }

    /// The author's declaration is the source of parameter names and types; the
    /// database is the source of how many there are.
    ///
    /// Only Postgres can type parameters at all, so the check that matters most is
    /// the arity one — and getting that wrong produces a statement the server
    /// rejects at runtime with a count mismatch, which is exactly the error this
    /// turns into a generation-time one naming the file.
    static func merge(
        declared: [DeclaredParameter], discovered: [ParameterInfo], query: ParsedQuery
    ) throws -> [ParameterInfo] {
        guard declared.count == discovered.count else {
            throw QueryParseError(
                file: query.file, line: query.line,
                reason: "query '\(query.name)' declares \(declared.count) parameter"
                    + "\(declared.count == 1 ? "" : "s") but the SQL has \(discovered.count) "
                    + "placeholder\(discovered.count == 1 ? "" : "s")"
            )
        }

        return zip(declared, discovered).map { declaration, found in
            var parameter = found
            parameter.name = declaration.name
            // The declared Swift type wins: it is the only one on MySQL and
            // SQLite, and on Postgres a mismatch would be caught by the compiler
            // at the call site anyway.
            parameter.source = found.swiftType == .unresolved ? .declared : .verified
            return parameter
        }
    }

    /// Applies `NotNull` / `Nullable` / `Type`, and refuses one that names nothing.
    ///
    /// A typo in an override is silent otherwise — the column keeps whatever the
    /// engine said, and the author believes they fixed it.
    static func applyOverrides(
        to columns: [ColumnInfo], from query: ParsedQuery
    ) throws -> [ColumnInfo] {
        let names = Set(columns.map(\.name))
        let overridden = query.notNull.union(query.nullable)
            .union(query.types.keys)
        for override in overridden where !names.contains(override) {
            throw QueryParseError(
                file: query.file, line: query.line,
                reason: "query '\(query.name)' has no column '\(override)' to override — "
                    + "it returns \(names.sorted().map { "'\($0)'" }.joined(separator: ", "))"
            )
        }
        if let both = query.notNull.intersection(query.nullable).first {
            throw QueryParseError(
                file: query.file, line: query.line,
                reason: "column '\(both)' is declared both NotNull and Nullable"
            )
        }

        return columns.map { column in
            var column = column
            // Applied first, so an explicit `NotNull`/`Nullable` below still wins
            // over the optionality implied by the spelling.
            if let declared = query.types[column.name] {
                column.swiftType = declared.type
                column.isOptional = declared.isOptional
                column.nullability = declared.isOptional
                    ? .annotationNullable : .annotationNotNull
            }
            if query.notNull.contains(column.name) {
                column.isOptional = false
                column.nullability = .annotationNotNull
            } else if query.nullable.contains(column.name) {
                column.isOptional = true
                column.nullability = .annotationNullable
            }
            return column
        }
    }
}
