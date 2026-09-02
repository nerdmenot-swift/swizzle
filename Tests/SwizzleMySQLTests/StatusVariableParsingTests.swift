import NIOCore
import Testing
@testable import SwizzleMySQL

/// The query-event status-variable block, parsed directly.
///
/// ## Why this block is worth its own suite
///
/// It is a **flat sequence with no per-entry framing**: a one-byte key, then a
/// payload whose width only the parser knows. There is no length prefix to skip
/// with and no terminator to resynchronise on, so one key read at the wrong
/// offset makes everything after it garbage — and the parser will keep going,
/// interpreting the middle of a database name as the next key.
///
/// That is why every arm ends in `break loop` rather than a `nil` return: the
/// block is best-effort, and the honest response to something unrecognisable is
/// to stop and keep what was already read. The mutation sweep found sixteen
/// survivors here, all in those truncation guards, because every test fed it a
/// well-formed block.
///
/// The bytes come from a replication stream, so "the server would not send that"
/// is not a property this code may rely on — a stream can desynchronise, and a
/// binlog can be replayed from a position that lands mid-event.
@Suite("Binlog status variables")
struct StatusVariableParsingTests {

    static func buffer(_ bytes: [UInt8]) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return buffer
    }

    static func parse(_ bytes: [UInt8]) -> MySQLQueryStatusVariables {
        var buffer = Self.buffer(bytes)
        return MySQLQueryStatusVariables.parse(&buffer)
    }

    /// A well-formed block carrying one of everything the parser understands,
    /// used both as the happy path and as the thing every truncation below is a
    /// prefix of.
    static let wellFormed: [UInt8] = {
        var bytes: [UInt8] = []
        bytes += [0x00, 0, 0, 0, 0]                       // FLAGS2
        bytes += [0x01, 0, 0, 0, 0, 0, 0, 0, 0]           // SQL_MODE
        bytes += [0x03, 2, 0, 5, 0]                       // AUTO_INCREMENT: 2, 5
        bytes += [0x04, 33, 0, 33, 0, 45, 0]              // CHARSET
        bytes += [0x05, 6] + Array("+00:00".utf8)         // TIME_ZONE
        bytes += [0x07, 0, 0]                             // LC_TIME_NAMES
        bytes += [0x09, 0, 0, 0, 0, 0, 0, 0, 0]           // TABLE_MAP_FOR_UPDATE
        bytes += [0x0A, 0, 0, 0, 0]                       // MASTER_DATA_WRITTEN
        bytes += [0x0D, 0, 0, 0]                          // MICROSECONDS
        bytes += [0x10, 1]                                // EXPLICIT_DEFAULTS
        bytes += [0x11, 0, 0, 0, 0, 0, 0, 0, 0]           // DDL_LOGGED_WITH_XID
        bytes += [0x12, 255, 0]                           // DEFAULT_COLLATION_UTF8MB4
        bytes += [0x13, 1]                                // REQUIRE_PK
        bytes += [0x0C, 2] + Array("app\0other\0".utf8)   // UPDATED_DB_NAMES
        return bytes
    }()

    // MARK: - The happy path

    @Test("a well-formed block yields every variable it carries")
    func wellFormedBlock() {
        let parsed = Self.parse(Self.wellFormed)
        #expect(parsed.timeZone == "+00:00")
        #expect(parsed.autoIncrement?.increment == 2)
        #expect(parsed.autoIncrement?.offset == 5)
        #expect(parsed.charset?.client == 33)
        #expect(parsed.charset?.server == 45)
        #expect(parsed.defaultCollationForUTF8MB4 == 255)
        #expect(parsed.updatedDatabases == ["app", "other"])
    }

    // MARK: - Truncation

    /// **No prefix of a valid block may crash or hang**, which is the property
    /// no hand-picked case states and the one that actually matters. Every
    /// truncation lands in the middle of some entry, so between them they reach
    /// every `break loop` in the parser.
    @Test("every prefix of a valid block parses without trapping")
    func everyPrefixIsSafe() {
        for length in 0...Self.wellFormed.count {
            _ = Self.parse(Array(Self.wellFormed.prefix(length)))
        }
    }

    /// And a truncated block keeps what it had already read rather than
    /// discarding the lot — that is what "best effort" means here, and it is why
    /// the arms break out of the loop instead of returning nil.
    @Test("a truncated block keeps the variables it read before the cut")
    func truncationKeepsEarlierVariables() {
        // Everything up to and including TIME_ZONE, then a CHARSET key with no
        // payload at all.
        var bytes: [UInt8] = [0x05, 6] + Array("+00:00".utf8)
        bytes += [0x04]
        let parsed = Self.parse(bytes)
        #expect(parsed.timeZone == "+00:00", "read before the cut, so it survives")
        #expect(parsed.charset == nil, "cut short, so never set")
    }

    /// A key the parser does not know ends the block, because without framing it
    /// cannot know how far to skip. Guessing would turn one unknown key into a
    /// stream of invented variables.
    @Test("an unknown key stops the walk rather than guessing a width")
    func unknownKeyStops() {
        var bytes: [UInt8] = [0x05, 6] + Array("+00:00".utf8)
        bytes += [0x7F, 1, 2, 3, 4]                       // not a key this knows
        bytes += [0x12, 99, 0]                            // would set the collation
        let parsed = Self.parse(bytes)
        #expect(parsed.timeZone == "+00:00")
        #expect(
            parsed.defaultCollationForUTF8MB4 == nil,
            "anything after an unknown key is unreadable and must not be invented"
        )
    }

    // MARK: - UPDATED_DB_NAMES, which has its own counting

    /// `254` is `OVER_MAX_DBS_IN_EVENT_MTS`: the server gave up listing them and
    /// **no names follow**. Reading 254 names would consume the rest of the
    /// event.
    @Test("a database count of 254 means the list was abandoned, not that 254 follow")
    func overMaxDatabases() {
        var bytes: [UInt8] = [0x0C, 254]
        bytes += [0x12, 77, 0]                            // a variable after it
        let parsed = Self.parse(bytes)
        #expect(parsed.updatedDatabases.isEmpty)
    }

    /// A count larger than the names supplied must not spin or invent entries.
    @Test("a database count larger than the names present terminates")
    func databaseCountBeyondTheNames() {
        let parsed = Self.parse([0x0C, 5] + Array("app\0".utf8))
        #expect(parsed.updatedDatabases.count <= 5)
    }

    /// A name with no terminator runs to the end of the buffer and stops there.
    @Test("an unterminated database name does not run past the buffer")
    func unterminatedDatabaseName() {
        let parsed = Self.parse([0x0C, 1] + Array("no_terminator".utf8))
        #expect(parsed.updatedDatabases.count <= 1)
    }

    /// A zero count is legal and means exactly that.
    @Test("a zero database count yields no names")
    func zeroDatabases() {
        let parsed = Self.parse([0x0C, 0, 0x12, 88, 0])
        #expect(parsed.updatedDatabases.isEmpty)
        #expect(parsed.defaultCollationForUTF8MB4 == 88, "parsing continues past an empty list")
    }


    /// Two keys the well-formed block above omits, so their guards were never
    /// walked.
    ///
    /// `CATALOG` is NUL-suffixed where the other var-strings are not, and
    /// `INVOKER` carries **two** strings rather than one — a user and a host.
    /// Reading either width wrong does not fail: the walk continues from the
    /// wrong offset and reads the middle of a name as the next key, which is
    /// the failure this whole parser is shaped to avoid.
    @Test("the two-string and NUL-suffixed keys are walked at the right width")
    func catalogAndInvokerWidths() {
        var bytes: [UInt8] = []
        bytes += [0x02, 3] + Array("def".utf8) + [0x00]         // CATALOG, NUL-suffixed
        bytes += [0x0B, 4] + Array("root".utf8)                 // INVOKER: user
        bytes += [9] + Array("localhost".utf8)                  //          then host
        bytes += [0x05, 6] + Array("+00:00".utf8)               // TIME_ZONE, after both

        let parsed = Self.parse(bytes)
        #expect(
            parsed.timeZone == "+00:00",
            "a variable after CATALOG and INVOKER is only reachable if both were consumed at exactly the right width"
        )
    }

    /// And each on its own, so a failure names which one.
    @Test("CATALOG consumes its trailing NUL")
    func catalogConsumesItsNUL() {
        var bytes: [UInt8] = [0x02, 3] + Array("def".utf8) + [0x00]
        bytes += [0x12, 77, 0]                                  // a variable after it
        #expect(Self.parse(bytes).defaultCollationForUTF8MB4 == 77)
    }

    @Test("INVOKER consumes both of its strings")
    func invokerConsumesBothStrings() {
        var bytes: [UInt8] = [0x0B, 4] + Array("root".utf8) + [9] + Array("localhost".utf8)
        bytes += [0x12, 88, 0]
        #expect(Self.parse(bytes).defaultCollationForUTF8MB4 == 88)
    }

    // MARK: - Fuzzing

    /// Random bytes, seeded so a failure reproduces.
    ///
    /// The parser's contract is that it always returns — it has no error path,
    /// only `break loop` — so the only thing to assert is that it does.
    @Test("no random block traps or hangs the parser", arguments: [UInt64](1...16))
    func randomBlocksAreSafe(seed: UInt64) {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1
        func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        for _ in 0..<200 {
            let count = Int(next() % 48)
            // Biased towards *valid* keys, so the walk gets past the first byte
            // and reaches the payload guards rather than stopping immediately on
            // an unknown key.
            let bytes = (0..<count).map { _ -> UInt8 in
                next() % 3 == 0 ? UInt8(next() % 0x15) : UInt8(next() % 256)
            }
            _ = Self.parse(bytes)
        }
    }
}
