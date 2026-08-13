import NIOCore
import Testing
@testable import SwizzleMySQL

/// Known-answer tests for the auth scrambles.
///
/// Vectors are taken verbatim from `go-sql-driver/mysql`'s `auth_test.go` — a
/// driver in wide production use whose outputs are known to authenticate against
/// real MySQL servers. That makes these a genuine external oracle: re-deriving
/// the same formula ourselves would only catch transcription slips, not a
/// misunderstood algorithm.
///
/// Their `scramblePassword` and `scrambleSHA256Password` were read alongside the
/// vectors and match our implementations step for step, including returning an
/// empty response for an empty password.
@Suite("Auth scrambles")
struct AuthTests {

    /// go-sql-driver `TestAuthFastNativePassword`
    static let nativeScramble: [UInt8] = [
        70, 114, 92, 94, 1, 38, 11, 116, 63, 114,
        23, 101, 126, 103, 26, 95, 81, 17, 24, 21,
    ]

    /// go-sql-driver `TestScrambleSHA256Pass`
    static let sha256Scramble: [UInt8] = [
        10, 47, 74, 111, 75, 73, 34, 48, 88, 76,
        114, 74, 37, 13, 3, 80, 82, 2, 23, 21,
    ]

    static func hex(_ string: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            out.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    @Test func nativePasswordMatchesGoDriverVector() {
        let expected: [UInt8] = [
            53, 177, 140, 159, 251, 189, 127, 53, 109, 252,
            172, 50, 211, 192, 240, 164, 26, 48, 207, 45,
        ]
        #expect(
            MySQLAuth.nativePassword(password: "secret", scramble: Self.nativeScramble) == expected
        )
    }

    @Test func cachingSHA2MatchesGoDriverVectors() {
        #expect(
            MySQLAuth.cachingSHA2Password(password: "secret", scramble: Self.sha256Scramble)
                == Self.hex("f490e76f66d9d86665ce54d98c78d0acfe2fb0b08b423da807144873d30b312c")
        )
        #expect(
            MySQLAuth.cachingSHA2Password(password: "secret2", scramble: Self.sha256Scramble)
                == Self.hex("abc3934a012cf342e876071c8ee202de51785b430258a7a0138bc79c4d800bc6")
        )
    }

    /// Second, independent source: rust-mysql-common's own unit tests
    /// (`auth/plugins/{mysql_native_password,caching_sha2_password}.rs`).
    /// Two unrelated projects agreeing on the same output is much stronger
    /// evidence than either alone.
    ///
    /// Note the password here is raw bytes, not a string literal — it is
    /// `[0x47,0x21,0x69,0x64,0x65,0x72,0x32,0x37]` = "G!ider27".
    @Test func matchesRustReferenceVectors() {
        let scramble: [UInt8] = [
            0x4e, 0x52, 0x33, 0x48, 0x50, 0x3a, 0x71, 0x49, 0x59, 0x61,
            0x5f, 0x39, 0x3d, 0x64, 0x62, 0x3f, 0x53, 0x64, 0x7b, 0x60,
        ]
        let password = "G!ider27"
        #expect(Array(password.utf8) == [0x47, 0x21, 0x69, 0x64, 0x65, 0x72, 0x32, 0x37])

        #expect(MySQLAuth.nativePassword(password: password, scramble: scramble) == [
            0x09, 0xcf, 0xf8, 0x85, 0x5e, 0x9e, 0x70, 0x53, 0x40, 0xff,
            0x22, 0x70, 0xd8, 0xfb, 0x9f, 0xad, 0xba, 0x90, 0x6b, 0x70,
        ])
        #expect(MySQLAuth.cachingSHA2Password(password: password, scramble: scramble) == [
            0x4f, 0x97, 0xbb, 0xfd, 0x20, 0x24, 0x01, 0xc4, 0x2a, 0x69, 0xde, 0xaa, 0xe5, 0x3b,
            0xda, 0x07, 0x7e, 0xd7, 0x57, 0x85, 0x63, 0xc1, 0xa8, 0x0e, 0xb8, 0x16, 0xc8, 0x21,
            0x19, 0xb6, 0x8d, 0x2e,
        ])
    }

    /// An empty password sends an empty response, not a hash of "". Getting this
    /// wrong makes passwordless accounts fail to authenticate. Both
    /// go-sql-driver and rust-mysql-common return nil here for the same reason.
    @Test func emptyPasswordProducesEmptyResponse() {
        #expect(MySQLAuth.nativePassword(password: "", scramble: Self.nativeScramble).isEmpty)
        #expect(MySQLAuth.cachingSHA2Password(password: "", scramble: Self.sha256Scramble).isEmpty)
    }

    @Test func digestsHaveExpectedWidths() {
        #expect(MySQLAuth.nativePassword(password: "x", scramble: Self.nativeScramble).count == 20)
        #expect(MySQLAuth.cachingSHA2Password(password: "x", scramble: Self.sha256Scramble).count == 32)
    }

    /// Different scrambles must give different responses, or replay works.
    @Test func responseDependsOnScramble() {
        let a = MySQLAuth.nativePassword(password: "secret", scramble: Self.nativeScramble)
        let b = MySQLAuth.nativePassword(password: "secret", scramble: Self.sha256Scramble)
        #expect(a != b)
    }

    /// Passwords hash over raw UTF-8 bytes, with no normalisation or transcoding.
    @Test func nonASCIIPasswordHashesOverUTF8Bytes() {
        let password = "Ünïcødé"
        let viaAPI = MySQLAuth.nativePassword(password: password, scramble: Self.nativeScramble)

        // Recompute from an explicit UTF-8 byte array rather than a String.
        let bytes = Array(password.utf8)
        let stage1 = MySQLAuth.sha1(bytes)
        let expected = MySQLAuth.xor(
            MySQLAuth.sha1(Self.nativeScramble + MySQLAuth.sha1(stage1)), stage1
        )
        #expect(viaAPI == expected)
        #expect(bytes.count == 11)  // 7 characters: Ü ï ø é are 2 bytes each, n c d are 1
    }

    @Test func pluginNameRoundTrips() {
        #expect(MySQLAuthPlugin(name: "mysql_native_password") == .mysqlNativePassword)
        #expect(MySQLAuthPlugin(name: "caching_sha2_password") == .cachingSHA2Password)
        #expect(MySQLAuthPlugin(name: "client_ed25519") == .ed25519)
        #expect(MySQLAuthPlugin(name: "auth_gssapi_client") == .unknown("auth_gssapi_client"))
        #expect(MySQLAuthPlugin.cachingSHA2Password.name == "caching_sha2_password")
    }

    @Test func sha256PluginIsDistinctFromCachingSHA2() {
        // Similar names, different plugins — sha256_password has no fast path.
        #expect(MySQLAuthPlugin(name: "sha256_password") == .sha256Password)
        #expect(MySQLAuthPlugin.sha256Password.name == "sha256_password")
        #expect(MySQLAuthPlugin(name: "sha256_password") != .cachingSHA2Password)
    }
}
