import NIOCore
import NIOPosix
import SwizzleCore
import SwizzlePostgresDriver
import Testing

/// The portal cursor: a row-limited `Execute` that actually resumes.
///
/// The ordinary stream holds the server in a blocking write while a slow consumer
/// catches up. A cursor leaves it **idle** between batches, at the cost of a round
/// trip each — which is the right trade when the consumer is slow or the result is
/// enormous, and the wrong one otherwise.
@Suite(
    "Postgres cursor", .serialized,
    .enabled(if: PostgresTestServer.isAvailable, PostgresTestServer.skipReason)
)
struct PostgresCursorTests {

    static let url = PostgresTestServer.url

    static func open() async throws -> PostgresConnection {
        try await PostgresConnection.connect(
            configuration: PostgresConnectionConfiguration(swizzleURL: url),
            on: MultiThreadedEventLoopGroup.singleton.next()
        )
    }

    @Test("a cursor reads a batch at a time and reaches the end")
    func batches() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await connection.withTransaction { db in
            let cursor = try await db.cursor(
                "SELECT g FROM generate_series(1, 25) g", batchSize: 10
            )

            var batches: [Int] = []
            var total = 0
            while true {
                let batch = try await cursor.next()
                if batch.isEmpty { break }
                batches.append(batch.count)
                total += batch.count
            }

            #expect(total == 25)
            // Three full-ish batches, not one big one — the point of the exercise.
            #expect(batches.count >= 3)
            #expect(batches.allSatisfy { $0 <= 10 })
        }
    }

    /// **No re-`Bind` between batches.** The portal holds its position, so binding
    /// again would restart it from the first row — an infinite loop that looks
    /// like a slow query rather than a bug.
    @Test("rows come back once each, in order")
    func noRestart() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await connection.withTransaction { db in
            let cursor = try await db.cursor(
                "SELECT g FROM generate_series(1, 30) g ORDER BY g", batchSize: 7
            )

            var seen: [Int64] = []
            while true {
                let batch = try await cursor.next()
                if batch.isEmpty { break }
                for row in batch {
                    guard case .int(let value) = row[0] else { continue }
                    seen.append(value)
                }
            }
            #expect(seen == Array(1...30).map(Int64.init))
        }
    }

    @Test("the row stream hides the batching")
    func streamed() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await connection.withTransaction { db in
            let cursor = try await db.cursor(
                "SELECT g FROM generate_series(1, 50) g", batchSize: 8
            )
            var count = 0
            for try await _ in cursor.rows { count += 1 }
            #expect(count == 50)
        }
    }

    @Test("columns are available and bindings work")
    func columnsAndBindings() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await connection.withTransaction { db in
            let cursor = try await db.cursor(
                "SELECT g AS n FROM generate_series(1, $1::int) g", [.int(5)], batchSize: 2
            )
            let first = try await cursor.next()
            #expect(cursor.schema?.columns.first?.name == "n")
            #expect(first.count == 2)
        }
    }

    /// An empty result must end rather than loop — the same shape that hung the
    /// row stream when a statement produced no `RowDescription`.
    @Test("an empty result terminates immediately")
    func empty() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await connection.withTransaction { db in
            let cursor = try await db.cursor(
                "SELECT g FROM generate_series(1, 0) g", batchSize: 10
            )
            let batch = try await cursor.next()
            #expect(batch.isEmpty)
            #expect(cursor.isExhausted)
        }
    }

    /// **Must be inside a transaction.** An unnamed portal dies with its
    /// statement's transaction, and outside an explicit one every statement is its
    /// own — so the portal would be gone before the second batch was asked for.
    /// Postgres reports that as "portal does not exist", which does not obviously
    /// mean "wrap this in a BEGIN".
    @Test("a cursor outside a transaction is refused with the reason")
    func needsATransaction() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        await #expect(throws: PostgresTransactionError.notInTransaction) {
            _ = try await connection.cursor("SELECT 1", batchSize: 10)
        }
    }

    /// A batch shorter than the limit is **not** the end signal — the server may
    /// return fewer rows than asked for and still have more. Only
    /// `CommandComplete` ends it.
    @Test("a short batch does not end the cursor early")
    func shortBatchIsNotTheEnd() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await connection.withTransaction { db in
            // 10 rows with a batch size of 4: 4, 4, 2, then done.
            let cursor = try await db.cursor(
                "SELECT g FROM generate_series(1, 10) g", batchSize: 4
            )
            var total = 0
            while true {
                let batch = try await cursor.next()
                if batch.isEmpty { break }
                total += batch.count
            }
            #expect(total == 10)
            #expect(cursor.isExhausted)
        }
    }

    /// The connection has to be usable the moment the cursor is done, rather than
    /// stuck mid-portal.
    @Test("the connection is clean after a cursor finishes")
    func connectionSurvives() async throws {
        let connection = try await Self.open()
        defer { connection.closeImmediately() }

        try await connection.withTransaction { db in
            let cursor = try await db.cursor(
                "SELECT g FROM generate_series(1, 5) g", batchSize: 2
            )
            while !(try await cursor.next()).isEmpty {}

            let rows = try await db.query("SELECT 42").rows
            #expect(rows[0][0] == .int(42))
        }

        let after = try await connection.query("SELECT 43").rows
        #expect(after[0][0] == .int(43))
    }
}
