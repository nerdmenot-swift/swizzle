import Testing
@testable import Swizzle

/// A table declared the way the design says tables are declared: named for the
/// SQL types, with nullability carried by the Swift optional.
private struct Users: SQLTable {
    static let tableName = "users"
    var tableAlias: String?

    var id: SQLColumn<Int64> { bigInt("id") }
    var email: SQLColumn<String> { varchar("email", 255) }
    var name: SQLColumn<String> { varchar("name", 120) }
    var nickname: SQLColumn<String?> { varchar("nickname", 64) }
    var price: SQLColumn<String> { decimal("price", 10, 2) }
    var views: SQLColumn<Int64> { int("views") }
    var age: SQLColumn<Int64> { int("age") }
    var active: SQLColumn<Bool> { boolean("is_active") }
}

private let u = Users()

// MARK: - UPDATE

@Test func updateSetsAndFilters() {
    let q = QueryBuilder<Postgres>()
        .update(u)
        .set(u.name, to: "Ada")
        .where(u.id == 42)

    #expect(q.sql == #"UPDATE "users" SET "name" = $1 WHERE "users"."id" = $2"#)
    #expect(q.bindings == [.text("Ada"), .int(42)])
}

/// The assignment target loses its qualifier: `SET users.name = …` is legal
/// MySQL and a syntax error in Postgres, and the bare name works on both.
@Test func assignmentTargetIsUnqualifiedEvenThoughTheColumnIsNot() {
    let q = QueryBuilder<MySQL>().update(u).set(u.name, to: "Ada").where(u.id == 1)
    #expect(q.sql == "UPDATE `users` SET `name` = ? WHERE `users`.`id` = ?")
}

/// `views = views + 1` is the case that sends people back to raw SQL in builders
/// whose assignments only accept literals.
@Test func assignmentsCanBeExpressions() {
    let q = QueryBuilder<Postgres>()
        .update(u)
        .set(u.views, to: u.views + 1)
        .where(u.id == 7)

    #expect(q.sql == #"UPDATE "users" SET "views" = "users"."views" + $1 WHERE "users"."id" = $2"#)
    #expect(q.bindings == [.int(1), .int(7)])
}

@Test func predicatesAccumulateAndAnd() {
    // The ordinary answer to "build a WHERE from N optional filters" — no
    // fragment API needed, which is why we did not copy Drizzle's four
    // chunk-joining constructors.
    var q = QueryBuilder<Postgres>().update(u).set(u.name, to: "Ada")
    for predicate in [u.age > 18, u.active == true] {
        q = q.where(predicate)
    }
    #expect(q.sql.hasSuffix(#"WHERE "users"."age" > $2 AND "users"."is_active" = $3"#))
}

// MARK: - DELETE

@Test func deleteRenders() {
    let q = QueryBuilder<Postgres>().delete(from: u).where(u.age < 13)
    #expect(q.sql == #"DELETE FROM "users" WHERE "users"."age" < $1"#)
    #expect(q.bindings == [.int(13)])
}

/// `DELETE … LIMIT` is how you drain a backlog without one enormous transaction.
/// It exists on MySQL and MariaDB and nowhere else we support.
@Test func writeLimitIsGatedToMySQLFamily() {
    let q = QueryBuilder<MariaDB>()
        .delete(from: u)
        .where(u.active == false)
        .orderBy(u.id.asc)
        .limit(1000)

    #expect(q.sql == "DELETE FROM `users` WHERE `users`.`is_active` = ? ORDER BY `users`.`id` LIMIT ?")
    #expect(q.bindings == [.bool(false), .int(1000)])
    // QueryBuilder<Postgres>().delete(from: u).limit(1) does not compile:
    // Postgres does not conform to SupportsWriteLimit.
}

@Test func returningOnDeleteIsGatedToDialectsThatHaveIt() {
    let q = QueryBuilder<Postgres>().delete(from: u).where(u.id == 3).returning(u.id, u.email)
    #expect(q.sql.hasSuffix(#"RETURNING "users"."id", "users"."email""#))
    // The same call on MySQL does not compile.
}

// MARK: - Upsert, spelled as each engine spells it

@Test func postgresOnConflictDoUpdateUsesExcluded() {
    let q = QueryBuilder<Postgres>()
        .insert(into: u)
        .values { $0.set(u.email, to: "ada@example.com"); $0.set(u.name, to: "Ada") }
        .onConflict(u.email)
        .doUpdate { $0.set(u.name, to: $0.excluded(u.name)) }

    #expect(q.sql == #"INSERT INTO "users" ("email", "name") VALUES ($1, $2) ON CONFLICT ("email") DO UPDATE SET "name" = EXCLUDED."name""#)
}

@Test func postgresOnConflictDoNothing() {
    let q = QueryBuilder<SQLite>()
        .insert(into: u)
        .values { $0.set(u.email, to: "a@b.c") }
        .onConflict(u.email)
        .doNothing()

    #expect(q.sql.hasSuffix(#"ON CONFLICT ("email") DO NOTHING"#))
}

@Test func mysqlOnDuplicateKeyUpdateUsesValues() {
    let q = QueryBuilder<MySQL>()
        .insert(into: u)
        .values { $0.set(u.email, to: "ada@example.com"); $0.set(u.name, to: "Ada") }
        .onDuplicateKeyUpdate { $0.set(u.name, to: $0.values(u.name)) }

    #expect(q.sql == "INSERT INTO `users` (`email`, `name`) VALUES (?, ?) ON DUPLICATE KEY UPDATE `name` = VALUES(`name`)")
    // `$0.excluded(...)` does not compile here, and `$0.values(...)` does not
    // compile inside a Postgres doUpdate — each sub-expression is gated by the
    // same capability as the clause that contains it.
}

@Test func upsertCanIncrementRatherThanOverwrite() {
    let q = QueryBuilder<MySQL>()
        .insert(into: u)
        .values { $0.set(u.email, to: "a@b.c") }
        .onDuplicateKeyUpdate { $0.set(u.views, to: u.views + 1) }

    #expect(q.sql.hasSuffix("ON DUPLICATE KEY UPDATE `views` = `users`.`views` + ?"))
}

// MARK: - Multi-row insert

@Test func repeatedValuesCallsMakeAMultiRowInsert() {
    let q = QueryBuilder<Postgres>()
        .insert(into: u)
        .values { $0.set(u.email, to: "a@b.c") }
        .values { $0.set(u.email, to: "d@e.f") }

    #expect(q.sql == #"INSERT INTO "users" ("email") VALUES ($1), ($2)"#)
    #expect(q.bindings == [.text("a@b.c"), .text("d@e.f")])
}
