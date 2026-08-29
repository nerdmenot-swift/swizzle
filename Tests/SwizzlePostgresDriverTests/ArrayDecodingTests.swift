import NIOCore
import SwizzleCore
import Testing
@testable import SwizzlePostgresDriver

@Suite("Postgres array decoding")
struct ArrayDecodingTests {

    /// Builds a binary array the way the server does: dimension count, null flag,
    /// element OID, then `(length, lowerBound)` per dimension, then each element
    /// length-prefixed.
    func binary(
        elementOID: PostgresOID,
        dimensions: [(length: Int32, lowerBound: Int32)],
        elements: [[UInt8]?]
    ) -> [UInt8] {
        var buffer = ByteBufferAllocator().buffer(capacity: 64)
        buffer.writeInteger(Int32(dimensions.count))
        buffer.writeInteger(Int32(elements.contains { $0 == nil } ? 1 : 0))
        buffer.writeInteger(elementOID.rawValue)
        for dimension in dimensions {
            buffer.writeInteger(dimension.length)
            buffer.writeInteger(dimension.lowerBound)
        }
        for element in elements {
            guard let element else {
                buffer.writeInteger(Int32(-1))
                continue
            }
            buffer.writeInteger(Int32(element.count))
            buffer.writeBytes(element)
        }
        return buffer.readBytes(length: buffer.readableBytes)!
    }

    func int8(_ value: Int64) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }

    // MARK: - Binary

    @Test("a one-dimensional binary array decodes its elements")
    func binaryOneDimension() {
        let array = PostgresArrayDecoder.decodeBinary(
            binary(
                elementOID: .int8, dimensions: [(3, 1)],
                elements: [int8(1), int8(2), int8(3)]
            )
        )
        #expect(array?.elements == [.int(1), .int(2), .int(3)])
        #expect(array?.elementOID == PostgresOID.int8.rawValue)
        #expect(array?.dimensions.count == 1)
    }

    /// An array may contain NULL even when the column itself is `NOT NULL`.
    @Test("nulls inside an array are preserved")
    func binaryNulls() {
        let array = PostgresArrayDecoder.decodeBinary(
            binary(elementOID: .int8, dimensions: [(3, 1)], elements: [int8(1), nil, int8(3)])
        )
        #expect(array?.elements == [.int(1), .null, .int(3)])
    }

    /// The empty array carries nothing after the header — not even a dimension
    /// entry — so reading one would run off the end.
    @Test("the empty array has zero dimensions and no elements")
    func binaryEmpty() {
        let array = PostgresArrayDecoder.decodeBinary(
            binary(elementOID: .text, dimensions: [], elements: [])
        )
        #expect(array?.isEmpty == true)
        #expect(array?.dimensions.isEmpty == true)
        #expect(array?.textRepresentation == "{}")
    }

    @Test("multi-dimensional arrays keep their shape")
    func binaryTwoDimensions() {
        let array = PostgresArrayDecoder.decodeBinary(
            binary(
                elementOID: .int8, dimensions: [(2, 1), (3, 1)],
                elements: [int8(1), int8(2), int8(3), int8(4), int8(5), int8(6)]
            )
        )
        #expect(array?.elements.count == 6)
        #expect(array?.dimensions.map(\.length) == [2, 3])
        #expect(array?.textRepresentation == "{{1,2,3},{4,5,6}}")
    }

    /// The element OID is on the wire, which is why the decoder needs no help
    /// identifying what it is reading.
    @Test("the element type comes from the wire, not the column")
    func elementTypeFromWire() {
        let array = PostgresArrayDecoder.decodeBinary(
            binary(elementOID: .bool, dimensions: [(2, 1)], elements: [[1], [0]])
        )
        #expect(array?.elements == [.bool(true), .bool(false)])
    }

    @Test("malformed input is rejected rather than half-read")
    func malformed() {
        // Claims three elements and supplies one.
        #expect(
            PostgresArrayDecoder.decodeBinary(
                binary(elementOID: .int8, dimensions: [(3, 1)], elements: [int8(1)])
            ) == nil
        )
        #expect(PostgresArrayDecoder.decodeBinary([0, 0]) == nil)
    }

    // MARK: - Text

    @Test("a text array parses")
    func textSimple() {
        let array = PostgresArrayDecoder.decodeText(
            Array("{1,2,3}".utf8), elementOID: PostgresOID.int8.rawValue
        )
        #expect(array?.elements == [.int(1), .int(2), .int(3)])
        #expect(array?.dimensions.map(\.length) == [3])
    }

    /// **The distinction that is silent when lost.** An unquoted `NULL` is a SQL
    /// null; a quoted `"NULL"` is the four-character string.
    @Test("quoted NULL is a string and unquoted NULL is a null")
    func nullVersusTheWordNull() {
        let array = PostgresArrayDecoder.decodeText(
            Array(#"{NULL,"NULL"}"#.utf8), elementOID: PostgresOID.text.rawValue
        )
        #expect(array?.elements == [.null, .text("NULL")])
    }

    @Test("quotes, commas, braces and backslashes survive a round trip")
    func quoting() {
        let array = PostgresArrayDecoder.decodeText(
            Array(#"{"a,b","c\"d","{e}","f\\g"}"#.utf8),
            elementOID: PostgresOID.text.rawValue
        )
        #expect(array?.elements == [.text("a,b"), .text("c\"d"), .text("{e}"), .text("f\\g")])

        // And rendering them back quotes exactly what has to be quoted.
        #expect(array?.textRepresentation == #"{"a,b","c\"d","{e}","f\\g"}"#)
    }

    @Test("an empty string element is quoted, not mistaken for nothing")
    func emptyStringElement() {
        let array = PostgresArray(
            elementOID: PostgresOID.text.rawValue,
            dimensions: [.init(length: 2, lowerBound: 1)],
            elements: [.text(""), .text("a")]
        )
        #expect(array.textRepresentation == #"{"",a}"#)
        let reparsed = PostgresArrayDecoder.decodeText(
            Array(array.textRepresentation.utf8), elementOID: PostgresOID.text.rawValue
        )
        #expect(reparsed?.elements == [.text(""), .text("a")])
    }

    @Test("nested text arrays parse and keep their dimensions")
    func textNested() {
        let array = PostgresArrayDecoder.decodeText(
            Array("{{1,2},{3,4}}".utf8), elementOID: PostgresOID.int8.rawValue
        )
        #expect(array?.elements == [.int(1), .int(2), .int(3), .int(4)])
        #expect(array?.dimensions.map(\.length) == [2, 2])
    }

    @Test("an empty text array parses")
    func textEmpty() {
        let array = PostgresArrayDecoder.decodeText(
            Array("{}".utf8), elementOID: PostgresOID.int8.rawValue
        )
        #expect(array?.elements.isEmpty == true)
    }

    /// `'[3:5]={a,b,c}'` is a one-dimensional array whose first index is 3.
    /// Dropping the prefix would silently rebase every index.
    @Test("an explicit lower bound is honoured")
    func explicitLowerBound() {
        let array = PostgresArrayDecoder.decodeText(
            Array("[3:5]={a,b,c}".utf8), elementOID: PostgresOID.text.rawValue
        )
        #expect(array?.elements == [.text("a"), .text("b"), .text("c")])
        #expect(array?.dimensions.first?.lowerBound == 3)
        #expect(array?.dimensions.first?.length == 3)
    }

    // MARK: - Through the value decoder

    /// Before this, an array column degraded to raw bytes — while the type map
    /// promised the generator `[Int64]`. The two now agree.
    @Test("an array column no longer degrades to bytes")
    func arrayColumnDecodes() {
        let bytes = binary(
            elementOID: .int8, dimensions: [(2, 1)], elements: [int8(10), int8(20)]
        )
        let value = PostgresValueDecoder.decode(
            bytes, oid: PostgresOID.int8Array.rawValue, format: 1
        )
        #expect(value == .text("{10,20}"))
    }

    /// A column decodes identically whichever format it arrived in — the same
    /// contract `numeric` and the temporals keep.
    @Test("binary and text arrays agree")
    func formatsAgree() {
        let fromBinary = PostgresValueDecoder.decode(
            binary(elementOID: .text, dimensions: [(2, 1)],
                   elements: [Array("a".utf8), Array("b,c".utf8)]),
            oid: PostgresOID.textArray.rawValue, format: 1
        )
        let fromText = PostgresValueDecoder.decode(
            Array(#"{a,"b,c"}"#.utf8), oid: PostgresOID.textArray.rawValue, format: 0
        )
        #expect(fromBinary == fromText)
    }

    @Test("a row hands back array elements on request")
    func rowArrayAccessor() {
        let column = PostgresColumnDescription(
            name: "tags", tableOID: 1, columnAttributeNumber: 1,
            dataTypeOID: PostgresOID.textArray.rawValue, dataTypeSize: -1,
            dataTypeModifier: -1, format: 1
        )
        let row = PostgresRow(values: [.text(#"{a,b}"#)], columns: [column])

        #expect(row.array(named: "tags")?.elements == [.text("a"), .text("b")])
        // A non-array column reports nothing rather than guessing.
        #expect(row.array(at: 0) != nil)
        #expect(row.array(named: "missing") == nil)
    }

    // MARK: - Malformed text

    /// The text scanner had no malformed-input coverage at all, and the mutation
    /// sweep found ten survivors in it — every one an `index < characters.count`
    /// bounds check.
    ///
    /// `malformed()` above is binary-only. Every text test feeds a well-formed
    /// array, and a well-formed array never reaches a bounds check by definition:
    /// the guards exist for input that stops early, and only a truncated or
    /// hostile value gets there.
    ///
    /// This matters more than the equivalent binary gap because the text path is
    /// a **hand-written recursive character scanner**. A missed bound is an
    /// out-of-range crash or a loop that does not terminate, on a value the
    /// server composed — and `decodeText` is reached for any array type whose
    /// binary decoder the driver does not have.
    ///
    /// The truncation sweep is the load-bearing test here rather than the
    /// individual cases: **no prefix of a valid array may crash or hang**, which
    /// is a property no single hand-picked input states.
    @Test("no prefix of a valid array crashes or hangs the scanner")
    func everyTruncationIsSafe() {
        let valid = #"{{"a,b",NULL,"c\"d"},{x,"",z}}"#
        let characters = Array(valid.utf8)
        for length in 0...characters.count {
            // The result may be a value or nil; what it may not do is trap or
            // fail to return.
            _ = PostgresArrayDecoder.decodeText(
                Array(characters.prefix(length)), elementOID: 25
            )
        }
    }

    /// The same for the explicit lower-bound prefix, which is a second scanner
    /// ahead of the first: `[3:5]={a,b,c}`.
    @Test("no prefix of a bounds-prefixed array crashes the scanner")
    func everyTruncationOfBoundsPrefixIsSafe() {
        let characters = Array("[3:5]={a,b,c}".utf8)
        for length in 0...characters.count {
            _ = PostgresArrayDecoder.decodeText(
                Array(characters.prefix(length)), elementOID: 25
            )
        }
    }

    /// A quote that never closes — the scanner runs to the end looking for its
    /// partner and must report failure rather than read past it.
    @Test("an unterminated quoted element is refused")
    func unterminatedQuote() {
        #expect(PostgresArrayDecoder.decodeText(Array(#"{"abc"#.utf8), elementOID: 25) == nil)
    }

    /// A backslash as the final character, where the escape consumes the byte
    /// that is not there. Both the quoted and unquoted branches have this, and
    /// each had its own survivor.
    @Test("a trailing escape is refused in both quoted and unquoted elements")
    func trailingEscape() {
        #expect(PostgresArrayDecoder.decodeText(Array(#"{"a\"#.utf8), elementOID: 25) == nil)
        #expect(PostgresArrayDecoder.decodeText(Array(#"{a\"#.utf8), elementOID: 25) == nil)
    }

    /// Braces that never close, at the outer level and nested.
    @Test("unclosed braces are refused")
    func unclosedBraces() {
        #expect(PostgresArrayDecoder.decodeText(Array("{".utf8), elementOID: 25) == nil)
        #expect(PostgresArrayDecoder.decodeText(Array("{a,b".utf8), elementOID: 25) == nil)
        #expect(PostgresArrayDecoder.decodeText(Array("{{1,2}".utf8), elementOID: 25) == nil)
        #expect(PostgresArrayDecoder.decodeText(Array("{{1,2},{3,4}".utf8), elementOID: 25) == nil)
    }

    /// A separator where a value should be, and a value where a separator should
    /// be — the two ways the element loop can be handed something it cannot use.
    @Test("a malformed separator is refused rather than skipped")
    func malformedSeparators() {
        #expect(PostgresArrayDecoder.decodeText(Array(#"{"a" "b"}"#.utf8), elementOID: 25) == nil)
        #expect(PostgresArrayDecoder.decodeText(Array("".utf8), elementOID: 25) == nil)
        #expect(PostgresArrayDecoder.decodeText(Array("not an array".utf8), elementOID: 25) == nil)
    }

    // MARK: - Malformed binary

    /// The binary header declares how many dimensions follow. Six is the server's
    /// own limit, and the guard is `<=` — so six must be accepted and seven
    /// refused, which is the boundary the mutant moves.
    @Test("the dimension limit admits six and refuses seven")
    func dimensionLimit() {
        func header(dimensions: Int) -> [UInt8] {
            var bytes: [UInt8] = []
            bytes += withUnsafeBytes(of: Int32(dimensions).bigEndian) { Array($0) }
            bytes += withUnsafeBytes(of: Int32(0).bigEndian) { Array($0) }      // flags
            bytes += withUnsafeBytes(of: UInt32(25).bigEndian) { Array($0) }    // element OID
            for _ in 0..<dimensions {
                bytes += withUnsafeBytes(of: Int32(0).bigEndian) { Array($0) }  // length
                bytes += withUnsafeBytes(of: Int32(1).bigEndian) { Array($0) }  // lower bound
            }
            return bytes
        }
        #expect(PostgresArrayDecoder.decodeBinary(header(dimensions: 6)) != nil)
        #expect(PostgresArrayDecoder.decodeBinary(header(dimensions: 7)) == nil)
    }

}
