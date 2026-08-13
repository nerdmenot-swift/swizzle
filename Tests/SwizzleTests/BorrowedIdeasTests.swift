import Foundation
import Testing
@testable import Swizzle

private struct Docs: SQLTable {
    static let tableName = "docs"
    var tableAlias: String?
    var id: SQLColumn<Int64> { bigInt("id") }
    var title: SQLColumn<String> { varchar("title", 200) }
    var body: SQLColumn<String> { text("body") }
    var tags: SQLColumn<String> { jsonb("tags") }
    var views: SQLColumn<Int64> { int("views") }
}

private let d = Docs()

// MARK: - Raw SQL with ? placeholders (red line 4)

/// The path for SQL you already have, rather than SQL you write into an
/// interpolation.
@Test func rawSQLTakesQuestionMarkPlaceholders() {
    let q = QueryBuilder<MySQL>()
        .raw("SELECT id FROM docs WHERE views > ? AND title = ?", [.int(100), .text("Ada")])

    #expect(q.sql == "SELECT id FROM docs WHERE views > ? AND title = ?")
    #expect(q.bindings == [.int(100), .text("Ada")])
}

/// The bit none of the libraries this was modelled on will do: `?` is the
/// placeholder everywhere, and Postgres gets `$1` on the way out.
@Test func questionMarksAreRenumberedForPostgres() {
    let q = QueryBuilder<Postgres>()
        .raw("SELECT id FROM docs WHERE views > ? AND title = ?", [.int(100), .text("Ada")])

    #expect(q.sql == "SELECT id FROM docs WHERE views > $1 AND title = $2")
    #expect(q.bindings == [.int(100), .text("Ada")])
    #expect(q.debugSQL == "SELECT id FROM docs WHERE views > 100 AND title = 'Ada'")
}

/// A `?` inside a string literal is not a placeholder. Getting this wrong is
/// silent in both directions, which is why the scan tracks quoting at all.
@Test func questionMarksInsideLiteralsAreLeftAlone() {
    let q = QueryBuilder<Postgres>()
        .raw("SELECT id FROM docs WHERE title = 'why?' AND views > ?", [.int(1)])

    #expect(q.sql == "SELECT id FROM docs WHERE title = 'why?' AND views > $1")
    #expect(q.bindings == [.int(1)])
}

@Test func questionMarksInCommentsAndIdentifiersAreLeftAlone() {
    let q = QueryBuilder<Postgres>().raw(
        """
        -- is this ok?
        SELECT "weird?column" FROM docs /* also? */ WHERE id = ?
        """,
        [.int(7)]
    )
    #expect(q.sql.hasSuffix("WHERE id = $1"))
    #expect(q.bindings == [.int(7)])
}

@Test func doubledQuestionMarkIsALiteralOne() {
    let q = QueryBuilder<Postgres>().raw("SELECT tags ?? 'x' FROM docs WHERE id = ?", [.int(1)])
    #expect(q.sql == "SELECT tags ? 'x' FROM docs WHERE id = $1")
}

/// Too few values would send a bare `?` to the server; too many would silently
/// drop one. Both are refused at the boundary.
@Test func placeholderCountMismatchIsRefusedAtExecution() async {
    let q = QueryBuilder<Postgres>().raw("SELECT ? , ?", [.int(1)])
    await #expect(throws: SQLPlaceholderMismatch.self) {
        _ = try await q.fetchRows(on: RecordingExecutor())
    }
    // Rendering still works, so debugSQL shows which one went unfilled.
    #expect(q.debugSQL.contains("?"))
}

// MARK: - Inlined values (Ecto's constant())

/// Some positions will not take a parameter at all. This writes the value into
/// the statement, still escaped.
@Test func inlineWritesAnEscapedLiteralInsteadOfBinding() {
    let q = QueryBuilder<Postgres>()
        .select(d.id)
        .from(d)
        .where(sql("\(d.title) COLLATE \(inline: "en_US") = \("Ada")"))

    #expect(q.sql.contains("COLLATE 'en_US'"))
    // Only the genuinely bound value travels out of band.
    #expect(q.bindings == [.text("Ada")])
}

@Test func inlineStillEscapes() {
    let q = QueryBuilder<Postgres>().select(d.id).from(d).where(sql("x = \(inline: "O'Brien")"))
    #expect(q.sql.hasSuffix("x = 'O''Brien'"))
    #expect(q.bindings.isEmpty)
}

// MARK: - Conditional building (Kysely's $if)

@Test func ifAppliesOnlyWhenTheConditionHolds() {
    func build(sorted: Bool) -> String {
        QueryBuilder<Postgres>()
            .select(d.id).from(d)
            .if(sorted) { $0.orderBy(d.title.asc) }
            .sql
    }
    #expect(build(sorted: true).contains("ORDER BY"))
    #expect(!build(sorted: false).contains("ORDER BY"))
}

@Test func ifLetUnwrapsAndFilters() {
    func build(title: String?) -> (sql: String, bindings: [SQLValue]) {
        QueryBuilder<Postgres>()
            .select(d.id).from(d)
            .ifLet(title) { $0.where(d.title == $1) }
            .build()
    }

    #expect(build(title: "Ada").bindings == [.text("Ada")])
    #expect(build(title: nil).bindings.isEmpty)
    #expect(!build(title: nil).sql.contains("WHERE"))
}

/// Works on writes too — an optional `LIMIT` on a batched delete is the same
/// shape as an optional filter on a read.
@Test func conditionalBuildingWorksOnWrites() {
    let q = QueryBuilder<MySQL>()
        .delete(from: d)
        .where(d.views == 0)
        .if(true) { $0.limit(500) }
    #expect(q.sql.hasSuffix("LIMIT ?"))
}

// MARK: - Dialect-specific operators (red line 5)

@Test func postgresOperatorsRenderAsThemselves() {
    let ilike = QueryBuilder<Postgres>().select(d.id).from(d).where(Postgres.ilike(d.title, "ada%"))
    #expect(ilike.sql.hasSuffix(#""docs"."title" ILIKE $1"#))

    let contains = QueryBuilder<Postgres>().select(d.id).from(d)
        .where(Postgres.contains(d.tags, #"["swift"]"#))
    #expect(contains.sql.hasSuffix(#""docs"."tags" @> $1"#))

    let key = QueryBuilder<Postgres>().select(d.id).from(d).where(Postgres.hasKey(d.tags, "swift"))
    #expect(key.sql.hasSuffix(#""docs"."tags" ? $1"#))

    let text = QueryBuilder<Postgres>().select(Postgres.text(d.tags, "name")).from(d)
    #expect(text.sql.hasPrefix(#"SELECT "docs"."tags" ->> $1"#))
}

/// `MATCH` takes a column list because a full-text index covers a set of columns
/// and the SQL has to name the same set.
@Test func mysqlFullTextTakesAColumnList() {
    let q = QueryBuilder<MySQL>()
        .select(d.id).from(d)
        .where(MySQL.match(d.title, d.body, against: "swift sql", mode: .boolean))

    #expect(q.sql.hasSuffix("MATCH (`docs`.`title`, `docs`.`body`) AGAINST (? IN BOOLEAN MODE)"))
    #expect(q.bindings == [.text("swift sql")])
}

@Test func mysqlJSONHelpersUseTheFunctionForms() {
    let q = QueryBuilder<MySQL>().select(MySQL.jsonText(d.tags, "$.name")).from(d)
    #expect(q.sql.hasPrefix("SELECT JSON_UNQUOTE(JSON_EXTRACT(`docs`.`tags`, ?))"))
}

// MARK: - CTEs and set operations

@Test func withRendersACommonTableExpression() {
    let recent = QueryBuilder<Postgres>().select(d.id).from(d).where(d.views > 100)
    let q = QueryBuilder<Postgres>()
        .with("recent", as: recent)
        .select(d.id, d.title)
        .from(cte: "recent")

    #expect(q.sql == #"WITH "recent" AS (SELECT "docs"."id" FROM "docs" WHERE "docs"."views" > $1) SELECT "docs"."id", "docs"."title" FROM "recent""#)
    #expect(q.bindings == [.int(100)])
}

@Test func severalBindingsShareOneWithClause() {
    let a = QueryBuilder<Postgres>().select(d.id).from(d)
    let q = QueryBuilder<Postgres>().with("a", as: a).with("b", as: a).select(d.id).from(cte: "a")
    #expect(q.sql.hasPrefix(#"WITH "a" AS (SELECT "docs"."id" FROM "docs"), "b" AS ("#))
}

/// `RECURSIVE` is a property of the clause, not of one binding — SQL puts the
/// keyword once, after `WITH`.
@Test func recursiveKeywordAppearsOncePerClause() {
    let anchor = QueryBuilder<Postgres>().select(d.id).from(d)
    let q = QueryBuilder<Postgres>()
        .withRecursive("tree", columns: ["id"], as: anchor)
        .select(d.id)
        .from(cte: "tree")

    #expect(q.sql.hasPrefix(#"WITH RECURSIVE "tree" ("id") AS ("#))
    #expect(q.sql.components(separatedBy: "RECURSIVE").count == 2)
}

/// The operand's projection pack must match, so a column-count mismatch is a
/// compile error rather than a server error about differing numbers of columns.
@Test func unionAppendsAfterThisQuerysOwnClauses() {
    let left = QueryBuilder<Postgres>().select(d.id).from(d).where(d.views > 10).limit(5)
    let right = QueryBuilder<Postgres>().select(d.id).from(d).where(d.views < 2)
    let q = left.unionAll(right)

    #expect(q.sql.contains("LIMIT $2 UNION ALL SELECT"))
    #expect(q.bindings == [.int(10), .int(5), .int(2)])
}

@Test func intersectAndExceptRender() {
    let a = QueryBuilder<Postgres>().select(d.id).from(d)
    #expect(a.intersect(a).sql.contains(" INTERSECT SELECT"))
    #expect(a.except(a).sql.contains(" EXCEPT SELECT"))
}

// MARK: - Support

/// Records what it was asked to run and returns nothing.
private struct RecordingExecutor: SQLExecutor {
    typealias Dialect = Postgres
    func execute(sql: String, bindings: [SQLValue]) async throws -> [SQLRow] { [] }
    func executeUpdate(sql: String, bindings: [SQLValue]) async throws -> Int { 0 }
}
