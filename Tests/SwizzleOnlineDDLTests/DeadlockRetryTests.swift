import Foundation
import Testing
@testable import SwizzleMySQL
@testable import SwizzleOnlineDDL

/// The retry that stands between a transient InnoDB deadlock and an abandoned
/// migration.
///
/// ## Why this is a unit test and not an integration one
///
/// A deadlock is exactly the thing you cannot ask for on demand. It needs three
/// writers to interleave on overlapping key ranges in an order InnoDB decides,
/// and a test that waits for one is a test that passes when the machine happens
/// to be slow — which is how this bug reached CI in the first place, showing up
/// only on the run where nine fixture servers made the windows wide enough to
/// overlap.
///
/// The behaviour worth pinning is deterministic even though the trigger is not:
/// which error codes are retried, how many times, and — most importantly — which
/// errors are **not** retried. A retry loop that swallows a genuine failure turns
/// a clear error into a slow one, and that is the more expensive mistake.
///
/// `MySQLOnlineDDL` is built here with a `connect` closure that is never called.
/// `withDeadlockRetry` takes a body and does not touch the connection, so a
/// runner that could not connect if it tried is the honest way to test it
/// without a server.
@Suite("Online DDL deadlock retry")
struct DeadlockRetryTests {

    static func runner(
        retries: Int = 10, delay: Duration = .microseconds(1)
    ) -> MySQLOnlineDDL {
        var configuration = MySQLOnlineDDL.Configuration()
        configuration.deadlockRetries = retries
        // Microseconds, not the 50 ms default: this suite is about the decision,
        // not the backoff, and the real delay doubles to seconds by attempt ten.
        configuration.deadlockRetryDelay = delay
        return MySQLOnlineDDL(
            connect: {
                Issue.record("withDeadlockRetry must not open a connection")
                throw OnlineDDLError.failed("unreachable")
            },
            configuration: configuration
        )
    }

    static func deadlock() -> MySQLProtocolError {
        .server(code: 1213, sqlState: "40001", message: "Deadlock found when trying to get lock")
    }

    static func lockWaitTimeout() -> MySQLProtocolError {
        .server(code: 1205, sqlState: "HY000", message: "Lock wait timeout exceeded")
    }

    // MARK: - What is retried

    /// The case the whole thing exists for: lose a deadlock, try again, succeed.
    @Test("a deadlock is retried until it succeeds")
    func retriesUntilItSucceeds() async throws {
        let attempts = Counter()
        let result = try await Self.runner().withDeadlockRetry("a chunk") {
            if attempts.increment() < 3 { throw Self.deadlock() }
            return "copied"
        }
        #expect(result == "copied")
        #expect(attempts.value == 3, "it should have taken exactly three attempts")
    }

    /// `ER_LOCK_WAIT_TIMEOUT` is the other transient one — no cycle, just a lock
    /// held longer than `innodb_lock_wait_timeout`. Same answer, and it was worth
    /// covering separately because it is a different code on a different path.
    @Test("a lock wait timeout is retried too")
    func retriesLockWaitTimeout() async throws {
        let attempts = Counter()
        let result = try await Self.runner().withDeadlockRetry("a chunk") {
            if attempts.increment() < 2 { throw Self.lockWaitTimeout() }
            return 42
        }
        #expect(result == 42)
    }

    /// Succeeding first time must not sleep, retry, or otherwise do anything.
    @Test("a statement that works is run exactly once")
    func happyPathRunsOnce() async throws {
        let attempts = Counter()
        _ = try await Self.runner().withDeadlockRetry("a chunk") { attempts.increment() }
        #expect(attempts.value == 1)
    }

    // MARK: - What is not

    /// **The important half.** A duplicate key does not become less true by being
    /// run again, and a retry loop that swallows it turns a clear failure into a
    /// slow one and then a confusing one.
    @Test("an ordinary server error is not retried")
    func realErrorsPropagate() async throws {
        let attempts = Counter()
        await #expect(throws: MySQLProtocolError.self) {
            try await Self.runner().withDeadlockRetry("a chunk") {
                _ = attempts.increment()
                throw MySQLProtocolError.server(
                    code: 1062, sqlState: "23000", message: "Duplicate entry '1' for key 'PRIMARY'"
                )
            }
        }
        #expect(attempts.value == 1, "a duplicate key must not be retried even once")
    }

    /// Anything that is not a server error at all — a closed connection, a codec
    /// failure — is likewise not a deadlock and must come straight out.
    @Test("a non-server error is not retried")
    func nonServerErrorsPropagate() async throws {
        let attempts = Counter()
        await #expect(throws: MySQLProtocolError.self) {
            try await Self.runner().withDeadlockRetry("a chunk") {
                _ = attempts.increment()
                throw MySQLProtocolError.connectionClosed("gone")
            }
        }
        #expect(attempts.value == 1)
    }

    // MARK: - Giving up

    /// Bounded, and the error says which of the three ways out to take. An
    /// unbounded retry against a genuinely contended table is a migration that
    /// never finishes and never says why.
    @Test("it gives up after the configured number of attempts")
    func givesUpEventually() async throws {
        let attempts = Counter()
        await #expect(throws: OnlineDDLError.self) {
            try await Self.runner(retries: 3).withDeadlockRetry("a chunk") {
                _ = attempts.increment()
                throw Self.deadlock()
            }
        }
        // Three retries after the first attempt.
        #expect(attempts.value == 4, "expected 1 attempt plus 3 retries, got \(attempts.value)")
    }

    /// The message has to name the cause and the remedy. "Deadlock" alone sends
    /// an operator looking for a bug in their schema.
    @Test("the give-up error explains itself")
    func giveUpMessageIsUseful() async throws {
        do {
            _ = try await Self.runner(retries: 1).withDeadlockRetry("the chunk copy") {
                throw Self.deadlock()
            }
            Issue.record("it should have given up")
        } catch let error as OnlineDDLError {
            let text = "\(error)"
            #expect(text.contains("the chunk copy"), "the message should name what failed")
            #expect(text.contains("1213"), "the message should carry the server's code")
            #expect(text.contains("chunkSize") || text.contains("deadlockRetries"))
            #expect(text.contains("Nothing was swapped"), "it should say the table is untouched")
        }
    }
}

/// A counter the escaping closures above can share.
///
/// `NSLock` rather than an actor: `withDeadlockRetry` takes a non-async closure
/// body in the sense that it does not await the counter, and making this an actor
/// would force every call site into an `await` that has nothing to do with what
/// is being tested.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}
