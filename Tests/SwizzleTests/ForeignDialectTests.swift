import SwizzleCore
import Testing

/// A dialect declared **outside** `SwizzleCore`, which is what a fourth database
/// would be.
///
/// The architecture claims a new engine can bring its own dialect and that
/// shared code never branches on a concrete one. That claim had exactly one
/// counter-example: the renderer wrote
/// `D.dialectName == "sqlite" ? "OR IGNORE " : "IGNORE "`, so a foreign dialect
/// that spells it SQLite's way got MySQL's spelling — and `INSERT IGNORE` is a
/// syntax error on anything SQLite-shaped, so the statement would not run.
///
/// Two ways it could bite, both silent: a new dialect getting the wrong clause,
/// and an existing dialect changing its `dialectName` and changing the SQL it
/// emits as a side effect.
///
/// These dialects exist only here. That is the point — if the renderer can serve
/// a dialect it has never heard of, it is not branching on the ones it has.
@Suite("Foreign dialects")
struct ForeignDialectTests {

    /// Spells duplicate-ignoring the SQLite way without being SQLite.
    enum Fictional: SQLDialect, SupportsInsertIgnore {
        static let dialectName = "fictional"
        static let identifierQuote: Character = "\""
        static let insertIgnoreClause = "OR IGNORE "
        static func writePlaceholder(index: Int, into sql: inout String) { sql.append("?") }
    }

    /// Says nothing, and so inherits the majority spelling.
    enum Silent: SQLDialect, SupportsInsertIgnore {
        static let dialectName = "silent"
        static let identifierQuote: Character = "`"
        static func writePlaceholder(index: Int, into sql: inout String) { sql.append("?") }
    }

    func rendered<D: SQLDialect>(_ dialect: D.Type) -> String {
        var core = SQLInsertCore(table: "users")
        core.columns = ["email"]
        core.rows = [[.text("a@example.com")]]
        core.ignoreDuplicates = true

        var renderer = SQLRenderer<D>()
        renderer.renderInsert(core)
        return renderer.sql
    }

    /// **The case the name comparison could not serve.** A dialect the renderer
    /// has never heard of, asking for the non-default spelling and getting it.
    @Test("a foreign dialect chooses its own ignore clause")
    func foreignDialectGetsItsOwnSpelling() {
        let sql = rendered(Fictional.self)
        #expect(sql.contains("INSERT OR IGNORE INTO"), "rendered: \(sql)")
        #expect(!sql.contains("INSERT IGNORE"), "got MySQL's spelling: \(sql)")
    }

    /// And one that says nothing inherits the majority spelling rather than
    /// having to restate it.
    @Test("a foreign dialect that says nothing gets the default")
    func defaultSpelling() {
        #expect(rendered(Silent.self).contains("INSERT IGNORE INTO"))
    }

    /// The two built-ins still disagree in the way they must: `INSERT OR IGNORE`
    /// is a syntax error on MySQL and `INSERT IGNORE` is one on SQLite.
    @Test("the built-in dialects keep their own spellings")
    func builtInsUnchanged() {
        #expect(rendered(SQLite.self).contains("INSERT OR IGNORE INTO"))
        #expect(rendered(MySQL.self).contains("INSERT IGNORE INTO"))
        #expect(rendered(MariaDB.self).contains("INSERT IGNORE INTO"))
    }

    /// Renaming a dialect must not change the SQL it emits — which it did, back
    /// when the renderer matched on the name.
    @Test("the clause does not depend on the dialect's name")
    func nameIsNotLoadBearing() {
        enum RenamedSQLite: SQLDialect, SupportsInsertIgnore {
            static let dialectName = "sqlite3"   // not the string the renderer used to match
            static let identifierQuote: Character = "\""
            static let insertIgnoreClause = "OR IGNORE "
            static func writePlaceholder(index: Int, into sql: inout String) { sql.append("?") }
        }
        #expect(rendered(RenamedSQLite.self).contains("INSERT OR IGNORE INTO"))
    }
}
