import Foundation
import NIOCore
import SwizzleCore

/// The binary decoders for the types beyond the core scalars.
///
/// ## Why these are here rather than absent
///
/// Found by diffing our OID table against `postgres-types/src/type_gen.rs`. The
/// unknown-OID fallback never *fails*, so every one of these was arriving as an
/// opaque `.blob` — an `inet` column came back as four raw bytes, a `daterange`
/// as a flag byte and two lengths. Degrading quietly is the right behaviour for a
/// type nobody has heard of; it is the wrong behaviour for `inet`.
///
/// Everything renders to the text Postgres itself would print, for the same
/// reason `numeric` and the temporals do: a column then decodes identically
/// whichever format it arrived in, and the server's rendering is canonical.
///
/// Deliberately **not** added: `tsvector`, `tsquery` and the `reg*` catalogue
/// types. Adding an OID without a binary decoder is a *regression* — the decoder
/// falls through to `.blob`, where an unrecognised OID would at least have tried
/// UTF-8 first. An entry here has to earn its place with a decoder.
enum PostgresExtendedTypes {

    // MARK: - Network addresses

    /// `family`, netmask bits, an `is_cidr` flag, address length, then the
    /// address. Confirmed against `inet_from_sql`.
    ///
    /// The family byte is **not** `AF_INET` from the host's headers — Postgres
    /// defines its own constants (2 and 3) precisely so the wire format does not
    /// change with the platform.
    static func decodeInet(_ buffer: inout ByteBuffer, isCIDR: Bool) -> SQLValue? {
        guard let family: UInt8 = buffer.readInteger(),
              let netmask: UInt8 = buffer.readInteger(),
              let _: UInt8 = buffer.readInteger(),
              let length: UInt8 = buffer.readInteger(),
              let bytes = buffer.readBytes(length: Int(length))
        else { return nil }

        let text: String
        switch family {
        case 2:
            guard bytes.count == 4, netmask <= 32 else { return nil }
            text = bytes.map(String.init).joined(separator: ".")
        case 3:
            guard bytes.count == 16, netmask <= 128 else { return nil }
            text = formatIPv6(bytes)
        default:
            return nil
        }

        // `inet` prints the prefix only when it is not a full-width host address;
        // `cidr` always prints it. Matching that is what makes the two formats
        // agree.
        let full: UInt8 = family == 2 ? 32 : 128
        return .text(isCIDR || netmask != full ? "\(text)/\(netmask)" : text)
    }

    /// Compressed form, with the longest run of zero groups replaced by `::` —
    /// which is what the server prints, so anything else would disagree with the
    /// text format.
    static func formatIPv6(_ bytes: [UInt8]) -> String {
        var groups: [UInt16] = []
        for index in stride(from: 0, to: 16, by: 2) {
            groups.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
        }

        var bestStart = -1, bestLength = 0
        var start = -1, length = 0
        for (index, group) in groups.enumerated() {
            if group == 0 {
                if start < 0 { start = index }
                length += 1
                if length > bestLength { bestStart = start; bestLength = length }
            } else {
                start = -1; length = 0
            }
        }
        // A single zero group is written out; `::` is only for a run of two or
        // more, again matching the server.
        guard bestLength > 1 else {
            return groups.map { String($0, radix: 16) }.joined(separator: ":")
        }

        let head = groups[0..<bestStart].map { String($0, radix: 16) }.joined(separator: ":")
        let tail = groups[(bestStart + bestLength)...].map { String($0, radix: 16) }
            .joined(separator: ":")
        return head + "::" + tail
    }

    static func decodeMACAddress(_ bytes: [UInt8], width: Int) -> SQLValue? {
        guard bytes.count == width else { return nil }
        return .text(bytes.map { String(format: "%02x", $0) }.joined(separator: ":"))
    }

    // MARK: - money

    /// An `Int64` in the smallest currency unit.
    ///
    /// The scale is `lc_monetary`'s fractional digits — two almost everywhere,
    /// and *not* something the wire carries. Kept as an exact decimal string for
    /// the same reason `numeric` is: this is money, and `Double` loses cents.
    static func decodeMoney(_ buffer: inout ByteBuffer) -> SQLValue? {
        guard let amount: Int64 = buffer.readInteger() else { return nil }
        let negative = amount < 0
        let magnitude = amount.magnitude
        let units = magnitude / 100
        let fraction = magnitude % 100
        return .text("\(negative ? "-" : "")\(units).\(String(format: "%02d", fraction))")
    }

    // MARK: - Bit strings

    /// An `Int32` length **in bits**, then the bits packed into bytes.
    ///
    /// The length is in bits rather than bytes, so `B'101'` is three bits in one
    /// byte and the trailing five are padding that must not be printed.
    static func decodeBits(_ buffer: inout ByteBuffer) -> SQLValue? {
        guard let bitCount: Int32 = buffer.readInteger(), bitCount >= 0,
              let bytes = buffer.readBytes(length: (Int(bitCount) + 7) / 8)
        else { return nil }

        var text = ""
        text.reserveCapacity(Int(bitCount))
        for index in 0..<Int(bitCount) {
            let byte = bytes[index / 8]
            text.append((byte >> (7 - UInt8(index % 8))) & 1 == 1 ? "1" : "0")
        }
        return .text(text)
    }

    // MARK: - Ranges

    static let rangeEmpty: UInt8 = 0b0000_0001
    static let rangeLowerInclusive: UInt8 = 0b0000_0010
    static let rangeUpperInclusive: UInt8 = 0b0000_0100
    static let rangeLowerUnbounded: UInt8 = 0b0000_1000
    static let rangeUpperUnbounded: UInt8 = 0b0001_0000

    /// A flags byte, then each present bound as a length-prefixed element.
    ///
    /// Rendered as Postgres prints it — `[1,10)` — where the brackets carry the
    /// inclusivity. Dropping them would turn a half-open range into an ambiguous
    /// pair, which for a `tstzrange` is the difference between including midnight
    /// and not.
    /// Quotes a range bound the way `range_out` does.
    ///
    /// Postgres quotes a bound whose text is empty or contains any of
    /// `"` `\` `(` `)` `[` `]` `,` or whitespace, escaping `"` and `\` inside.
    /// A timestamp contains a space, so **every** `tsrange` and `tstzrange` needs
    /// it — which is how this was missed: the range tests covered `int4range`,
    /// `daterange` and `numrange`, and not one of those has a bound that needs
    /// quoting. The binary form rendered `[2024-01-01 00:00:00,…)` where the
    /// server renders `["2024-01-01 00:00:00",…)`, so the two formats disagreed
    /// for exactly the two range types nothing compared.
    static func quotedBound(_ text: String) -> String {
        let needsQuotes =
            text.isEmpty
            || text.contains {
                $0 == "\"" || $0 == "\\" || $0 == "(" || $0 == ")"
                    || $0 == "[" || $0 == "]" || $0 == "," || $0.isWhitespace
            }
        guard needsQuotes else { return text }
        var escaped = ""
        for character in text {
            if character == "\"" || character == "\\" { escaped.append("\\") }
            escaped.append(character)
        }
        return "\"\(escaped)\""
    }

    static func decodeRange(
        _ buffer: inout ByteBuffer, elementOID: UInt32
    ) -> SQLValue? {
        guard let flags: UInt8 = buffer.readInteger() else { return nil }
        if flags & rangeEmpty != 0 { return .text("empty") }

        func bound(unbounded: UInt8) -> String? {
            // An absent bound prints as nothing at all, and must not be quoted:
            // `(,5)` is unbounded-below, `("",5)` would be a bound whose value is
            // the empty string.
            guard flags & unbounded == 0 else { return "" }
            guard let length: Int32 = buffer.readInteger(), length >= 0,
                  let bytes = buffer.readBytes(length: Int(length))
            else { return nil }
            let value = PostgresValueDecoder.decode(bytes, oid: elementOID, format: 1)
            return quotedBound(PostgresArray.plainText(value))
        }

        guard let lower = bound(unbounded: rangeLowerUnbounded),
              let upper = bound(unbounded: rangeUpperUnbounded)
        else { return nil }

        let open = flags & rangeLowerInclusive != 0 ? "[" : "("
        let close = flags & rangeUpperInclusive != 0 ? "]" : ")"
        return .text("\(open)\(lower),\(upper)\(close)")
    }

    /// A count, then each range as a length-prefixed blob of the range encoding.
    ///
    /// Postgres 14 gave every range type a multirange companion, and
    /// `multirange_send` frames them exactly this way. Printed the way Postgres
    /// prints them — `{[1,5),[10,20)}` — so binary and text agree, which is the
    /// contract every other type here keeps.
    ///
    /// `rust-postgres` knows multiranges only as a *kind*: it records the element
    /// type and has no codec, so a multirange arrives there as raw bytes. This is
    /// one of the few places we are ahead of the reference rather than level with
    /// it, and it is a decode nobody has to write twice — the per-range work is
    /// the same `decodeRange` used for the singular form.
    static func decodeMultirange(
        _ buffer: inout ByteBuffer, elementOID: UInt32
    ) -> SQLValue? {
        guard let count: Int32 = buffer.readInteger(), count >= 0 else { return nil }

        var ranges: [String] = []
        ranges.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let length: Int32 = buffer.readInteger(), length >= 0,
                  var slice = buffer.readSlice(length: Int(length)),
                  case .text(let rendered)? = decodeRange(&slice, elementOID: elementOID)
            else { return nil }
            ranges.append(rendered)
        }
        return .text("{" + ranges.joined(separator: ",") + "}")
    }

    /// `int2vector` and `oidvector`, printed space-separated as Postgres prints
    /// them.
    ///
    /// These are catalog types: `pg_index.indkey` is an `int2vector` and
    /// `pg_proc.proargtypes` an `oidvector`. Nobody declares a column of one, and
    /// anybody reading the catalogs meets them immediately — which is the worst
    /// moment to be handed opaque bytes.
    ///
    /// **Their binary form is an ordinary array**, header and all, differing only
    /// in a lower bound of 0 rather than 1 and in printing space-separated rather
    /// than `{1,2,3}`. A first attempt here read a bare run of fixed-width
    /// integers, which is what the *text* form suggests; the binary/text oracle
    /// rejected it immediately, returning the array header as though it were
    /// data.
    static func decodeIntVector(_ bytes: [UInt8]) -> SQLValue? {
        guard let array = PostgresArrayDecoder.decodeBinary(bytes) else { return nil }
        let elements = array.elements.map { PostgresArray.plainText($0) }
        return .text(elements.joined(separator: " "))
    }

    // MARK: - System and replication

    /// Two `UInt32`s printed as `XXXXXXXX/XXXXXXXX`, which is the only spelling
    /// any Postgres tool accepts.
    static func decodeLSN(_ buffer: inout ByteBuffer) -> SQLValue? {
        guard let value: UInt64 = buffer.readInteger() else { return nil }
        return .text(String(format: "%X/%X", UInt32(value >> 32), UInt32(value & 0xFFFF_FFFF)))
    }

    /// A block number and an offset, printed as `(block,offset)` — the form
    /// `SELECT ctid` shows.
    static func decodeTID(_ buffer: inout ByteBuffer) -> SQLValue? {
        guard let block: UInt32 = buffer.readInteger(),
              let offset: UInt16 = buffer.readInteger()
        else { return nil }
        return .text("(\(block),\(offset))")
    }

    // MARK: - Geometric

    static func decodeDoubles(_ buffer: inout ByteBuffer, count: Int) -> [Double]? {
        var values: [Double] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            guard let bits: UInt64 = buffer.readInteger() else { return nil }
            values.append(Double(bitPattern: bits))
        }
        return values
    }

    static func number(_ value: Double) -> String {
        // Postgres prints an integral float without a trailing `.0`, and matching
        // that is what keeps the binary and text renderings equal.
        value == value.rounded() && value.magnitude < 1e15
            ? String(Int64(value))
            : String(value)
    }

    static func point(_ values: [Double], at index: Int) -> String {
        "(\(number(values[index])),\(number(values[index + 1])))"
    }

    static func decodeGeometry(_ buffer: inout ByteBuffer, type: PostgresOID) -> SQLValue? {
        switch type {
        case .point:
            guard let v = decodeDoubles(&buffer, count: 2) else { return nil }
            return .text(point(v, at: 0))
        case .lseg:
            guard let v = decodeDoubles(&buffer, count: 4) else { return nil }
            return .text("[\(point(v, at: 0)),\(point(v, at: 2))]")
        case .box:
            guard let v = decodeDoubles(&buffer, count: 4) else { return nil }
            // A box prints *without* enclosing brackets, unlike an lseg.
            return .text("\(point(v, at: 0)),\(point(v, at: 2))")
        case .line:
            guard let v = decodeDoubles(&buffer, count: 3) else { return nil }
            return .text("{\(number(v[0])),\(number(v[1])),\(number(v[2]))}")
        case .circle:
            guard let v = decodeDoubles(&buffer, count: 3) else { return nil }
            return .text("<\(point(v, at: 0)),\(number(v[2]))>")
        case .path:
            // A leading flag says whether the path is closed, which decides
            // whether it prints with parentheses or square brackets.
            guard let closed: UInt8 = buffer.readInteger(),
                  let count: Int32 = buffer.readInteger(), count >= 0,
                  let v = decodeDoubles(&buffer, count: Int(count) * 2)
            else { return nil }
            let points = (0..<Int(count)).map { point(v, at: $0 * 2) }.joined(separator: ",")
            return .text(closed == 1 ? "(\(points))" : "[\(points)]")
        case .polygon:
            guard let count: Int32 = buffer.readInteger(), count >= 0,
                  let v = decodeDoubles(&buffer, count: Int(count) * 2)
            else { return nil }
            return .text("(" + (0..<Int(count)).map { point(v, at: $0 * 2) }
                .joined(separator: ",") + ")")
        default:
            return nil
        }
    }
}

extension PostgresExtendedTypes {

    // MARK: - Full-text search

    /// `tsvector`: a lexeme count, then each lexeme as a C string followed by its
    /// positions.
    ///
    /// Each position is a packed `UInt16` — **weight in the top two bits, position
    /// in the low fourteen** — which is why a naive read gives positions in the
    /// tens of thousands. The weight encoding is inverted from what you would
    /// guess: `3` is `A` and `0` is `D`, and `D` is the default so it is never
    /// printed.
    ///
    /// Confirmed against `pgx/pgtype/tsvector.go`.
    static func decodeTSVector(_ buffer: inout ByteBuffer) -> SQLValue? {
        guard let count: UInt32 = buffer.readInteger(), count < 1_000_000 else { return nil }

        var lexemes: [String] = []
        lexemes.reserveCapacity(Int(count))

        for _ in 0..<count {
            guard let word = readCString(&buffer),
                  let positionCount: UInt16 = buffer.readInteger()
            else { return nil }

            var text = "'" + word.replacingOccurrences(of: "'", with: "''") + "'"
            guard positionCount > 0 else {
                lexemes.append(text)
                continue
            }

            var positions: [String] = []
            positions.reserveCapacity(Int(positionCount))
            for _ in 0..<positionCount {
                guard let packed: UInt16 = buffer.readInteger() else { return nil }
                let position = packed & 0x3FFF
                // 3→A, 2→B, 1→C, 0→D. `D` is the default weight and Postgres
                // omits it, so printing it would disagree with the text format.
                let weight = ["", "C", "B", "A"][Int(packed >> 14)]
                positions.append("\(position)\(weight)")
            }
            text += ":" + positions.joined(separator: ",")
            lexemes.append(text)
        }
        // Sorted on the wire already — `tsvector` keeps its lexemes in order —
        // so joining preserves what the server would print.
        return .text(lexemes.joined(separator: " "))
    }

    /// `jsonpath`: a version byte, then the expression as text.
    ///
    /// The same shape as `jsonb`, and the same trap: the leading byte is not part
    /// of the document.
    static func decodeJSONPath(_ bytes: [UInt8]) -> SQLValue? {
        guard bytes.first == 1 else { return nil }
        return String(bytes: bytes.dropFirst(), encoding: .utf8).map { .text($0) }
    }

    static func readCString(_ buffer: inout ByteBuffer) -> String? {
        guard let length = buffer.readableBytesView.firstIndex(of: 0).map({
            $0 - buffer.readableBytesView.startIndex
        }) else { return nil }
        let text = buffer.readString(length: length)
        buffer.moveReaderIndex(forwardBy: 1)  // the NUL
        return text
    }
}

extension PostgresExtendedTypes {

    /// `tsquery`: an item count, then the tree in **prefix order** — and the
    /// operands are stored *right before left*.
    ///
    /// ## Why this one was left until last
    ///
    /// Reading the tree is easy. Printing it back the way Postgres does is not:
    /// the server emits the **minimum** parentheses, so a fully-parenthesised
    /// rendering is semantically identical and textually different — which is
    /// worse than not decoding at all, because it looks right and compares
    /// unequal everywhere.
    ///
    /// The precedences are `|` < `&` < `<->` < `!`, and a child is wrapped when
    /// its precedence is lower than its parent's, or equal *and* it is the right
    /// operand of a phrase operator — because `a <-> (b <-> c)` is not
    /// `(a <-> b) <-> c`.
    ///
    /// Verified against the server over a corpus rather than reasoned about:
    /// every expression is decoded from binary and compared with the server's own
    /// text rendering of the same value.
    static func decodeTSQuery(_ buffer: inout ByteBuffer) -> SQLValue? {
        guard let count: UInt32 = buffer.readInteger() else { return nil }
        // The empty query prints as nothing at all.
        guard count > 0 else { return .text("") }
        guard count < 1_000_000 else { return nil }

        var items: [TSQueryItem] = []
        items.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let kind: UInt8 = buffer.readInteger() else { return nil }
            switch kind {
            case 1:
                guard let weight: UInt8 = buffer.readInteger(),
                      let prefix: UInt8 = buffer.readInteger(),
                      let operand = readCString(&buffer)
                else { return nil }
                items.append(.value(operand: operand, weight: weight, isPrefix: prefix != 0))
            case 2:
                guard let oper: UInt8 = buffer.readInteger() else { return nil }
                var distance: UInt16 = 0
                if oper == 4 {
                    guard let value: UInt16 = buffer.readInteger() else { return nil }
                    distance = value
                }
                items.append(.operator(oper: oper, distance: distance))
            default:
                return nil
            }
        }

        var index = 0
        guard let text = renderTSQuery(items, &index, parentPriority: 0, isRightPhrase: false),
              index == items.count
        else { return nil }
        return .text(text)
    }

    enum TSQueryItem {
        case value(operand: String, weight: UInt8, isPrefix: Bool)
        case `operator`(oper: UInt8, distance: UInt16)
    }

    /// `|` 1 · `&` 2 · `<->` 3 · `!` 4
    static func tsQueryPriority(_ oper: UInt8) -> Int {
        switch oper {
        case 3: 1   // OR
        case 2: 2   // AND
        case 4: 3   // PHRASE
        default: 4  // NOT
        }
    }

    static func renderTSQuery(
        _ items: [TSQueryItem], _ index: inout Int,
        parentPriority: Int, isRightPhrase: Bool
    ) -> String? {
        guard index < items.count else { return nil }
        let item = items[index]
        index += 1

        switch item {
        case .value(let operand, let weight, let isPrefix):
            var text = "'" + operand
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "''") + "'"
            if weight != 0 || isPrefix {
                text += ":"
                // **The prefix marker comes first.** Postgres prints
                // `'cat':*A` and `'cat':*AB`, not `'cat':A*` — confirmed
                // against the server rather than inferred from the wire
                // order, which puts the weight byte first and is what
                // this followed.
                if isPrefix { text += "*" }
                // A is the high bit and D the low one.
                if weight & 0b1000 != 0 { text += "A" }
                if weight & 0b0100 != 0 { text += "B" }
                if weight & 0b0010 != 0 { text += "C" }
                if weight & 0b0001 != 0 { text += "D" }
            }
            return text

        case .operator(let oper, let distance):
            let priority = tsQueryPriority(oper)

            if oper == 1 {
                // NOT is unary and binds tightest, so its operand is wrapped only
                // when the operand itself is looser.
                guard let operand = renderTSQuery(
                    items, &index, parentPriority: priority, isRightPhrase: false
                ) else { return nil }
                let text = "!" + operand
                // `( … )` with spaces, as the server prints it — see below.
                return priority < parentPriority ? "( " + text + " )" : text
            }

            // **Right operand first.** The wire order is operator, right subtree,
            // left subtree — reading it left-to-right silently mirrors every
            // asymmetric query, and `a <2> b` is not `b <2> a`.
            guard let right = renderTSQuery(
                items, &index, parentPriority: priority, isRightPhrase: oper == 4
            ) else { return nil }
            guard let left = renderTSQuery(
                items, &index, parentPriority: priority, isRightPhrase: false
            ) else { return nil }

            let symbol: String
            switch oper {
            case 2: symbol = " & "
            case 3: symbol = " | "
            default: symbol = distance == 1 ? " <-> " : " <\(distance)> "
            }

            let text = left + symbol + right
            let needsParentheses = priority < parentPriority
                || (priority == parentPriority && isRightPhrase)
            // **Spaces inside the parentheses**, because that is what Postgres
            // prints: `( 'cat' | 'rat' ) & 'dog'`, not `('cat' | 'rat') & 'dog'`.
            //
            // Without them a `tsquery` column read over the extended protocol did
            // not match the same column read over the simple one — the exact
            // inconsistency this file exists to prevent, since everything here
            // renders what the server renders so a value reads identically
            // whichever format it arrived in.
            //
            // Hidden because the suite checking this ran `SELECT expr::text, expr`
            // with no bindings, which takes the simple protocol and returns *both*
            // columns as text: it compared the server's rendering against the
            // server's rendering and could not fail.
            return needsParentheses ? "( " + text + " )" : text
        }
    }
}

extension PostgresExtendedTypes {

    /// `interval`: microseconds, then days, then months — three fields, because
    /// Postgres refuses to pretend a month is a fixed number of days.
    ///
    /// Rendered in the `postgres` style, which is the default output and what
    /// `psql` shows. The pluralisation is Postgres's own and is not regular:
    /// `1 year 2 mons 3 days`, with `mon` abbreviated and `year`/`day` not.
    static func decodeInterval(_ buffer: inout ByteBuffer) -> SQLValue? {
        guard let microseconds: Int64 = buffer.readInteger(),
              let days: Int32 = buffer.readInteger(),
              let months: Int32 = buffer.readInteger()
        else { return nil }

        var parts: [String] = []
        let years = months / 12
        let remainingMonths = months % 12
        // `value == 1`, not `abs(value) == 1`. Postgres pluralises a negative
        // singular — it prints `-1 years`, `-1 mons` and `-1 days`, and only a
        // *positive* one is singular:
        //
        //     SELECT interval '-1 year'::text, interval '1 year'::text
        //     → -1 years | 1 year
        //
        // Taking the magnitude first rendered `-1 year`, which no server prints.
        if years != 0 { parts.append("\(years) year\(years == 1 ? "" : "s")") }
        if remainingMonths != 0 {
            parts.append("\(remainingMonths) mon\(remainingMonths == 1 ? "" : "s")")
        }
        if days != 0 { parts.append("\(days) day\(days == 1 ? "" : "s")") }

        if microseconds != 0 {
            let negative = microseconds < 0
            let total = microseconds.magnitude
            let hours = total / 3_600_000_000
            let minutes = (total % 3_600_000_000) / 60_000_000
            let seconds = (total % 60_000_000) / 1_000_000
            let fraction = total % 1_000_000

            var time = String(
                format: "%@%02d:%02d:%02d", negative ? "-" : "", hours, minutes, seconds
            )
            if fraction > 0 {
                // Trailing zeros are trimmed, as the server trims them.
                var digits = String(format: "%06d", fraction)
                while digits.hasSuffix("0") { digits.removeLast() }
                time += "." + digits
            }
            parts.append(time)
        }

        // A zero interval is `00:00:00`, not the empty string.
        return .text(parts.isEmpty ? "00:00:00" : parts.joined(separator: " "))
    }
}
