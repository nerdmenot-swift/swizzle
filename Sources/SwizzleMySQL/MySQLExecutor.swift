import NIOCore
import SwizzleCore
import SwizzleQuery

/// Runs `SwizzleQuery`-built statements on a MySQL or MariaDB connection.
///
/// ## Why this is generic over the dialect
///
/// `MySQL` and `MariaDB` are *different* dialects — MariaDB has `RETURNING`,
/// MySQL does not — but they are the same wire protocol and the same connection
/// type. The dialect therefore has to be chosen at compile time while the actual
/// server flavour is only known at runtime, and the two must agree or the
/// capability protocols become decoration.
///
/// So the executor is obtained from a connection through ``MySQLConnection/executor(_:)``,
/// which checks the flavour and throws on mismatch. After that the type system
/// carries it: a `SelectQuery<MariaDB, …>` cannot be run on a `MySQL` executor,
/// and `.returning()` cannot even be written against MySQL.
public struct MySQLExecutor<Dialect: SQLDialect>: SQLExecutor, SQLStreamingExecutor {

    public let connection: MySQLConnection

    // `query`, `select`, `insert`, `update`, `delete` and `raw` used to live
    // here. They now come from `SQLExecutor` in SwizzleQuery, which means two
    // things this version could not do: Postgres gets them too, and the query
    // they return remembers this connection — so the executor no longer has to
    // be handed back at the end of the chain.

    init(connection: MySQLConnection) {
        self.connection = connection
    }

    public func execute(sql: String, bindings: [SQLValue]) async throws -> [SQLRow] {
        // No bindings means no prepared statement: a plain COM_QUERY avoids the
        // prepare/execute round trip entirely, which matters for the DDL and
        // constant queries that make up much of a migration.
        let result = bindings.isEmpty
            ? try await connection.query(sql)
            : try await connection.query(sql, bindings.map(MySQLValue.init(sqlValue:)))
        return result.rows.map(Self.bridge)
    }

    /// Converts a driver row using its **column metadata**, not the bytes alone.
    ///
    /// `MySQLValue.sqlValue` has to guess `.text` vs `.blob` from whether the
    /// bytes happen to be valid UTF-8, and that guess is wrong for real binary
    /// data: `[0x01, 0x02, 0x03]` is perfectly good UTF-8, so a BLOB came back
    /// as `.text`. The server already tells us — character set 63 is `binary` —
    /// so the row-level bridge uses that and only falls back to guessing when a
    /// column definition is missing.
    static func bridge(_ row: MySQLRow) -> SQLRow {
        SQLRow(values: row.values.enumerated().map { index, value in
            guard index < row.columns.count, row.columns[index].isBinary,
                  case .bytes(let bytes) = value
            else { return value.sqlValue }
            return .blob(bytes)
        })
    }

    @discardableResult
    public func executeUpdate(sql: String, bindings: [SQLValue]) async throws -> Int {
        let result = bindings.isEmpty
            ? try await connection.query(sql)
            : try await connection.query(sql, bindings.map(MySQLValue.init(sqlValue:)))
        return Int(result.affectedRows)
    }

    /// Streams a query's rows under backpressure.
    ///
    /// Parameterised queries stream through a prepared statement and the binary
    /// protocol; unparameterised ones go straight out as `COM_QUERY`. The
    /// distinction is invisible to the caller and deliberately so — a builder
    /// emits a `WHERE` clause with bindings for almost every real query, and
    /// having those fall back to text would either mean interpolating values
    /// into SQL or refusing to stream at all.
    public func stream(sql: String, bindings: [SQLValue]) async throws -> MySQLSQLRowSequence {
        let base = bindings.isEmpty
            ? try await connection.stream(sql)
            : try await connection.stream(sql, bindings.map(MySQLValue.init(sqlValue:)))
        return MySQLSQLRowSequence(base: base)
    }
}

/// Adapts the driver's row sequence to the dialect-neutral `SQLRow`.
public struct MySQLSQLRowSequence: AsyncSequence, Sendable {
    public typealias Element = SQLRow

    let base: MySQLRowSequence

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: MySQLRowSequence.AsyncIterator

        public mutating func next() async throws -> SQLRow? {
            guard let row = try await base.next() else { return nil }
            return MySQLExecutor<MySQL>.bridge(row)
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: base.makeAsyncIterator())
    }
}

extension MySQLValue {
    /// Bridges a dialect-neutral value into a bind parameter.
    ///
    /// `bool` becomes an integer because MySQL has no boolean type — `BOOL` is
    /// an alias for `TINYINT(1)` — so round-tripping through 0/1 is what the
    /// server does anyway.
    public init(sqlValue: SQLValue) {
        switch sqlValue {
        case .null: self = .null
        case .bool(let value): self = .int(value ? 1 : 0)
        case .int(let value): self = .int(value)
        case .double(let value): self = .double(value)
        case .text(let value): self = .bytes(Array(value.utf8))
        case .blob(let value): self = .bytes(value)
        }
    }
}

extension MySQLConnection {

    /// A typed executor for this connection.
    ///
    /// Checks that the chosen dialect matches the server actually connected to.
    /// Without that check the capability protocols would be a fiction: a
    /// `MariaDB`-typed query using `RETURNING` would compile happily and then
    /// fail on a MySQL server at runtime, which is precisely the failure mode
    /// the type-level design exists to prevent.
    public func executor<Dialect: SQLDialect>(
        _ dialect: Dialect.Type = Dialect.self
    ) throws -> MySQLExecutor<Dialect> {
        let wantsMariaDB = dialect == MariaDB.self
        let wantsMySQL = dialect == MySQL.self

        guard wantsMariaDB || wantsMySQL else {
            throw MySQLProtocolError.unexpectedPacket(
                "\(dialect) is not a MySQL-family dialect"
            )
        }
        guard wantsMariaDB == metadata.isMariaDB else {
            throw MySQLProtocolError.unexpectedPacket(
                "connected to \(metadata.isMariaDB ? "MariaDB" : "MySQL") "
                + "but asked for the \(dialect) dialect"
            )
        }
        return MySQLExecutor(connection: self)
    }

    /// The executor matching whichever server this actually is.
    ///
    /// Convenient, but it hands back an existential rather than a concrete type,
    /// so the compile-time dialect checking is lost. Prefer `executor(MariaDB.self)`
    /// when the target is known — which it usually is.
    public var anyExecutor: any SQLExecutor {
        metadata.isMariaDB
            ? MySQLExecutor<MariaDB>(connection: self)
            : MySQLExecutor<MySQL>(connection: self)
    }
}

// MARK: - Pool and transactions

extension MySQLClient {

    /// Borrows a connection from the pool and hands it to `body` as a typed
    /// executor.
    ///
    /// This is the surface an application actually uses: a pool, not a raw
    /// connection. The dialect is checked once per borrow, so a pool pointed at
    /// MySQL cannot serve `MariaDB`-typed queries even though the connections
    /// are interchangeable.
    public func withExecutor<Dialect: SQLDialect, Result: Sendable>(
        _ dialect: Dialect.Type = Dialect.self,
        _ body: @Sendable (MySQLExecutor<Dialect>) async throws -> Result
    ) async throws -> Result {
        try await withConnection { connection in
            try await body(try connection.executor(dialect))
        }
    }

    /// Borrows a connection, opens a transaction, and hands it over as a typed
    /// executor. Rolls back if `body` throws.
    public func withTransaction<Dialect: SQLDialect, Result: Sendable>(
        _ dialect: Dialect.Type = Dialect.self,
        options: MySQLTransactionOptions = .default,
        _ body: @Sendable (MySQLExecutor<Dialect>) async throws -> Result
    ) async throws -> Result {
        try await withConnection { connection in
            try await connection.withTransaction(options) { transactional in
                try await body(try transactional.executor(dialect))
            }
        }
    }
}

extension MySQLExecutor {
    /// Runs `body` inside a transaction on this executor's connection.
    ///
    /// The executor handed to `body` is a *different* value bound to the same
    /// connection, which is what keeps the transactional scope explicit rather
    /// than implied by whichever executor happened to be in scope.
    public func withTransaction<Result: Sendable>(
        _ options: MySQLTransactionOptions = .default,
        _ body: @Sendable (MySQLExecutor<Dialect>) async throws -> Result
    ) async throws -> Result {
        try await connection.withTransaction(options) { transactional in
            try await body(MySQLExecutor<Dialect>(connection: transactional))
        }
    }
}
