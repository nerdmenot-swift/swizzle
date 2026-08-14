import Foundation
import SwizzleCore
import Testing

@testable import SwizzleSQLite
@testable import SwizzleSQLiteEngine

/// Reading a text column by *length* rather than as a C string.
///
/// SQLite's `sqlite3_column_text` returns a NUL-terminated pointer, and taking it
/// at its word is the obvious thing to do. It is also wrong: SQLite text may
/// contain embedded NUL bytes, and `sqlite3_column_bytes` is what says how long
/// the value really is. `rusqlite` builds its `&str` from
/// `from_raw_parts(text, sqlite3_column_bytes(...))` and quotes the SQLite book
/// on the point.
///
/// Reading it as a C string truncates at the first NUL and reports success, which
/// is data loss with no error attached.
@Suite("SQLite text encoding")
struct SQLiteTextEncodingTests {

    /// **The truncation.** A three-character value with a NUL in the middle came
    /// back as one character.
    @Test("text with an embedded NUL survives the round trip")
    func embeddedNulSurvives() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        // Built by SQLite rather than bound from Swift, so the value is
        // unambiguously what the engine holds and not an artefact of binding.
        //
        // Measured with `length(CAST(… AS BLOB))`, because `length()` on a *text*
        // value is documented to count "characters prior to the first NUL" — it
        // truncates in exactly the way being tested for, so it cannot be the
        // instrument. On a blob it counts bytes.
        let rows = try await connection.query(
            """
            SELECT 'a' || char(0) || 'b' AS v,
                   length(CAST('a' || char(0) || 'b' AS BLOB)) AS n
            """
        )
        #expect(rows[0].values[1] == .int(3), "SQLite should hold three bytes")

        guard case .text(let value) = rows[0].values[0] else {
            Issue.record("expected text, got \(rows[0].values[0])"); return
        }
        #expect(
            Array(value.utf8) == [0x61, 0x00, 0x62],
            "got \(Array(value.utf8)) — truncated at the NUL"
        )
    }

    /// And a value bound from Swift comes back intact too, which is the path an
    /// application actually takes.
    @Test("a bound string with an embedded NUL round-trips")
    func boundStringWithNul() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }
        _ = try await connection.query("CREATE TABLE t (v TEXT)")

        let original = "before\u{0}after"
        _ = try await connection.query("INSERT INTO t VALUES (?1)", [.text(original)])

        // Again by byte count, for the same reason as above.
        let rows = try await connection.query("SELECT v, length(CAST(v AS BLOB)) FROM t")
        #expect(rows[0].values[1] == .int(12), "the bind truncated at the NUL")
        #expect(rows[0].values[0] == .text(original))
    }

    /// The ordinary case must not regress: no NUL, no change.
    @Test("ordinary text is unaffected")
    func ordinaryText() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        let rows = try await connection.query("SELECT 'hello' AS v, '' AS empty")
        #expect(rows[0].values[0] == .text("hello"))
        #expect(rows[0].values[1] == .text(""))
    }

    /// Multi-byte UTF-8 is measured in bytes by `sqlite3_column_bytes` and in
    /// characters by `length()`, and conflating them would truncate every
    /// non-ASCII string.
    @Test("multi-byte UTF-8 is read by byte length, not character count")
    func multiByteText() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        for text in ["héllo", "日本語", "🇬🇧 flag", "e\u{0301}"] {
            let rows = try await connection.query("SELECT ?1 AS v", [.text(text)])
            #expect(rows[0].values[0] == .text(text), "\(text) did not survive")
        }
    }

    /// A blob that is not valid UTF-8, cast to text, must not lose bytes or
    /// crash. SQLite allows it; the decoder has to cope.
    @Test("invalid UTF-8 in a text column does not lose the row")
    func invalidUTF8() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        // 0xFF is never valid UTF-8.
        let rows = try await connection.query("SELECT CAST(x'61FF62' AS TEXT) AS v")
        guard case .text(let value) = rows[0].values[0] else {
            Issue.record("expected text, got \(rows[0].values[0])"); return
        }
        // Repaired rather than rejected: the alternative is failing a whole row
        // because one column has a stray byte, and the replacement character is
        // visible where a silent truncation would not be.
        #expect(value.contains("a"))
        #expect(value.contains("b"), "the byte after the invalid one was dropped")
    }

    /// Zero-length blobs are the other classic: `sqlite3_column_blob` returns
    /// NULL for them, which is not the same as the column being NULL.
    @Test("a zero-length blob is a blob, not a null")
    func zeroLengthBlob() async throws {
        let connection = try SQLiteConnection.inMemory()
        defer { connection.close() }

        let rows = try await connection.query("SELECT x'' AS v, NULL AS n")
        #expect(rows[0].values[0] == .blob([]))
        #expect(rows[0].values[1] == .null)
    }
}
