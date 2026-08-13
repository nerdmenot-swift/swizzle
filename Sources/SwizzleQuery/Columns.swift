import SwizzleCore

/// A table column. Structurally identical to any other expression — the alias
/// exists so declarations read as what they are.
public typealias SQLColumn<Value> = SQLExpression<Value>

/// Column declarations named after the SQL type they describe.
///
/// ```swift
/// struct Users: SQLTable {
///     static let tableName = "users"
///     var tableAlias: String?
///
///     var id:       SQLColumn<Int64>   { bigInt("id") }
///     var email:    SQLColumn<String>  { varchar("email", 255) }
///     var nickname: SQLColumn<String?> { varchar("nickname", 64) }
///     var price:    SQLColumn<String>  { decimal("price", 10, 2) }
///     var active:   SQLColumn<Bool>    { boolean("is_active") }
/// }
/// ```
///
/// Following Drizzle, the declaration names the *database* type rather than
/// restating the schema in Swift terms — `varchar("email", 255)` sits closer to
/// the `CREATE TABLE` it describes than `column("email")` does.
///
/// ## Nullability is the Swift type
///
/// There is no `.null` argument, because Swift already has one: write
/// `SQLColumn<String?>` and the optional flows through the projection into the
/// result tuple, so the compiler makes the caller deal with it. Go needs
/// `sql.NullString` for this and sqlc needs annotations.
///
/// ## What the length and precision do — and do not do
///
/// Today they document. The builder decodes by the *Swift* type, so `255` and
/// `(10, 2)` change no behaviour at runtime, and it would be dishonest to imply
/// otherwise. What they buy is a declaration that reads like the schema, and a
/// place for pillar three to attach: prepare-and-describe can compare these
/// against what the database actually reports and turn drift into a generation-time
/// error. Migrations stay SQL-first, so the declaration *describes* a schema
/// rather than defining one, and the two can drift until that check exists.
///
/// The one place the SQL type earns its keep immediately is `decimal`, whose
/// documented Swift type is `String`: routing an exact numeric through `Double`
/// is how you lose the cents, and naming the type at the declaration makes that
/// visible instead of leaving it a rule you have to know.
extension SQLTable {
    /// The general form. Reach for a named type below when one fits.
    public func column<V>(_ name: String, as type: V.Type = V.self) -> SQLColumn<V> {
        SQLExpression(.column(qualifier: qualifier, name: name))
    }

    // MARK: Integers

    public func tinyInt<V>(_ name: String) -> SQLColumn<V> { column(name) }
    public func smallInt<V>(_ name: String) -> SQLColumn<V> { column(name) }
    public func int<V>(_ name: String) -> SQLColumn<V> { column(name) }
    public func bigInt<V>(_ name: String) -> SQLColumn<V> { column(name) }
    /// Postgres `SERIAL` / `BIGSERIAL`.
    public func serial<V>(_ name: String) -> SQLColumn<V> { column(name) }

    // MARK: Exact and approximate numerics

    /// `DECIMAL(p, s)` — an *exact* numeric.
    ///
    /// Declare it as `SQLColumn<String>`. Every driver we support returns it as
    /// text precisely so the value survives; decoding through `Double` silently
    /// rounds, which is the wrong failure for money.
    public func decimal<V>(_ name: String, _ precision: Int, _ scale: Int) -> SQLColumn<V> {
        column(name)
    }
    public func numeric<V>(_ name: String, _ precision: Int, _ scale: Int) -> SQLColumn<V> {
        column(name)
    }
    public func real<V>(_ name: String) -> SQLColumn<V> { column(name) }
    public func double<V>(_ name: String) -> SQLColumn<V> { column(name) }

    // MARK: Strings

    public func char<V>(_ name: String, _ length: Int) -> SQLColumn<V> { column(name) }
    public func varchar<V>(_ name: String, _ length: Int) -> SQLColumn<V> { column(name) }
    public func text<V>(_ name: String) -> SQLColumn<V> { column(name) }

    // MARK: Binary

    public func binary<V>(_ name: String, _ length: Int) -> SQLColumn<V> { column(name) }
    public func varbinary<V>(_ name: String, _ length: Int) -> SQLColumn<V> { column(name) }
    public func blob<V>(_ name: String) -> SQLColumn<V> { column(name) }
    /// Postgres spells it `BYTEA`.
    public func bytea<V>(_ name: String) -> SQLColumn<V> { column(name) }

    // MARK: Booleans

    public func boolean<V>(_ name: String) -> SQLColumn<V> { column(name) }

    // MARK: Temporal

    public func date<V>(_ name: String) -> SQLColumn<V> { column(name) }
    public func time<V>(_ name: String) -> SQLColumn<V> { column(name) }

    /// `DATETIME` — a wall clock, stored and returned unchanged.
    ///
    /// The distinction from `timestamp` is invisible on the MySQL wire except in
    /// the column-type byte, which is exactly why naming it here is worth
    /// something.
    public func datetime<V>(_ name: String) -> SQLColumn<V> { column(name) }

    /// `TIMESTAMP` — converted through the session time zone on the way in and out.
    public func timestamp<V>(_ name: String) -> SQLColumn<V> { column(name) }

    /// Postgres `TIMESTAMPTZ`.
    public func timestamptz<V>(_ name: String) -> SQLColumn<V> { column(name) }

    // MARK: Everything else

    public func json<V>(_ name: String) -> SQLColumn<V> { column(name) }
    /// Postgres `JSONB` — binary, indexable, and not the same type as `JSON`.
    public func jsonb<V>(_ name: String) -> SQLColumn<V> { column(name) }
    public func uuid<V>(_ name: String) -> SQLColumn<V> { column(name) }
    public func `enum`<V>(_ name: String) -> SQLColumn<V> { column(name) }
}
