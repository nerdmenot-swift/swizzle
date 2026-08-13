import Testing
@testable import Swizzle

private struct T: SQLTable {
    static let tableName = "users"
    var tableAlias: String?
    var id: SQLExpression<Int64> { column("id") }
    var age: SQLExpression<Int64> { column("age") }
    var name: SQLExpression<String> { column("name") }
}

private let t = T()

@Test func postgresUsesNumberedPlaceholdersAndDoubleQuotes() {
    let q = QueryBuilder<Postgres>()
        .select(t.id, t.name)
        .from(t)
        .where(t.age > 18 && t.name.like("A%"))
        .build()

    #expect(q.sql == #"SELECT "users"."id", "users"."name" FROM "users" WHERE ("users"."age" > $1 AND "users"."name" LIKE $2)"#)
    #expect(q.bindings == [.int(18), .text("A%")])
}

@Test func mysqlUsesQuestionMarksAndBackticks() {
    let q = QueryBuilder<MySQL>()
        .select(t.id)
        .from(t)
        .where(t.age > 18)
        .build()

    #expect(q.sql == "SELECT `users`.`id` FROM `users` WHERE `users`.`age` > ?")
    #expect(q.bindings == [.int(18)])
}

@Test func limitAndOffsetAreBoundNotInterpolated() {
    // Keeps the prepared-statement cache key stable across pages.
    let q = QueryBuilder<Postgres>().select(t.id).from(t).limit(10).offset(20).build()
    #expect(q.sql.hasSuffix("LIMIT $1 OFFSET $2"))
    #expect(q.bindings == [.int(10), .int(20)])
}

@Test func projectionPackTypesTheDecodedRow() throws {
    let q = QueryBuilder<Postgres>().select(t.id, t.name, t.age).from(t)
    let decoded: (Int64, String, Int64) = try q.decode(
        SQLRow(values: [.int(1), .text("Ada"), .int(36)])
    )
    #expect(decoded.0 == 1)
    #expect(decoded.1 == "Ada")
    #expect(decoded.2 == 36)
}

@Test func andOperatorAndAndFunctionProduceIdenticalSQL() {
    let viaOperator = QueryBuilder<Postgres>()
        .select(t.id).from(t)
        .where(t.age > 18 && t.name.like("A%"))
        .build()

    let viaFunction = QueryBuilder<Postgres>()
        .select(t.id).from(t)
        .where(and(t.age > 18, t.name.like("A%")))
        .build()

    #expect(viaOperator.sql == viaFunction.sql)
    #expect(viaOperator.bindings == viaFunction.bindings)
}
