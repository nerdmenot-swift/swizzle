import NIOCore

/// The ergonomic surface: interpolated queries in, typed values out.
///
/// `query(_:)` and `execute(_:)` split the same way they do in node-mysql2 and
/// `mysql_async` (`query` vs `exec`): `query` takes a `String` and goes out as
/// text, `execute` takes a ``MySQLQuery`` and goes out as a prepared statement
/// with its values bound. The naming is theirs because it is already the thing
/// people expect, and keeping the two types distinct means a string literal
/// never silently picks the wrong one.
///
/// Everything here is built on the existing `query`/`stream` primitives, which
/// stay exactly as they were for callers holding SQL they have already built.
extension MySQLConnection {

    // MARK: - Buffered

    /// Runs an interpolated query and returns its first result set.
    ///
    /// ```swift
    /// let result = try await connection.execute("SELECT name FROM users WHERE id = \(id)")
    /// ```
    @discardableResult
    public func execute(_ query: MySQLQuery) async throws -> MySQLQueryResult {
        query.binds.isEmpty
            ? try await self.query(query.sql)
            : try await self.query(query.sql, query.binds)
    }

    /// Runs an interpolated query and decodes every row into a typed tuple.
    ///
    /// ```swift
    /// let users = try await connection.execute(
    ///     "SELECT id, name, email FROM users WHERE active = \(true)",
    ///     as: (Int, String, String?).self
    /// )
    /// ```
    ///
    /// This is `mysql_async`'s `exec` with a `FromRow` bound, and the reason
    /// that API is pleasant: the shape of the result is stated once, at the call
    /// site, and the rows arrive already destructurable.
    public func execute<each T: MySQLDecodable>(
        _ query: MySQLQuery, as types: (repeat each T).Type
    ) async throws -> [(repeat each T)] {
        let result = try await execute(query)
        return try result.rows.map { try $0.decode(repeat (each T).self) }
    }

    /// The first row, or `nil` when there were none.
    ///
    /// `mysql_async` calls this `exec_first`, Go calls it `QueryRow`, PyMySQL
    /// `fetchone`. It exists in all of them because "look up one row by its key"
    /// is the most common query anyone writes, and `.rows.first` plus a decode
    /// is a lot of ceremony for it.
    public func executeFirst<each T: MySQLDecodable>(
        _ query: MySQLQuery, as types: (repeat each T).Type
    ) async throws -> (repeat each T)? {
        let result = try await execute(query)
        guard let row = result.rows.first else { return nil }
        // Bound to a local first: returning a pack expansion straight into an
        // optional leaves the shape ambiguous to the type checker.
        let decoded: (repeat each T) = try row.decode(repeat (each T).self)
        return decoded
    }

    /// The first row, undecoded.
    public func executeFirst(_ query: MySQLQuery) async throws -> MySQLRow? {
        try await execute(query).rows.first
    }

    /// Rows affected, for statements that do not return any.
    ///
    /// Named for what it answers, so an `UPDATE` reads as
    /// `let changed = try await connection.executeUpdate(...)` rather than
    /// reaching into a result set that has no rows in it.
    @discardableResult
    public func executeUpdate(_ query: MySQLQuery) async throws -> Int {
        Int(try await execute(query).affectedRows)
    }

    /// The `AUTO_INCREMENT` value the server assigned to an insert.
    @discardableResult
    public func executeInsert(_ query: MySQLQuery) async throws -> UInt64 {
        try await execute(query).lastInsertID
    }

    // MARK: - Streaming

    /// Streams an interpolated query's rows under backpressure.
    ///
    /// The same bounded-memory guarantee as ``stream(_:)`` — a result set larger
    /// than memory streams in constant space — with the values bound rather than
    /// interpolated into the SQL.
    public func stream(_ query: MySQLQuery) async throws -> MySQLRowSequence {
        query.binds.isEmpty
            ? try await stream(query.sql)
            : try await stream(query.sql, query.binds)
    }

    /// Streams rows decoded into typed tuples, handing each to `body` as it
    /// arrives.
    ///
    /// A callback rather than an `AsyncSequence` for the same reason
    /// `SelectQuery.forEach(on:)` is: an `AsyncSequence` whose `Element` is a
    /// pack expansion — `(repeat each T)` — cannot be iterated by Swift 6.1,
    /// which is the current Linux toolchain. It compiles and then fails at every
    /// use site. A closure parameter *is* a function argument list, so this form
    /// works on both.
    ///
    /// Backpressure is untouched: `body` runs per row as it arrives, so a result
    /// set larger than memory still streams in bounded space.
    public func forEach<each T: MySQLDecodable>(
        _ query: MySQLQuery,
        as types: (repeat each T).Type,
        _ body: (repeat each T) async throws -> Void
    ) async throws {
        for try await row in try await stream(query) {
            try await body(repeat each row.decode(repeat (each T).self))
        }
    }

    // MARK: - Batch

    /// Runs one statement over many parameter sets, in a single round trip where
    /// the server supports it.
    ///
    /// `mysql_async` calls this `exec_batch` and PyMySQL `executemany`. On
    /// MariaDB this uses `COM_STMT_BULK_EXECUTE`; elsewhere it reuses one
    /// prepared statement, which is still far cheaper than re-preparing.
    @discardableResult
    public func executeBatch(
        _ sql: String, rows: [[MySQLValue]]
    ) async throws -> [MySQLQueryResult] {
        guard !rows.isEmpty else { return [] }
        if supportsBulkExecute {
            let statement = try await prepare(sql)
            return try await executeBulk(statement, rows: rows)
        }
        return try await queryBulk(sql, rows: rows)
    }
}
