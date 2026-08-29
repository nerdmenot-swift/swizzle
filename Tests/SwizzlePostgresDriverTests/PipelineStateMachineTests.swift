import Testing
@testable import SwizzlePostgresDriver

/// The pipeline state machine, driven directly.
///
/// ## Why this file exists
///
/// The mutation sweep found **six survivors in one file**, all of them the same
/// shape: `<` relaxed to `<=` on a bounds check, at lines 148, 154, 158, 166,
/// 177 and 195. Six mutants clustered in one place is not scattered noise, it is
/// a hole — and the hole was that nothing referenced `PostgresPipelineStateMachine` at
/// all. Its only coverage was `PostgresPipelineTests` driving a real server down
/// the happy path.
///
/// Every one of those guards protects an array subscript against a server that
/// sends **more replies than there were statements**. Relax `current <
/// results.count` to `<=` and the very next line indexes one past the end, which
/// is a crash rather than an error — the worst failure mode a driver has, and
/// the one hardest to attribute to the driver rather than to the caller.
///
/// A real server does not do this. That is exactly why it needs a test: the
/// guards exist for a desynchronised or hostile peer, and a happy-path
/// integration test can never reach them. Driving the machine directly is the
/// only way to hand it the message it should not have received.
@Suite("Postgres pipeline state machine")
struct PostgresPipelineStateMachineTests {

    static func statement(_ sql: String) -> PostgresPipelineStatement {
        PostgresPipelineStatement(sql: sql)
    }

    static func column(_ name: String) -> PostgresColumnDescription {
        PostgresColumnDescription(
            name: name, tableOID: 1, columnAttributeNumber: 1,
            dataTypeOID: 20, dataTypeSize: 8, dataTypeModifier: -1, format: 1
        )
    }

    /// Runs one statement's worth of replies through, leaving `current` at 1 —
    /// which for a single-statement pipeline is one past the end.
    static func exhausted() -> PostgresPipelineStateMachine {
        var machine = PostgresPipelineStateMachine(statements: [Self.statement("SELECT 1")])
        _ = machine.start()
        _ = machine.handle(.rowDescription([Self.column("id")]))
        _ = machine.handle(.dataRow([Array("1".utf8)]))
        _ = machine.handle(.commandComplete(tag: "SELECT 1"))
        return machine
    }

    // MARK: - The happy path, so the rest means something

    @Test("one statement's replies are collected in order")
    func singleStatement() {
        var machine = PostgresPipelineStateMachine(statements: [Self.statement("SELECT 1")])
        guard case .send(let messages) = machine.start() else {
            Issue.record("start should send"); return
        }
        // Parse, Bind, Describe, Execute — then exactly one Sync for the batch.
        #expect(messages.count == 5)

        _ = machine.handle(.rowDescription([Self.column("id")]))
        _ = machine.handle(.dataRow([Array("1".utf8)]))
        _ = machine.handle(.commandComplete(tag: "SELECT 1"))

        guard case .succeeded(let results) = machine.handle(.readyForQuery(.idle)) else {
            Issue.record("ReadyForQuery should complete the pipeline"); return
        }
        #expect(results.count == 1)
        #expect(results[0].rows.count == 1)
        #expect(results[0].commandTag == "SELECT 1")
    }

    /// `CommandComplete` is the only boundary between statements — there is no
    /// per-statement marker — so this is what keeps two statements' rows apart.
    @Test("each statement's rows stay with that statement")
    func resultsAreNotMixed() {
        var machine = PostgresPipelineStateMachine(
            statements: [Self.statement("SELECT 1"), Self.statement("SELECT 2")]
        )
        _ = machine.start()

        _ = machine.handle(.rowDescription([Self.column("a")]))
        _ = machine.handle(.dataRow([Array("1".utf8)]))
        _ = machine.handle(.commandComplete(tag: "SELECT 1"))

        _ = machine.handle(.rowDescription([Self.column("b")]))
        _ = machine.handle(.dataRow([Array("2".utf8)]))
        _ = machine.handle(.dataRow([Array("3".utf8)]))
        _ = machine.handle(.commandComplete(tag: "SELECT 2"))

        guard case .succeeded(let results) = machine.handle(.readyForQuery(.idle)) else {
            Issue.record("expected success"); return
        }
        #expect(results.map(\.rows.count) == [1, 2])
        #expect(results.map(\.commandTag) == ["SELECT 1", "SELECT 2"])
    }

    // MARK: - More replies than statements

    /// The guard at every one of those six lines, stated once: a server that
    /// keeps talking after the last statement's `CommandComplete` must be
    /// ignored, not indexed.
    ///
    /// Each of these would index `results[1]` in a one-element array if its
    /// bounds check were off by one.
    @Test("a RowDescription after the last statement is ignored, not indexed")
    func rowDescriptionPastTheEnd() {
        var machine = Self.exhausted()
        guard case .wait = machine.handle(.rowDescription([Self.column("ghost")])) else {
            Issue.record("expected .wait"); return
        }
    }

    @Test("a DataRow after the last statement is ignored, not indexed")
    func dataRowPastTheEnd() {
        var machine = Self.exhausted()
        guard case .wait = machine.handle(.dataRow([Array("x".utf8)])) else {
            Issue.record("expected .wait"); return
        }
    }

    @Test("a CommandComplete after the last statement is ignored, not indexed")
    func commandCompletePastTheEnd() {
        var machine = Self.exhausted()
        guard case .wait = machine.handle(.commandComplete(tag: "SELECT 0")) else {
            Issue.record("expected .wait"); return
        }
    }

    @Test("an EmptyQueryResponse after the last statement is ignored, not indexed")
    func emptyQueryPastTheEnd() {
        var machine = Self.exhausted()
        guard case .wait = machine.handle(.emptyQueryResponse) else {
            Issue.record("expected .wait"); return
        }
    }

    /// And the whole run still completes rather than being poisoned by the extra
    /// traffic — the results are the ones the statements produced.
    @Test("extra replies do not corrupt the results that were collected")
    func extraRepliesLeaveResultsIntact() {
        var machine = Self.exhausted()
        _ = machine.handle(.rowDescription([Self.column("ghost")]))
        _ = machine.handle(.dataRow([Array("x".utf8)]))
        _ = machine.handle(.emptyQueryResponse)

        guard case .succeeded(let results) = machine.handle(.readyForQuery(.idle)) else {
            Issue.record("expected success"); return
        }
        #expect(results.count == 1)
        #expect(results[0].rows.count == 1, "the ghost row must not have been appended")
        #expect(results[0].commandTag == "SELECT 1")
    }

    // MARK: - A row wider than its description

    /// `DataRow` values are zipped against the columns from `RowDescription`, and
    /// a value with no matching column decodes with OID 0 rather than reading off
    /// the end of the array. This is line 158's guard, and the same reasoning:
    /// a well-behaved server cannot produce it, which is why nothing reached it.
    @Test("a row with more values than columns decodes the surplus as untyped")
    func rowWiderThanItsDescription() {
        var machine = PostgresPipelineStateMachine(statements: [Self.statement("SELECT 1")])
        _ = machine.start()
        _ = machine.handle(.rowDescription([Self.column("only")]))
        _ = machine.handle(.dataRow([Array("1".utf8), Array("surplus".utf8)]))
        _ = machine.handle(.commandComplete(tag: "SELECT 1"))

        guard case .succeeded(let results) = machine.handle(.readyForQuery(.idle)) else {
            Issue.record("expected success"); return
        }
        #expect(results[0].rows.first?.count == 2, "both values should survive")
    }

    /// A row arriving with no `RowDescription` at all: `columns` is empty, so
    /// every value takes the same fallback.
    @Test("a row with no description at all is still decoded")
    func rowWithNoDescription() {
        var machine = PostgresPipelineStateMachine(statements: [Self.statement("SELECT 1")])
        _ = machine.start()
        _ = machine.handle(.dataRow([Array("1".utf8)]))
        _ = machine.handle(.commandComplete(tag: "SELECT 1"))

        guard case .succeeded(let results) = machine.handle(.readyForQuery(.idle)) else {
            Issue.record("expected success"); return
        }
        #expect(results[0].rows.count == 1)
    }

    // MARK: - Failure

    /// An error attributes itself to the statement whose replies were arriving,
    /// and everything after it is the server draining rather than more results.
    @Test("an error names the statement that caused it and swallows the drain")
    func errorAttribution() {
        var machine = PostgresPipelineStateMachine(
            statements: [Self.statement("SELECT 1"), Self.statement("SELECT bad")]
        )
        _ = machine.start()
        _ = machine.handle(.rowDescription([Self.column("a")]))
        _ = machine.handle(.dataRow([Array("1".utf8)]))
        _ = machine.handle(.commandComplete(tag: "SELECT 1"))

        _ = machine.handle(.error(PostgresServerMessage(fields: [
            UInt8(ascii: "S"): "ERROR",
            UInt8(ascii: "C"): "42703",
            UInt8(ascii: "M"): "column \"bad\" does not exist",
        ])))
        // Anything between the error and ReadyForQuery is drained, not recorded.
        _ = machine.handle(.dataRow([Array("noise".utf8)]))

        guard case .failed(let error) = machine.handle(.readyForQuery(.failed)) else {
            Issue.record("expected failure"); return
        }
        #expect(error.statementIndex == 1)
        #expect(error.sql == "SELECT bad")
        // Diagnostic only: the implicit transaction rolled the first one back too.
        #expect(error.completed.count == 1)
    }

    /// Line 195's guard. If the error arrives before any statement's replies —
    /// or after all of them — `failureIndex` can sit outside the statement list,
    /// and the error still has to be constructible rather than crash while being
    /// reported.
    @Test("an error past the last statement still produces a reportable failure")
    func errorPastTheEnd() {
        var machine = Self.exhausted()
        _ = machine.handle(.error(PostgresServerMessage(fields: [
            UInt8(ascii: "S"): "ERROR",
            UInt8(ascii: "M"): "something after the end",
        ])))

        guard case .failed(let error) = machine.handle(.readyForQuery(.failed)) else {
            Issue.record("expected failure"); return
        }
        #expect(error.statementIndex == 1, "one past the single statement")
        #expect(error.sql == "", "there is no statement to name, and that is not a crash")
    }

    /// An empty pipeline has no statements at all, so *every* one of these bounds
    /// is zero-length. Cheap, and it exercises all six guards at once.
    @Test("an empty pipeline handles replies it should never receive")
    func emptyPipeline() {
        var machine = PostgresPipelineStateMachine(statements: [])
        _ = machine.start()
        _ = machine.handle(.rowDescription([Self.column("ghost")]))
        _ = machine.handle(.dataRow([Array("x".utf8)]))
        _ = machine.handle(.commandComplete(tag: "SELECT 0"))
        _ = machine.handle(.emptyQueryResponse)

        guard case .succeeded(let results) = machine.handle(.readyForQuery(.idle)) else {
            Issue.record("expected success"); return
        }
        #expect(results.isEmpty)
    }
}
