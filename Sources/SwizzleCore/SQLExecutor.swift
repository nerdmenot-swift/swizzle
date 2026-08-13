/// Something that can run rendered SQL against a database.
///
/// The bridge between the query builder and a driver. Deliberately narrow: the
/// builder produces text plus an ordered binding list, and that is all an
/// executor needs. A driver conforms without knowing anything about the builder,
/// and the builder gains database access without depending on any driver.
///
/// ## Why `Dialect` is an associated type
///
/// It makes running a query on the wrong database a **compile** error rather
/// than a confusing runtime failure. A `SelectQuery<Postgres, …>` renders `$1`
/// placeholders and `"quoted"` identifiers; handing it to a MySQL connection
/// would produce a syntax error hundreds of milliseconds later, from the server,
/// with no indication that the dialect was the problem.
///
/// This is the same bet the capability protocols make — `.returning()` on MySQL
/// fails to compile — extended to the execution boundary.
public protocol SQLExecutor: Sendable {
    associatedtype Dialect: SQLDialect

    /// Runs a statement and returns every row.
    func execute(sql: String, bindings: [SQLValue]) async throws -> [SQLRow]

    /// Runs a statement that returns no rows, reporting how many it changed.
    @discardableResult
    func executeUpdate(sql: String, bindings: [SQLValue]) async throws -> Int

    /// This executor with its dialect forgotten.
    ///
    /// A **requirement** rather than only an extension method, and that is
    /// load-bearing: `SQLStreamingExecutor` supplies a better default that keeps
    /// the streaming path, and only a requirement dispatches to it. As a plain
    /// extension method it resolved statically to whichever protocol the *caller*
    /// named — so a bound query built through `SQLExecutor` lost the ability to
    /// stream even when the underlying driver could.
    var erased: AnySQLExecutor { get }
}

/// An executor that can also deliver rows as they arrive.
///
/// Separate from `SQLExecutor` because not every backend can stream — an
/// in-process SQLite driver has nothing to stream *from* — and a protocol that
/// forces a fake implementation is worse than two protocols.
public protocol SQLStreamingExecutor: SQLExecutor {
    associatedtype RowSequence: AsyncSequence & Sendable where RowSequence.Element == SQLRow

    func stream(sql: String, bindings: [SQLValue]) async throws -> RowSequence
}
