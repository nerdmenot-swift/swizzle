import SwizzleCore

/// A `MigrationDialect`'s behaviour as a value.
///
/// The migrator used to be generic over its executor so it could reach
/// `Executor.Dialect` statically. That forced every caller to name a concrete
/// dialect, which is how the CLI ended up with a two-case enum and six methods
/// switching over it — a shape that needed editing in eight places to add a
/// third database.
///
/// Migrations are raw SQL, so the dialect only has to be *known*, not *typed*.
/// Carrying it as a value costs nothing here and makes the migrator work with a
/// database it has never heard of.
public struct AnyMigrationDialect: Sendable {
    public let name: String
    public let hasTransactionalDDL: Bool
    public let migrationSyntax: SQLStatementSplitter.Syntax

    let _writeIdentifier: @Sendable (String) -> String
    let _writePlaceholder: @Sendable (Int) -> String
    let _createJournalTable: @Sendable (String) -> String
    let _journalColumns: @Sendable (String) -> (String, [SQLValue])
    let _upgradeJournal: @Sendable (String) -> [String]
    let _acquireLock: @Sendable (String, Int) -> (String, [SQLValue])
    let _releaseLock: @Sendable (String) -> (String, [SQLValue])

    public init<D: MigrationDialect>(_ dialect: D.Type) {
        self.name = D.dialectName
        self.hasTransactionalDDL = D.hasTransactionalDDL
        self.migrationSyntax = D.migrationSyntax
        self._writeIdentifier = { name in
            var out = ""
            D.writeIdentifier(name, into: &out)
            return out
        }
        self._writePlaceholder = { index in
            var out = ""
            D.writePlaceholder(index: index, into: &out)
            return out
        }
        self._createJournalTable = { D.createJournalTable(named: $0) }
        self._journalColumns = { D.journalColumns(named: $0) }
        self._upgradeJournal = { D.upgradeJournal(named: $0) }
        self._acquireLock = { D.acquireLock(named: $0, timeoutSeconds: $1) }
        self._releaseLock = { D.releaseLock(named: $0) }
    }

    public func identifier(_ name: String) -> String { _writeIdentifier(name) }
    public func placeholder(_ index: Int) -> String { _writePlaceholder(index) }
    func createJournalTable(named table: String) -> String { _createJournalTable(table) }
    func journalColumns(named table: String) -> (String, [SQLValue]) { _journalColumns(table) }
    func upgradeJournal(named table: String) -> [String] { _upgradeJournal(table) }
    func acquireLock(named name: String, timeoutSeconds: Int) -> (String, [SQLValue]) {
        _acquireLock(name, timeoutSeconds)
    }
    func releaseLock(named name: String) -> (String, [SQLValue]) { _releaseLock(name) }
}

extension MigrationDialect {
    /// This dialect's migration behaviour as a value.
    public static var erased: AnyMigrationDialect { AnyMigrationDialect(Self.self) }
}
