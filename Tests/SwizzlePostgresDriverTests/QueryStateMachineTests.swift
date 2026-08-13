import SwizzleCore
import Testing
@testable import SwizzlePostgresDriver

@Suite("Postgres query flow")
struct QueryStateMachineTests {

    func column(
        _ name: String, _ oid: PostgresOID, format: Int16 = 1, tableOID: UInt32 = 16385,
        attnum: Int16 = 1
    ) -> PostgresColumnDescription {
        PostgresColumnDescription(
            name: name, tableOID: tableOID, columnAttributeNumber: attnum,
            dataTypeOID: oid.rawValue, dataTypeSize: -1, dataTypeModifier: -1, format: format
        )
    }

    // MARK: - Simple query

    @Test("a simple query sends one message and collects rows")
    func simpleQuery() {
        var machine = PostgresQueryStateMachine(mode: .simple("SELECT id FROM users"))
        #expect(machine.start() == .send([.query("SELECT id FROM users")]))

        _ = machine.handle(.rowDescription([column("id", .int8, format: 0)]))
        _ = machine.handle(.dataRow([Array("1".utf8)]))
        _ = machine.handle(.dataRow([Array("2".utf8)]))
        _ = machine.handle(.commandComplete(tag: "SELECT 2"))

        guard case .succeeded(let result) = machine.handle(.readyForQuery(.idle)) else {
            Issue.record("expected success"); return
        }
        #expect(result.rows == [[.int(1)], [.int(2)]])
        #expect(result.columns.map(\.name) == ["id"])
        #expect(result.affectedRows == 2)
    }

    // MARK: - Extended query

    @Test("an extended query sends Parse, Bind, Describe, Execute and Sync")
    func extendedQuerySequence() {
        var machine = PostgresQueryStateMachine(
            mode: .extended(sql: "SELECT $1", bindings: [Array("x".utf8)])
        )
        guard case .send(let messages) = machine.start() else {
            Issue.record("expected messages"); return
        }
        #expect(messages.count == 5)

        // An unnamed statement and portal: replaced on each use, so nothing has to
        // be closed and nothing can leak.
        guard case .parse(let name, let query, _) = messages[0] else {
            Issue.record("expected Parse"); return
        }
        #expect(name.isEmpty)
        #expect(query == "SELECT $1")
        #expect(messages.last == .sync)
    }

    /// **Not an optimisation and not optional.** A portal sends a
    /// `RowDescription` only if it is asked to. Without the `Describe`, the
    /// server replies with bare `DataRow`s and no column metadata at all — so
    /// every value decodes through the unknown-OID path and comes back as text.
    /// `SELECT pg_try_advisory_lock($1)` returns `"\u{01}"` instead of `true`,
    /// and nothing fails; it is simply wrong.
    ///
    /// The simple protocol has no such trap, which is what makes it easy to
    /// miss: unbound queries look perfectly fine.
    @Test("every extended query describes its portal")
    func extendedQueryDescribesThePortal() {
        func messages(for mode: PostgresQueryStateMachine.Mode) -> [PostgresFrontendMessage] {
            var machine = PostgresQueryStateMachine(mode: mode)
            guard case .send(let sent) = machine.start() else { return [] }
            return sent
        }

        // A fresh statement…
        #expect(
            messages(for: .extended(sql: "SELECT $1", bindings: [nil]))
                .contains(.describe(.portal, name: ""))
        )
        // …and a cached one, which skips the Parse but still has to ask.
        #expect(
            messages(
                for: .extended(
                    sql: "SELECT $1", bindings: [nil],
                    statement: PostgresPreparedStatementRef(name: "s1", needsParse: false)
                )
            ).contains(.describe(.portal, name: ""))
        )
    }

    /// The portal describe must come *before* the Execute, or the row
    /// descriptions arrive after the rows they describe.
    @Test("the portal describe precedes the execute")
    func describeComesBeforeExecute() {
        var machine = PostgresQueryStateMachine(
            mode: .extended(sql: "SELECT 1", bindings: [])
        )
        guard case .send(let messages) = machine.start() else {
            Issue.record("expected messages"); return
        }
        let describeIndex = messages.firstIndex(of: .describe(.portal, name: ""))
        let executeIndex = messages.firstIndex { if case .execute = $0 { true } else { false } }
        #expect(describeIndex != nil)
        #expect(executeIndex != nil)
        #expect(describeIndex! < executeIndex!)
    }

    @Test("binary results decode through the declared format")
    func binaryResults() {
        var machine = PostgresQueryStateMachine(
            mode: .extended(sql: "SELECT n", bindings: [])
        )
        _ = machine.start()
        _ = machine.handle(.parseComplete)
        _ = machine.handle(.bindComplete)
        _ = machine.handle(.rowDescription([column("n", .int4, format: 1)]))
        _ = machine.handle(.dataRow([[0, 0, 0, 42]]))
        _ = machine.handle(.commandComplete(tag: "SELECT 1"))

        guard case .succeeded(let result) = machine.handle(.readyForQuery(.idle)) else {
            Issue.record("expected success"); return
        }
        #expect(result.rows == [[.int(42)]])
    }

    /// The format comes from `RowDescription`, not from what we asked for — a
    /// server may answer a binary request with text for a type it has no binary
    /// form of, and decoding those bytes as binary would be nonsense.
    @Test("a per-column format is honoured rather than assumed")
    func perColumnFormat() {
        var machine = PostgresQueryStateMachine(mode: .extended(sql: "…", bindings: []))
        _ = machine.start()
        _ = machine.handle(.rowDescription([
            column("binary", .int4, format: 1, attnum: 1),
            column("textual", .int4, format: 0, attnum: 2),
        ]))
        _ = machine.handle(.dataRow([[0, 0, 0, 7], Array("7".utf8)]))
        _ = machine.handle(.commandComplete(tag: "SELECT 1"))

        guard case .succeeded(let result) = machine.handle(.readyForQuery(.idle)) else {
            Issue.record("expected success"); return
        }
        // Both are 7, decoded two different ways.
        #expect(result.rows == [[.int(7), .int(7)]])
    }

    // MARK: - The error rule

    /// After an error the server **discards every message until `Sync`**. A client
    /// that reports the failure and moves on finds its next statement's replies
    /// arriving for a statement that never ran.
    @Test("an error keeps consuming until ReadyForQuery")
    func errorDrainsToReadyForQuery() {
        var machine = PostgresQueryStateMachine(mode: .extended(sql: "boom", bindings: []))
        _ = machine.start()

        let error = PostgresServerMessage(fields: [
            0x53: "ERROR", 0x43: "42601", 0x4D: "syntax error at or near \"boom\"",
        ])
        // The failure is not reported yet — the server is still discarding.
        #expect(machine.handle(.error(error)) == .wait)
        #expect(machine.handle(.dataRow([nil])) == .wait)
        #expect(machine.handle(.commandComplete(tag: "SELECT 0")) == .wait)

        guard case .failed(let failure) = machine.handle(.readyForQuery(.failed)) else {
            Issue.record("expected a failure at ReadyForQuery"); return
        }
        #expect(failure.description.contains("syntax error"))
        #expect(failure.description.contains("42601"))
    }

    // MARK: - Describe, the reason this driver exists

    /// Parse, Describe, Sync — and never Bind or Execute. A generator that ran the
    /// statements it analysed would delete rows to find out what `DELETE` returns.
    @Test("describe never sends Bind or Execute")
    func describeDoesNotExecute() {
        var machine = PostgresQueryStateMachine(mode: .describe("DELETE FROM users"))
        guard case .send(let messages) = machine.start() else {
            Issue.record("expected messages"); return
        }
        #expect(messages.count == 3)
        #expect(messages[1] == .describe(.statement, name: ""))
        #expect(messages[2] == .sync)

        for message in messages {
            if case .bind = message { Issue.record("describe must not Bind") }
            if case .execute = message { Issue.record("describe must not Execute") }
        }
    }

    /// Both halves. postgres-nio exposes neither — `RowDescription` is internal and
    /// `ParameterDescription.dataTypes` is discarded outright.
    @Test("describe returns parameter types and column descriptions")
    func describeReturnsBothHalves() {
        var machine = PostgresQueryStateMachine(
            mode: .describe("SELECT id, email FROM users WHERE id = $1")
        )
        _ = machine.start()
        _ = machine.handle(.parseComplete)
        _ = machine.handle(.parameterDescription([PostgresOID.int8.rawValue]))
        _ = machine.handle(.rowDescription([
            column("id", .int8, attnum: 1),
            column("email", .text, attnum: 2),
        ]))

        guard case .described(let description) = machine.handle(.readyForQuery(.idle)) else {
            Issue.record("expected a description"); return
        }
        // Postgres is the only engine that genuinely types parameters.
        #expect(description.parameterTypes == [PostgresOID.int8.rawValue])
        #expect(description.columns.map(\.name) == ["id", "email"])
        // tableOID and attnum are what make a column traceable to a base table,
        // and therefore what makes nullability recoverable at all.
        #expect(description.columns[1].tableOID == 16385)
        #expect(description.columns[1].columnAttributeNumber == 2)
    }

    /// A statement returning no rows still describes: `NoData` replaces
    /// `RowDescription` and the parameters still arrive.
    @Test("describing a statement with no result still yields parameters")
    func describeWithNoData() {
        var machine = PostgresQueryStateMachine(mode: .describe("DELETE FROM users WHERE id = $1"))
        _ = machine.start()
        _ = machine.handle(.parseComplete)
        _ = machine.handle(.parameterDescription([PostgresOID.int8.rawValue]))
        _ = machine.handle(.noData)

        guard case .described(let description) = machine.handle(.readyForQuery(.idle)) else {
            Issue.record("expected a description"); return
        }
        #expect(description.parameterTypes.count == 1)
        #expect(description.columns.isEmpty)
    }

    @Test("a describe that fails reports the server's error")
    func describeFailure() {
        var machine = PostgresQueryStateMachine(mode: .describe("SELECT nope FROM users"))
        _ = machine.start()
        _ = machine.handle(.error(PostgresServerMessage(fields: [
            0x53: "ERROR", 0x43: "42703", 0x4D: "column \"nope\" does not exist",
        ])))

        guard case .failed(let error) = machine.handle(.readyForQuery(.idle)) else {
            Issue.record("expected a failure"); return
        }
        #expect(error.description.contains("does not exist"))
    }

    // MARK: - Portals

    /// A row-limited `Execute` stopping short must be visible, or a caller reads a
    /// truncated result as a complete one.
    @Test("a suspended portal is flagged rather than mistaken for the end")
    func suspendedPortal() {
        var machine = PostgresQueryStateMachine(
            mode: .extended(sql: "SELECT id FROM big", bindings: [], maxRows: 2)
        )
        _ = machine.start()
        _ = machine.handle(.rowDescription([column("id", .int8, format: 1)]))
        _ = machine.handle(.dataRow([[0, 0, 0, 0, 0, 0, 0, 1]]))
        _ = machine.handle(.dataRow([[0, 0, 0, 0, 0, 0, 0, 2]]))
        _ = machine.handle(.portalSuspended)

        guard case .succeeded(let result) = machine.handle(.readyForQuery(.idle)) else {
            Issue.record("expected success"); return
        }
        #expect(result.isSuspended)
        #expect(result.rows.count == 2)
        // No command tag, because the command has not completed.
        #expect(result.commandTag == nil)
    }
}

@Suite("Postgres command tags")
struct CommandTagTests {

    /// The tag is the *only* place the affected-row count exists — there is no
    /// separate field for it anywhere in the protocol. Not parsing it is how
    /// `executeUpdate` came to return zero for months on the borrowed driver.
    @Test("the affected-row count is read from the tag")
    func affectedRows() {
        #expect(PostgresCommandTag.affectedRows("UPDATE 5") == 5)
        #expect(PostgresCommandTag.affectedRows("DELETE 2") == 2)
        #expect(PostgresCommandTag.affectedRows("SELECT 12") == 12)
        #expect(PostgresCommandTag.affectedRows("MERGE 7") == 7)
    }

    /// `INSERT` carries an OID before the count — historically the row's OID, now
    /// always zero. Taking the last field handles it without a special case.
    @Test("INSERT's extra OID field does not become the count")
    func insertHasThreeFields() {
        #expect(PostgresCommandTag.affectedRows("INSERT 0 3") == 3)
        #expect(PostgresCommandTag.affectedRows("INSERT 0 0") == 0)
    }

    /// "No count" and "changed nothing" are different answers, and only one of
    /// them is a number.
    @Test("commands with no count report nil, not zero")
    func commandsWithoutCounts() {
        #expect(PostgresCommandTag.affectedRows("BEGIN") == nil)
        #expect(PostgresCommandTag.affectedRows("COMMIT") == nil)
        #expect(PostgresCommandTag.affectedRows("SET") == nil)
        #expect(PostgresCommandTag.affectedRows("CREATE TABLE") == nil)
    }

    @Test("the command verb is available for diagnostics")
    func verbs() {
        #expect(PostgresCommandTag.command("INSERT 0 3") == "INSERT")
        #expect(PostgresCommandTag.command("CREATE TABLE") == "CREATE")
    }
}
