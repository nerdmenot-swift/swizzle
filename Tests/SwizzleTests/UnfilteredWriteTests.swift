import Foundation
import Testing
@testable import Swizzle

private struct Sessions: SQLTable {
    static let tableName = "sessions"
    var tableAlias: String?
    var id: SQLColumn<Int64> { bigInt("id") }
    var token: SQLColumn<String> { varchar("token", 64) }
}

private let s = Sessions()

/// Records what the builder reports instead of writing to stderr.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func capture(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        messages.append(message)
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }
}

/// Accepts anything and reports a fixed row count.
private struct FakeExecutor: SQLExecutor {
    typealias Dialect = Postgres
    let affected: Int
    func execute(sql: String, bindings: [SQLValue]) async throws -> [SQLRow] { [] }
    func executeUpdate(sql: String, bindings: [SQLValue]) async throws -> Int { affected }
}

/// Serialized because `SQLDiagnostics.handler` is process-global — a diagnostic
/// sink, deliberately not lock-protected, so the tests that swap it must not
/// overlap.
@Suite("Unfiltered writes are reported, not refused", .serialized)
struct UnfilteredWriteTests {

    /// Swaps the handler for the duration of `body` and returns what it saw.
    private func capturing(_ body: () async throws -> Void) async rethrows -> [String] {
        let recorder = Recorder()
        let previous = SQLDiagnostics.handler
        SQLDiagnostics.handler = { recorder.capture($0) }
        defer { SQLDiagnostics.handler = previous }
        try await body()
        return recorder.all
    }

    /// The point of the design: an unfiltered write is not a compile error and
    /// not a different method — it runs, and says so.
    @Test("an UPDATE with no WHERE runs and warns")
    func unfilteredUpdateWarns() async throws {
        let messages = try await capturing {
            _ = try await QueryBuilder<Postgres>()
                .update(s)
                .set(s.token, to: "rotated")
                .execute(on: FakeExecutor(affected: 4200))
        }
        #expect(messages.count == 1)
        #expect(messages[0].contains("UPDATE"))
        #expect(messages[0].contains("sessions"))
        // The count is the part that tells you whether this was the intended
        // full-table write.
        #expect(messages[0].contains("4200"))
    }

    @Test("a DELETE with no WHERE runs and warns")
    func unfilteredDeleteWarns() async throws {
        let messages = try await capturing {
            _ = try await QueryBuilder<Postgres>()
                .delete(from: s)
                .execute(on: FakeExecutor(affected: 1))
        }
        #expect(messages.count == 1)
        #expect(messages[0].contains("DELETE"))
        // Singular, because a warning that says "1 rows" reads as a bug in us
        // rather than a problem in the caller's query.
        #expect(messages[0].contains("1 row") && !messages[0].contains("1 rows"))
    }

    @Test("a filtered write says nothing")
    func filteredWriteIsSilent() async throws {
        let messages = try await capturing {
            _ = try await QueryBuilder<Postgres>()
                .update(s).set(s.token, to: "x").where(s.id == 1)
                .execute(on: FakeExecutor(affected: 1))
            _ = try await QueryBuilder<Postgres>()
                .delete(from: s).where(s.id == 1)
                .execute(on: FakeExecutor(affected: 1))
        }
        #expect(messages.isEmpty)
    }

    /// The call is spelled identically either way. That is the whole decision:
    /// no `.executeAllRows(on:)`, no method that appears only when you forgot a
    /// filter.
    @Test("filtered and unfiltered writes are the same call")
    func theCallDoesNotChangeShape() async throws {
        let executor = FakeExecutor(affected: 0)
        _ = try await capturing {
            let unfiltered = QueryBuilder<Postgres>().delete(from: s)
            let filtered = QueryBuilder<Postgres>().delete(from: s).where(s.id == 1)
            _ = try await unfiltered.execute(on: executor)
            _ = try await filtered.execute(on: executor)
        }
    }
}
