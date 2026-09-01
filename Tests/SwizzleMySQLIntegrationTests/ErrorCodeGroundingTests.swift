import Foundation
import Testing
@testable import SwizzleMySQL

/// Provokes real failures and checks the driver classifies what the server
/// actually sent.
///
/// ## Why the unit tests are not enough
///
/// `MySQLErrorMappingTests` asserts that code 1969 is a timeout. It cannot
/// assert that 1969 is *the code a MariaDB server sends* when a statement
/// exceeds its time limit — that is a fact about the servers, and writing it
/// down from an error table is how it goes stale or starts out wrong.
///
/// It did start out wrong. MySQL's `max_execution_time` reports 3024 and was
/// mapped; MariaDB's `max_statement_time` reports **1969** and was not, so on
/// three of the six fixtures a statement timeout arrived as `.other` — not
/// transient, not recognisable as a timeout by anything deciding what to do
/// about it. Nothing caught it because nothing had ever timed a statement out.
///
/// So each case here makes the server produce the failure and checks the
/// classification of whatever comes back, naming the code only in the message.
@Suite(
    "MySQL error codes, grounded",
    .enabled(
        if: TestServers.isAvailable,
        "Integration servers not reachable — start them with ./Scripts/test-servers.sh up"
    )
)
struct ErrorCodeGroundingTests {

    static func connect(_ server: MySQLTestServer) async throws -> MySQLConnection {
        try await TestServers.connect(server)
    }

    /// A statement that runs long enough to be cut off, under whichever
    /// deadline this flavour implements.
    @Test("a statement timeout is classified as a timeout on every server",
          arguments: TestServers.all)
    func statementTimeout(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        // A self-join over information_schema is reliably slow and, unlike
        // SLEEP, is interruptible by MySQL's execution-time limit.
        let heavy = """
            SELECT COUNT(*) FROM information_schema.columns a, \
            information_schema.columns b
            """
        do {
            switch server.flavor {
            case .mysql:
                _ = try await connection.query("SET SESSION max_execution_time = 20")
            case .mariaDB:
                _ = try await connection.query("SET SESSION max_statement_time = 0.02")
            }
            _ = try await connection.query(heavy)
            Issue.record("\(server): the statement was not interrupted")
        } catch let error as MySQLProtocolError {
            #expect(
                error.sqlKind == .timeout,
                Comment(rawValue: "\(server): code \(error.nativeCode as Any) "
                    + "classified as \(error.sqlKind) rather than .timeout")
            )
            #expect(error.sqlKind.isTransient, "\(server)")
        }
    }

    /// A duplicate key, which is the classification callers most often branch
    /// on and the one an upsert path depends on.
    @Test("a duplicate key is classified as a unique violation on every server",
          arguments: TestServers.all)
    func duplicateKey(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let table = "dup_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await connection.query("CREATE TABLE \(table) (id INT PRIMARY KEY)")
        _ = try await connection.query("INSERT INTO \(table) VALUES (1)")
        do {
            _ = try await connection.query("INSERT INTO \(table) VALUES (1)")
            Issue.record("\(server): the duplicate was accepted")
        } catch let error as MySQLProtocolError {
            #expect(
                error.sqlKind == .uniqueViolation,
                Comment(rawValue: "\(server): code \(error.nativeCode as Any)")
            )
            #expect(!error.isSafeToRetry, "retrying a duplicate cannot help")
        }
        _ = try? await connection.query("DROP TABLE IF EXISTS \(table)")
    }

    /// The other constraint kinds, each provoked rather than asserted.
    @Test("constraint failures are classified from what the server sends",
          arguments: TestServers.all)
    func constraintKinds(server: MySQLTestServer) async throws {
        let connection = try await Self.connect(server)
        defer { connection.closeImmediately() }

        let parent = "parent_\(UInt32.random(in: 0..<UInt32.max))"
        let child = "child_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await connection.query("CREATE TABLE \(parent) (id INT PRIMARY KEY)")
        _ = try await connection.query(
            """
            CREATE TABLE \(child) (
                id INT PRIMARY KEY,
                parent_id INT,
                required INT NOT NULL,
                FOREIGN KEY (parent_id) REFERENCES \(parent)(id)
            )
            """
        )

        // A foreign key with no parent row.
        do {
            _ = try await connection.query(
                "INSERT INTO \(child) VALUES (1, 999, 1)"
            )
            Issue.record("\(server): the orphan was accepted")
        } catch let error as MySQLProtocolError {
            #expect(
                error.sqlKind == .foreignKeyViolation,
                Comment(rawValue: "\(server): code \(error.nativeCode as Any)")
            )
        }

        // A NOT NULL column with no value and no default.
        do {
            _ = try await connection.query(
                "INSERT INTO \(child) (id, parent_id, required) VALUES (2, NULL, NULL)"
            )
            Issue.record("\(server): the null was accepted")
        } catch let error as MySQLProtocolError {
            #expect(
                error.sqlKind == .notNullViolation,
                Comment(rawValue: "\(server): code \(error.nativeCode as Any)")
            )
        }

        // A table that is not there.
        do {
            _ = try await connection.query("SELECT * FROM definitely_not_a_table_here")
            Issue.record("\(server): the missing table was accepted")
        } catch let error as MySQLProtocolError {
            #expect(
                error.sqlKind == .syntax,
                Comment(rawValue: "\(server): code \(error.nativeCode as Any)")
            )
        }

        _ = try? await connection.query("DROP TABLE IF EXISTS \(child)")
        _ = try? await connection.query("DROP TABLE IF EXISTS \(parent)")
    }

    /// A deadlock, which is the one server error the driver will retry
    /// automatically — so its classification is the one with consequences.
    @Test("a deadlock is classified as safe to retry", arguments: [TestServers.latest])
    func deadlock(server: MySQLTestServer) async throws {
        let setup = try await Self.connect(server)
        defer { setup.closeImmediately() }

        let table = "deadlock_\(UInt32.random(in: 0..<UInt32.max))"
        _ = try await setup.query("CREATE TABLE \(table) (id INT PRIMARY KEY, v INT) ENGINE=InnoDB")
        _ = try await setup.query("INSERT INTO \(table) VALUES (1, 0), (2, 0)")

        let first = try await Self.connect(server)
        defer { first.closeImmediately() }
        let second = try await Self.connect(server)
        defer { second.closeImmediately() }

        _ = try await first.query("BEGIN")
        _ = try await second.query("BEGIN")
        // Each takes one row, then reaches for the other's — the classic cycle.
        _ = try await first.query("UPDATE \(table) SET v = 1 WHERE id = 1")
        _ = try await second.query("UPDATE \(table) SET v = 1 WHERE id = 2")

        // Whichever loses is the victim; the other completes.
        async let firstReach: Void = {
            _ = try? await first.query("UPDATE \(table) SET v = 2 WHERE id = 2")
        }()
        var victim: MySQLProtocolError?
        do {
            _ = try await second.query("UPDATE \(table) SET v = 2 WHERE id = 1")
        } catch let error as MySQLProtocolError {
            victim = error
        }
        await firstReach

        if let victim {
            #expect(
                victim.sqlKind == .deadlock || victim.sqlKind == .lockTimeout,
                Comment(rawValue: "code \(victim.nativeCode as Any)")
            )
            #expect(
                victim.isSafeToRetry,
                "InnoDB rolled the victim back, so this is the one retryable failure"
            )
        }

        _ = try? await first.query("ROLLBACK")
        _ = try? await second.query("ROLLBACK")
        _ = try? await setup.query("DROP TABLE IF EXISTS \(table)")
    }
}
