import NIOCore
import SwizzleCore

/// A decoded Postgres array.
///
/// Postgres arrays are genuinely multi-dimensional and genuinely
/// arbitrarily-based — `'[3:5]={a,b,c}'` is a one-dimensional array whose first
/// index is 3 — so the dimensions are kept rather than flattened away. Most
/// arrays are one-dimensional and one-based, and `elements` is all those callers
/// need; the rest is there so the ones that are not do not silently lose their
/// shape.
public struct PostgresArray: Sendable, Equatable {

    public struct Dimension: Sendable, Equatable {
        public var length: Int32
        /// Almost always 1. Postgres allows any base, and an array declared with
        /// another one indexes from there.
        public var lowerBound: Int32

        public init(length: Int32, lowerBound: Int32) {
            self.length = length
            self.lowerBound = lowerBound
        }
    }

    public var elementOID: UInt32
    public var dimensions: [Dimension]
    /// Row-major, with `.null` for SQL NULL — which an array may contain even
    /// when the column itself is `NOT NULL`.
    public var elements: [SQLValue]

    public init(
        elementOID: UInt32, dimensions: [Dimension] = [], elements: [SQLValue] = []
    ) {
        self.elementOID = elementOID
        self.dimensions = dimensions
        self.elements = elements
    }

    public var isEmpty: Bool { elements.isEmpty }
    public var count: Int { elements.count }
}

/// Reads Postgres's array wire formats.
public enum PostgresArrayDecoder {

    /// Decodes an array column in either format.
    public static func decode(_ bytes: [UInt8], oid: UInt32, format: Int16) -> PostgresArray? {
        let elementOID = PostgresOID(rawValue: oid)?.elementType?.rawValue ?? 0
        return format == 1
            ? decodeBinary(bytes)
            : decodeText(bytes, elementOID: elementOID)
    }

    // MARK: - Binary

    /// The binary layout: dimension count, a null flag, the element OID, then a
    /// `(length, lowerBound)` pair per dimension, then the elements themselves —
    /// each a length-prefixed blob, with `-1` meaning NULL.
    ///
    /// The element OID is **on the wire**, which is why this does not need to be
    /// told what it is decoding. That matters for a domain over an array, where
    /// the column's own OID says nothing useful.
    public static func decodeBinary(_ bytes: [UInt8]) -> PostgresArray? {
        var buffer = ByteBuffer(bytes: bytes)
        guard let dimensionCount: Int32 = buffer.readInteger(),
              let _: Int32 = buffer.readInteger(),  // has-nulls flag; the lengths say so anyway
              let elementOID: UInt32 = buffer.readInteger()
        else { return nil }

        // Zero dimensions is the empty array, and it carries nothing after the
        // header — not even a dimension entry.
        guard dimensionCount > 0 else {
            return PostgresArray(elementOID: elementOID)
        }
        // A negative or absurd dimension count is malformed input, not a shape.
        guard dimensionCount <= 6 else { return nil }

        var dimensions: [PostgresArray.Dimension] = []
        var total = 1
        for _ in 0..<dimensionCount {
            guard let length: Int32 = buffer.readInteger(),
                  let lowerBound: Int32 = buffer.readInteger(),
                  length >= 0
            else { return nil }
            dimensions.append(.init(length: length, lowerBound: lowerBound))
            total *= Int(length)
        }

        var elements: [SQLValue] = []
        elements.reserveCapacity(total)
        for _ in 0..<total {
            guard let length: Int32 = buffer.readInteger() else { return nil }
            if length < 0 {
                elements.append(.null)
                continue
            }
            guard let element = buffer.readBytes(length: Int(length)) else { return nil }
            elements.append(PostgresValueDecoder.decode(element, oid: elementOID, format: 1))
        }

        return PostgresArray(
            elementOID: elementOID, dimensions: dimensions, elements: elements
        )
    }

    // MARK: - Text

    /// Parses `{a,b,c}`, including quoting, escapes, nesting, and `NULL`.
    ///
    /// The two rules that are easy to get wrong, and both silently:
    ///
    /// - An **unquoted** `NULL` is a SQL null; a **quoted** `"NULL"` is the
    ///   four-character string. Losing the distinction turns a null into a word
    ///   or, worse, a word into a null.
    /// - Backslash escapes apply inside quotes *and* outside them.
    public static func decodeText(_ bytes: [UInt8], elementOID: UInt32) -> PostgresArray? {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        var characters = Array(text)
        var index = 0

        // An explicit lower bound prefix: `[3:5]={a,b,c}`.
        var declaredBounds: [PostgresArray.Dimension] = []
        if characters.first == "[" {
            guard let equals = characters.firstIndex(of: "=") else { return nil }
            let header = String(characters[1..<equals]).dropLast()  // trailing "]"
            for range in header.split(separator: "][") {
                let parts = range.split(separator: ":")
                guard parts.count == 2, let lower = Int32(parts[0]), let upper = Int32(parts[1])
                else { return nil }
                declaredBounds.append(.init(length: upper - lower + 1, lowerBound: lower))
            }
            characters = Array(characters[(equals + 1)...])
        }

        var elements: [SQLValue] = []
        // Keyed by depth rather than appended, because nested arrays *close*
        // innermost-first: `{{1,2},{3,4}}` finishes depth 1 twice before depth 0
        // finishes once, so appending in close order records the dimensions
        // inside out and loses all but the last.
        var lengths: [Int: Int] = [:]

        func parse(depth: Int) -> Bool {
            guard index < characters.count, characters[index] == "{" else { return false }
            index += 1
            var count = 0

            // `{}` — an empty array, and the only case with no elements at all.
            if index < characters.count, characters[index] == "}" {
                index += 1
                recordLength(0, at: depth)
                return true
            }

            while index < characters.count {
                if characters[index] == "{" {
                    guard parse(depth: depth + 1) else { return false }
                } else {
                    guard let value = parseElement() else { return false }
                    elements.append(value)
                }
                count += 1

                guard index < characters.count else { return false }
                if characters[index] == "," {
                    index += 1
                    continue
                }
                if characters[index] == "}" {
                    index += 1
                    recordLength(count, at: depth)
                    return true
                }
                return false
            }
            return false
        }

        func recordLength(_ count: Int, at depth: Int) {
            // The first time a depth closes fixes that dimension's length.
            // Postgres requires arrays to be rectangular, so every sibling at that
            // depth has the same length anyway.
            if lengths[depth] == nil { lengths[depth] = count }
        }

        func parseElement() -> SQLValue? {
            var raw = ""
            var quoted = false

            if characters[index] == "\"" {
                quoted = true
                index += 1
                while index < characters.count, characters[index] != "\"" {
                    if characters[index] == "\\" {
                        index += 1
                        guard index < characters.count else { return nil }
                    }
                    raw.append(characters[index])
                    index += 1
                }
                // Redundant with the caller's own bounds check, and deliberately
                // kept. The mutation sweep relaxes this to `<=` and nothing can
                // catch it: letting `index` reach `count + 1` here just makes
                // `parse` return false on its next guard, so the array still
                // decodes to nil by a slightly longer route. Removing it would
                // rely on that second check never moving.
                guard index < characters.count else { return nil }
                index += 1  // closing quote
            } else {
                while index < characters.count,
                      characters[index] != ",", characters[index] != "}" {
                    if characters[index] == "\\" {
                        index += 1
                        guard index < characters.count else { return nil }
                    }
                    raw.append(characters[index])
                    index += 1
                }
                raw = raw.trimmingCharacters(in: .whitespaces)
            }

            // Unquoted NULL is a null; quoted "NULL" is the four-character string.
            if !quoted, raw.uppercased() == "NULL" { return .null }
            return PostgresValueDecoder.decode(Array(raw.utf8), oid: elementOID, format: 0)
        }

        guard parse(depth: 0) else { return nil }

        let ordered = lengths.keys.sorted().map { lengths[$0]! }
        let dimensions = !declaredBounds.isEmpty
            ? declaredBounds
            : ordered.map { PostgresArray.Dimension(length: Int32($0), lowerBound: 1) }
        return PostgresArray(
            elementOID: elementOID, dimensions: dimensions, elements: elements
        )
    }
}

extension PostgresArray {
    /// The array as Postgres would print it.
    ///
    /// This is what a binary-format array becomes when it lands in a `SQLValue`,
    /// so a column decodes identically whichever format it arrived in — the same
    /// contract `numeric` and the temporals already keep.
    public var textRepresentation: String {
        guard !dimensions.isEmpty else { return "{}" }
        var index = 0
        return render(dimension: 0, index: &index)
    }

    private func render(dimension: Int, index: inout Int) -> String {
        let length = Int(dimensions[dimension].length)
        var parts: [String] = []
        parts.reserveCapacity(length)
        for _ in 0..<length {
            if dimension == dimensions.count - 1 {
                guard index < elements.count else { break }
                parts.append(Self.literal(elements[index]))
                index += 1
            } else {
                parts.append(render(dimension: dimension + 1, index: &index))
            }
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// One element, quoted only when it has to be.
    ///
    /// An unquoted `NULL` is the null; anything that *looks* like it — the string
    /// "NULL", or an empty string, or anything containing a delimiter — must be
    /// quoted or it reads back as something else.
    static func literal(_ value: SQLValue) -> String {
        guard case .null = value else {
            let text = plainText(value)
            let needsQuotes = text.isEmpty
                || text.uppercased() == "NULL"
                || text.contains(where: { "{},\"\\ \t\n\r".contains($0) })
            guard needsQuotes else { return text }
            let escaped = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return "NULL"
    }

    static func plainText(_ value: SQLValue) -> String {
        switch value {
        case .null: return "NULL"
        case .bool(let flag): return flag ? "t" : "f"
        case .int(let number): return String(number)
        case .double(let number): return String(number)
        case .text(let string): return string
        case .blob(let bytes):
            return "\\x" + String(decoding: PostgresValueEncoder.hexEncode(bytes), as: UTF8.self)
        }
    }
}
