import Testing
@testable import Swizzle

private struct Accounts: SQLTable {
    static let tableName = "accounts"
    var tableAlias: String?
    var id: SQLColumn<Int64> { bigInt("id") }
    var name: SQLColumn<String> { varchar("name", 120) }
    var balance: SQLColumn<String> { decimal("balance", 12, 2) }
    var active: SQLColumn<Bool> { boolean("active") }
    var avatar: SQLColumn<[UInt8]?> { blob("avatar") }
}

private let a = Accounts()

/// Every query renders, and rendering needs no connection — the dialect is a
/// type parameter, so the SQL can be asserted with nothing running.
@Test func everyQueryKindRendersWithoutADatabase() {
    let select = QueryBuilder<Postgres>().select(a.id).from(a).where(a.id == 1)
    let insert = QueryBuilder<Postgres>().insert(into: a).values { $0.set(a.name, to: "x") }
    let update = QueryBuilder<Postgres>().update(a).set(a.name, to: "y").where(a.id == 1)
    let delete = QueryBuilder<Postgres>().delete(from: a).where(a.id == 1)

    #expect(select.sql.hasPrefix("SELECT"))
    #expect(insert.sql.hasPrefix("INSERT"))
    #expect(update.sql.hasPrefix("UPDATE"))
    #expect(delete.sql.hasPrefix("DELETE"))
}

/// `sql` is the wire form: the string the server actually receives.
@Test func sqlIsTheWireForm() {
    let q = QueryBuilder<Postgres>().update(a).set(a.name, to: "Ada").where(a.id == 42)
    #expect(q.sql.contains("$1"))
    #expect(q.bindings == [.text("Ada"), .int(42)])
}

/// `debugSQL` is the paste-able form. Same traversal, values inlined.
@Test func debugSQLInlinesValues() {
    let q = QueryBuilder<Postgres>().update(a).set(a.name, to: "Ada").where(a.id == 42)
    #expect(q.debugSQL == #"UPDATE "accounts" SET "name" = 'Ada' WHERE "accounts"."id" = 42"#)
}

@Test func debugSQLQuotesStringsSafelyForReading() {
    let q = QueryBuilder<Postgres>().select(a.id).from(a).where(a.name == "O'Brien")
    #expect(q.debugSQL.hasSuffix("= 'O''Brien'"))
}

/// MySQL treats a backslash as an escape unless NO_BACKSLASH_ESCAPES is set, so
/// the debug rendering doubles it there and leaves it alone for Postgres.
@Test func debugSQLDoublesBackslashesOnlyForTheMySQLFamily() {
    let path = #"C:\temp"#
    let mysql = QueryBuilder<MySQL>().select(a.id).from(a).where(a.name == path)
    let postgres = QueryBuilder<Postgres>().select(a.id).from(a).where(a.name == path)
    #expect(mysql.debugSQL.hasSuffix(#"= 'C:\\temp'"#))
    #expect(postgres.debugSQL.hasSuffix(#"= 'C:\temp'"#))
}

@Test func debugSQLRendersEachValueKind() {
    let q = QueryBuilder<Postgres>()
        .update(a)
        .set(a.active, to: true)
        .set(a.balance, to: "10.25")
        .set(a.avatar, to: [0xDE, 0xAD] as [UInt8]?)

    #expect(q.debugSQL.contains("\"active\" = TRUE"))
    #expect(q.debugSQL.contains("\"balance\" = '10.25'"))
    #expect(q.debugSQL.contains("\"avatar\" = X'DEAD'"))
}

@Test func nullRendersAsNullNotAsAQuotedEmptyString() {
    let q = QueryBuilder<Postgres>().update(a).set(a.avatar, to: nil).where(a.id == 1)
    #expect(q.debugSQL.contains(#""avatar" = NULL"#))
}

/// Both forms have to describe the *same* statement — that is the whole reason
/// they share one traversal rather than being rendered separately.
@Test func bothFormsAgreeOnHowManyValuesTheStatementCarries() {
    let q = QueryBuilder<MySQL>()
        .select(a.id)
        .from(a)
        .where(a.name == "x" && a.id > 3)
        .limit(10)

    var inline = SQLRenderer<MySQL>(inlineBindings: true)
    q.render(into: &inline)
    #expect(inline.bindings.count == q.bindings.count)
    #expect(!inline.sql.contains("?"))
    #expect(q.sql.filter { $0 == "?" }.count == q.bindings.count)
}

/// `print(query)` has to work without anyone remembering an API — that is why
/// the protocol inherits the printable ones rather than leaving it to each type.
@Test func printingAQueryShowsTheStatementAndItsBindings() {
    let q = QueryBuilder<Postgres>().select(a.id).from(a).where(a.name == "Ada")
    let printed = String(describing: q)
    #expect(printed.contains("SELECT"))
    #expect(printed.contains("\"Ada\""))
    #expect(String(reflecting: q).hasPrefix("postgres: "))
}

@Test func aQueryWithNoBindingsPrintsAsJustTheStatement() {
    let q = QueryBuilder<Postgres>().select(a.id).from(a)
    #expect(String(describing: q) == #"SELECT "accounts"."id" FROM "accounts""#)
}
