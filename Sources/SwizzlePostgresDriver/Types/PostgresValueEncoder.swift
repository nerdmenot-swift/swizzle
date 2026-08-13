import Foundation
import NIOCore
import SwizzleCore

/// Turns a bound value into the bytes that go in a `Bind`.
///
/// ## Why everything goes out as text
///
/// A `Bind` declares a format per parameter, and text is the default. Binary
/// would save a conversion, but it requires knowing the parameter's *type OID* —
/// and at bind time we do not: `Parse` was sent with an empty type list so the
/// server could infer types from the statement, which is what makes
/// `WHERE id = $1` work without the caller declaring anything.
///
/// Sending text lets the server apply the type it inferred. Sending binary would
/// mean guessing the OID and encoding to match; guess wrong and the server reads
/// the bytes as whatever it inferred, which does not fail — it produces a
/// different value. The round trip we would save is not worth a silent one.
///
/// The one exception is `bytea`, below.
public enum PostgresValueEncoder {

    /// Encodes one bound value. `nil` is a SQL NULL.
    ///
    /// A null parameter is a length of `-1` on the wire and an *empty* one is a
    /// length of `0` — distinct, and the reason this returns an optional array
    /// rather than an empty one for null.
    public static func encode(_ value: SQLValue) -> [UInt8]? {
        switch value {
        case .null:
            return nil
        case .int(let number):
            return Array(String(number).utf8)
        case .double(let number):
            // Round-trippable rather than pretty: Swift's default description is
            // the shortest string that reparses to the same Double, which is
            // exactly what is wanted here.
            return Array(String(number).utf8)
        case .bool(let flag):
            // Postgres accepts `t`/`f` in text format, and they are what it sends
            // back — using the same spelling in both directions is one fewer way
            // for the two to disagree.
            return Array((flag ? "t" : "f").utf8)
        case .text(let string):
            return Array(string.utf8)
        case .blob(let bytes):
            // The exception. `bytea` in text format is `\x` plus hex, which
            // doubles the size of every blob on the wire, so this one is worth
            // the hex encoding rather than sending raw bytes that the server
            // would read as a string.
            return Array("\\x".utf8) + hexEncode(bytes)
        }
    }

    /// The formats to declare in `Bind` for a set of parameters.
    ///
    /// All text, which the protocol also lets us say with a single `0` — but
    /// spelling it out per parameter keeps the door open for a future binary
    /// path without changing the shape of the message.
    public static func formats(for count: Int) -> [Int16] {
        Array(repeating: 0, count: count)
    }

    static func hexEncode(_ bytes: [UInt8]) -> [UInt8] {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return out
    }
}
