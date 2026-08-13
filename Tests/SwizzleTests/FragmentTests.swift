import Testing
@testable import Swizzle

private struct Docs: SQLTable {
    static let tableName = "docs"
    var tableAlias: String?
    var id: SQLColumn<Int64> { bigInt("id") }
    var body: SQLColumn<String> { text("body") }
    var score: SQLColumn<Double> { double("score") }
    var tag: SQLColumn<String> { varchar("tag", 32) }
}

private let d = Docs()

/// The property that makes a fragment an escape hatch rather than a hole:
/// interpolated values still bind.
@Test func interpolatedValuesBindRatherThanSplice() {
    let hostile = "'); DROP TABLE docs; --"
    let q = QueryBuilder<Postgres>()
        .select(d.id)
        .from(d)
        .where(sql("\(d.body) LIKE \(hostile)"))

    #expect(q.sql == #"SELECT "docs"."id" FROM "docs" WHERE "docs"."body" LIKE $1"#)
    #expect(q.bindings == [.text(hostile)])
    #expect(!q.sql.contains("DROP"))
}

@Test func fragmentsCarryQualifiedQuotedColumns() {
    let q = QueryBuilder<MySQL>().select(d.id).from(d).where(sql("LENGTH(\(d.body)) > \(10)"))
    #expect(q.sql.hasSuffix("WHERE LENGTH(`docs`.`body`) > ?"))
}

/// The typed form exists only where a projection has to name a type.
@Test func typedFragmentProjectsAndDecodes() throws {
    let q = QueryBuilder<Postgres>()
        .select(d.id, sql("ts_rank(\(d.body), \("swift"))", as: Double.self))
        .from(d)

    #expect(q.sql == #"SELECT "docs"."id", ts_rank("docs"."body", $1) FROM "docs""#)

    let decoded: (Int64, Double) = try q.decode(SQLRow(values: [.int(1), .double(0.5)]))
    #expect(decoded.1 == 0.5)
}

/// Drizzle documents that `sql<T>` performs no runtime mapping, so a wrong type
/// is silently wrong. Ours is the instruction the decoder follows, so it fails on
/// the first row instead.
@Test func aWrongFragmentTypeThrowsRatherThanLying() {
    let q = QueryBuilder<Postgres>().select(sql("some_expression", as: Double.self)).from(d)
    #expect(throws: SQLDecodeError.self) {
        _ = try q.decode(SQLRow(values: [.text("not a number")]))
    }
}

@Test func listInterpolationBindsEveryElement() {
    let tags = ["swift", "sql"]
    let q = QueryBuilder<Postgres>().select(d.id).from(d).where(sql("\(d.tag) IN \(list: tags)"))
    #expect(q.sql.hasSuffix(#"WHERE "docs"."tag" IN ($1, $2)"#))
    #expect(q.bindings == [.text("swift"), .text("sql")])
}

@Test func identifierInterpolationQuotesPerDialect() {
    let table = "docs_2026"
    #expect(SQLFragment("FROM \(identifier: table)").rendered(MySQL.self) == "FROM `docs_2026`")
    #expect(SQLFragment("FROM \(identifier: table)").rendered(Postgres.self) == #"FROM "docs_2026""#)
}

/// `sql.raw`'s equivalent: verbatim, in either position.
@Test func unescapedSplicesVerbatim() {
    let q = QueryBuilder<Postgres>().select(d.id).from(d).where(sql("\(unescaped: "1 = 1")"))
    #expect(q.sql.hasSuffix("WHERE 1 = 1"))
}

@Test func fragmentsNestAndCompose() {
    let a: SQLFragment = "\(d.score) > \(0.5)"
    let b: SQLFragment = "\(d.tag) = \("swift")"
    let joined = [a, b].joined(separator: " AND ")

    let q = QueryBuilder<Postgres>().select(d.id).from(d).where(sql(joined))
    #expect(q.sql.hasSuffix(#"WHERE "docs"."score" > $1 AND "docs"."tag" = $2"#))
    #expect(q.bindings == [.double(0.5), .text("swift")])
}

@Test func appendingBuildsAFragmentIncrementally() {
    var clause = SQLFragment.empty
    #expect(clause.isEmpty)
    clause += "\(d.id) > \(0)"
    clause += " AND \(d.tag) = \("x")"

    let q = QueryBuilder<MySQL>().select(d.id).from(d).where(sql(clause))
    #expect(q.sql.hasSuffix("WHERE `docs`.`id` > ? AND `docs`.`tag` = ?"))
}

@Test func aSubqueryCanBeInterpolated() {
    let inner = QueryBuilder<Postgres>().select(d.id).from(d).where(d.score > 0.9)
    let q = QueryBuilder<Postgres>().select(d.id).from(d).where(sql("\(d.id) IN \(inner)"))
    #expect(q.sql.contains(#"IN (SELECT "docs"."id" FROM "docs" WHERE "docs"."score" > $1)"#))
}

private extension SQLFragment {
    /// Renders a bare fragment for a dialect, so identifier quoting can be
    /// asserted without wrapping it in a whole statement.
    func rendered<D: SQLDialect>(_ dialect: D.Type) -> String {
        var renderer = SQLRenderer<D>()
        renderer.render(node)
        return renderer.sql
    }
}

// MARK: - A fragment as the whole statement

/// `sql.raw`'s other position. The point of routing it through the builder
/// rather than the driver is that it keeps binding, dialect-correct placeholders,
/// and `debugSQL`.
@Test func aRawStatementStillBindsAndStillInspects() {
    let q = QueryBuilder<Postgres>().raw("SELECT id FROM report_view WHERE day = \(20260805)")
    #expect(q.sql == "SELECT id FROM report_view WHERE day = $1")
    #expect(q.bindings == [.int(20260805)])
    #expect(q.debugSQL == "SELECT id FROM report_view WHERE day = 20260805")
}

@Test func aRawStatementRendersPlaceholdersPerDialect() {
    let day = 1
    #expect(QueryBuilder<MySQL>().raw("SELECT \(day)").sql == "SELECT ?")
    #expect(QueryBuilder<Postgres>().raw("SELECT \(day)").sql == "SELECT $1")
}

/// Fully verbatim, for SQL your program authored — no binding at all.
@Test func aRawStatementCanBeEntirelyUnescaped() {
    let statement = "VACUUM ANALYZE"
    let q = QueryBuilder<Postgres>().raw("\(unescaped: statement)")
    #expect(q.sql == "VACUUM ANALYZE")
    #expect(q.bindings.isEmpty)
}
