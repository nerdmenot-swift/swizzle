import Testing
@testable import Swizzle

private struct Jobs: SQLTable {
    static let tableName = "jobs"
    var tableAlias: String?
    var id: SQLColumn<Int64> { bigInt("id") }
    var state: SQLColumn<String> { varchar("state", 20) }
    var payload: SQLColumn<String> { text("payload") }
    var runAt: SQLColumn<String> { timestamp("run_at") }
}

private struct Archive: SQLTable {
    static let tableName = "jobs_archive"
    var tableAlias: String?
    var id: SQLColumn<Int64> { bigInt("id") }
    var payload: SQLColumn<String> { text("payload") }
}

private let j = Jobs()
private let a = Archive()

// MARK: - Row locking

/// The queue-worker pattern, which was previously impossible without rewriting
/// the whole statement as raw text.
@Test func forUpdateSkipLockedRendersAfterLimit() {
    let q = QueryBuilder<Postgres>()
        .select(j.id, j.payload)
        .from(j)
        .where(j.state == "pending")
        .limit(1)
        .forUpdate(.skipLocked)

    #expect(q.sql.hasSuffix("LIMIT $2 FOR UPDATE SKIP LOCKED"))
}

@Test func lockingRendersOnTheMySQLFamilyToo() {
    let q = QueryBuilder<MySQL>().select(j.id).from(j).forUpdate(.noWait)
    #expect(q.sql.hasSuffix("FOR UPDATE NOWAIT"))

    let shared = QueryBuilder<MariaDB>().select(j.id).from(j).forShare()
    #expect(shared.sql.hasSuffix("FOR SHARE"))
    // The default wait mode adds nothing — older servers have no NOWAIT at all.
    #expect(!shared.sql.contains("NOWAIT"))
}

@Test func postgresWeakerLockModesAreGatedToPostgres() {
    let q = QueryBuilder<Postgres>().select(j.id).from(j).forKeyShare()
    #expect(q.sql.hasSuffix("FOR KEY SHARE"))
    // `.forNoKeyUpdate()` and `.forKeyShare()` do not exist on MySQL, and no
    // locking method at all exists on SQLite — its locking is whole-database.
}

// MARK: - INSERT … SELECT

@Test func insertFromSelectReplacesTheValuesList() {
    let q = QueryBuilder<Postgres>()
        .insert(into: a)
        .columns(a.id, a.payload)
        .select(QueryBuilder<Postgres>().select(j.id, j.payload).from(j).where(j.state == "done"))

    #expect(q.sql == #"INSERT INTO "jobs_archive" ("id", "payload") SELECT "jobs"."id", "jobs"."payload" FROM "jobs" WHERE "jobs"."state" = $1"#)
    #expect(q.bindings == [.text("done")])
    #expect(!q.sql.contains("VALUES"))
}

@Test func insertFromSelectComposesWithUpsert() {
    let q = QueryBuilder<Postgres>()
        .insert(into: a)
        .columns(a.id, a.payload)
        .select(QueryBuilder<Postgres>().select(j.id, j.payload).from(j))
        .onConflict(a.id)
        .doNothing()

    #expect(q.sql.hasSuffix(#"ON CONFLICT ("id") DO NOTHING"#))
}

// MARK: - Sources that are not tables

@Test func fromAFragmentSupportsTableValuedFunctions() {
    let n = SQLExpression<Int64>(.column(qualifier: nil, name: "n"))
    let q = QueryBuilder<Postgres>()
        .select(n)
        .from(sql: "generate_series(1, \(100))", as: "n")

    #expect(q.sql == #"SELECT "n" FROM generate_series(1, $1) AS "n""#)
    #expect(q.bindings == [.int(100)])
}

// MARK: - The remaining joins

@Test func rightAndCrossJoinsRender() {
    #expect(QueryBuilder<Postgres>().select(j.id).from(j)
        .rightJoin(a, on: a.id == j.id).sql.contains("RIGHT JOIN"))

    let cross = QueryBuilder<Postgres>().select(j.id).from(j).crossJoin(a)
    #expect(cross.sql.contains("CROSS JOIN"))
    // CROSS JOIN takes no ON, and must not render a dangling one.
    #expect(!cross.sql.contains(" ON "))
}

@Test func subqueriesCanBeJoined() {
    let recent = QueryBuilder<Postgres>().select(j.id).from(j).where(j.state == "done")
    let q = QueryBuilder<Postgres>()
        .select(a.id)
        .from(a)
        .leftJoin(recent, as: "r", on: a.id == j.id)

    #expect(q.sql.contains(#"LEFT JOIN (SELECT "jobs"."id" FROM "jobs" WHERE "jobs"."state" = $1) AS "r" ON"#))
}

// MARK: - The general escape

/// The guarantee: anything not modelled still does not require a rewrite.
@Test func appendingPutsVerbatimSQLAfterEverythingElse() {
    let q = QueryBuilder<MySQL>()
        .select(j.id)
        .from(j)
        .where(j.state == "pending")
        .limit(10)
        .appending("FOR UPDATE OF \(identifier: "jobs")")

    #expect(q.sql.hasSuffix("LIMIT ? FOR UPDATE OF `jobs`"))
}

/// Interpolation inside a trailing fragment still binds, so the escape hatch is
/// not also an injection.
@Test func appendingStillBinds() {
    let q = QueryBuilder<Postgres>()
        .select(j.id).from(j)
        .appending("FOR UPDATE OF \(identifier: "jobs") LIMIT \(42)")
    #expect(q.bindings == [.int(42)])
}

/// A value interpolated into a comment is refused before it reaches the server.
///
/// This used to be documented and left as a trap: the placeholder went into a
/// position the server ignores, the value was still sent, and the driver replied
/// *"statement expects 1 parameters, got 2"* — an error naming neither the query
/// nor the interpolation. Now the render refuses it and says what to do instead.
@Test func aValueBoundInsideACommentIsRefused() async {
    let q = QueryBuilder<Postgres>().select(j.id).from(j).appending("/* tenant \(42) */")

    #expect(throws: SQLBindingInDeadPosition.self) { _ = try q.buildChecked() }
    await #expect(throws: SQLBindingInDeadPosition.self) { _ = try await q.fetch(on: NullExecutor()) }

    // The message has to be actionable, since the driver's was not.
    do {
        _ = try q.buildChecked()
    } catch let error as SQLBindingInDeadPosition {
        #expect(error.count == 1)
        #expect(error.description.contains("inline:"))
    } catch {
        Issue.record("wrong error: \(error)")
    }
}

/// Inside a string literal, for the same reason.
@Test func aValueBoundInsideAStringLiteralIsRefused() {
    let q = QueryBuilder<Postgres>().select(j.id).from(j)
        .where(sql("\(j.state) = 'pending \(1)'"))
    #expect(throws: SQLBindingInDeadPosition.self) { _ = try q.buildChecked() }
}

/// `\(inline:)` is the form that belongs there, and it passes.
@Test func inlineIsTheFormThatBelongsInAComment() throws {
    let q = QueryBuilder<Postgres>().select(j.id).from(j).appending("/* tenant \(inline: 42) */")
    let (sql, bindings) = try q.buildChecked()
    #expect(bindings.isEmpty)
    #expect(sql.hasSuffix("/* tenant 42 */"))
}

/// The lexer has to *close* comments and strings too, or every binding after one
/// would be flagged.
@Test func bindingsAfterAClosedCommentAreFine() throws {
    let q = QueryBuilder<Postgres>()
        .select(j.id).from(j)
        .where(sql("/* note */ \(j.state) = \("done") AND \(j.id) > \(5)"))
    let (_, bindings) = try q.buildChecked()
    #expect(bindings == [.text("done"), .int(5)])
}

/// A line comment ends at the newline, not at the end of the fragment.
@Test func lineCommentsCloseAtTheNewline() throws {
    let q = QueryBuilder<Postgres>()
        .select(j.id).from(j)
        .where(sql("-- why\n\(j.id) = \(7)"))
    let (_, bindings) = try q.buildChecked()
    #expect(bindings == [.int(7)])
}

/// Accepts everything, so the test exercises the render rather than a driver.
private struct NullExecutor: SQLExecutor {
    typealias Dialect = Postgres
    func execute(sql: String, bindings: [SQLValue]) async throws -> [SQLRow] { [] }
    func executeUpdate(sql: String, bindings: [SQLValue]) async throws -> Int { 0 }
}

@Test func appendingWorksOnEveryStatementKind() {
    #expect(QueryBuilder<MySQL>().update(j).set(j.state, to: "x")
        .appending("/* hint */").sql.hasSuffix("/* hint */"))
    #expect(QueryBuilder<MySQL>().delete(from: j)
        .appending("/* hint */").sql.hasSuffix("/* hint */"))
    #expect(QueryBuilder<MySQL>().insert(into: a).values { $0.set(a.id, to: 1) }
        .appending("/* hint */").sql.hasSuffix("/* hint */"))
}

// MARK: - Things that were never blocked, confirmed

/// Window functions, CASE, CAST and ROLLUP need no dedicated API: a fragment is
/// an expression, and expressions compose. Worth pinning so nobody "fixes" it by
/// adding a builder for each.
@Test func expressionShapedSQLGoesInAsAFragment() {
    let rank = sql("ROW_NUMBER() OVER (PARTITION BY \(j.state) ORDER BY \(j.runAt) DESC)", as: Int64.self)
    let bucket = sql("CASE WHEN \(j.state) = \("done") THEN 1 ELSE 0 END", as: Int64.self)

    let q = QueryBuilder<Postgres>()
        .select(j.id, rank, bucket)
        .from(j)
        .groupBy(sql("ROLLUP(\(j.state))", as: Int64.self))
        .orderBy(rank.desc)

    #expect(q.sql.contains("ROW_NUMBER() OVER (PARTITION BY"))
    #expect(q.sql.contains("CASE WHEN"))
    #expect(q.sql.contains("GROUP BY ROLLUP("))
    #expect(q.bindings == [.text("done")])
}

/// The dead-binding lexer must not cry wolf.
///
/// It refuses a value bound inside a comment or a string. The risk of any such
/// check is the other direction — flagging something legitimate — and an
/// apostrophe inside a comment is the obvious way to trip it, since `'` outside
/// a comment does open a string.
@Test func theDeadBindingCheckDoesNotFlagLegitimateSQL() throws {
    // An apostrophe inside a comment is not a string.
    let contraction = QueryBuilder<Postgres>()
        .select(j.id).from(j)
        .appending("/* don't reorder this */")
        .where(j.id == 1)
    #expect(try contraction.buildChecked().bindings == [.int(1)])

    // A quoted literal that opens and closes leaves the lexer where it started.
    let quoted = QueryBuilder<Postgres>()
        .select(j.id).from(j)
        .where(sql("json_extract(\(j.payload), '$.a') = \(1)"))
    #expect(try quoted.buildChecked().bindings == [.int(1)])

    // A doubled quote inside a literal toggles twice and nets out.
    let doubled = QueryBuilder<Postgres>()
        .select(j.id).from(j)
        .where(sql("\(j.state) = 'O''Brien' AND \(j.id) > \(2)"))
    #expect(try doubled.buildChecked().bindings == [.int(2)])

    // A line comment ends at its newline, not at the end of the statement.
    let lineComment = QueryBuilder<Postgres>()
        .select(j.id).from(j)
        .where(sql("-- why not\n\(j.id) = \(3)"))
    #expect(try lineComment.buildChecked().bindings == [.int(3)])
}
