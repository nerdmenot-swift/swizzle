import Foundation
import NIOCore
import Testing
@testable import SwizzleMySQL

/// Parsing `DATABASE_URL`.
@Suite("Connection URLs")
struct ConnectionURLTests {

    @Test("a full URL populates every field")
    func fullURL() throws {
        let config = try MySQLConnectionConfiguration(
            url: "mysql://ada:s3cret@db.example.com:3307/app?tls=require&compression=zstd"
        )
        guard case .hostname(let host, let port) = config.address else {
            Issue.record("expected a hostname address"); return
        }
        #expect(host == "db.example.com")
        #expect(port == 3307)
        #expect(config.username == "ada")
        #expect(config.password == "s3cret")
        #expect(config.database == "app")
        #expect(config.tls == .require)
        #expect(config.compression == .zstd())
    }

    @Test("the port defaults to 3306")
    func defaultPort() throws {
        let config = try MySQLConnectionConfiguration(url: "mysql://root@localhost/app")
        guard case .hostname(_, let port) = config.address else {
            Issue.record("expected a hostname address"); return
        }
        #expect(port == 3306)
    }

    @Test("mariadb is the same protocol", arguments: ["mysql", "mariadb"])
    func bothSchemes(scheme: String) throws {
        let config = try MySQLConnectionConfiguration(url: "\(scheme)://root@localhost/app")
        #expect(config.database == "app")
    }

    /// A password with reserved characters must be percent-encoded, and must
    /// come back decoded — otherwise authentication fails with a message that
    /// says nothing about the URL.
    @Test("credentials are percent-decoded")
    func credentialsAreDecoded() throws {
        let config = try MySQLConnectionConfiguration(
            url: "mysql://ada%40home:p%40ss%2Fword@localhost/app"
        )
        #expect(config.username == "ada@home")
        #expect(config.password == "p@ss/word")
    }

    @Test("no database is nil, not empty")
    func noDatabase() throws {
        #expect(try MySQLConnectionConfiguration(url: "mysql://root@localhost").database == nil)
        #expect(try MySQLConnectionConfiguration(url: "mysql://root@localhost/").database == nil)
    }

    @Test("a socket parameter replaces the host")
    func unixSocket() throws {
        let config = try MySQLConnectionConfiguration(
            url: "mysql://root@localhost/app?socket=/tmp/mysql.sock"
        )
        guard case .unixDomainSocket(let path) = config.address else {
            Issue.record("expected a socket address"); return
        }
        #expect(path == "/tmp/mysql.sock")
    }

    @Test("tuning parameters are applied")
    func tuningParameters() throws {
        let config = try MySQLConnectionConfiguration(
            url: """
            mysql://root@localhost/app?statement_cache_size=0&connect_timeout=30\
            &max_allowed_packet=1048576&allow_cleartext_plugin=true
            """
        )
        #expect(config.statementCacheCapacity == 0)
        #expect(config.connectTimeout == .seconds(30))
        #expect(config.maxAllowedPacket == 1_048_576)
        #expect(config.allowCleartextPlugin)
    }

    @Test(arguments: ["disable", "prefer", "require"])
    func tlsModes(value: String) throws {
        let config = try MySQLConnectionConfiguration(url: "mysql://r@h/d?tls=\(value)")
        #expect(config.tls == MySQLConnectionConfiguration.TLSMode(rawValueName: value))
    }

    /// A `postgres://` URL reaching a MySQL driver is a deployment mistake, and
    /// guessing would connect to the wrong thing.
    @Test("a foreign scheme is refused")
    func foreignScheme() {
        #expect(throws: MySQLURLError.self) {
            try MySQLConnectionConfiguration(url: "postgres://root@localhost/app")
        }
    }

    /// The important one. A dropped `tls=require` is a security failure that
    /// looks exactly like success, so a typo must not be ignored.
    @Test("an unknown parameter is refused, not ignored")
    func unknownParameterRefused() {
        #expect(throws: MySQLURLError.self) {
            try MySQLConnectionConfiguration(url: "mysql://root@localhost/app?tsl=require")
        }
    }

    @Test(arguments: [
        "mysql://root@localhost/app?tls=maybe",
        "mysql://root@localhost/app?compression=lz4",
        "mysql://root@localhost/app?connect_timeout=0",
        "mysql://root@localhost/app?statement_cache_size=-1",
        "mysql:///app",
    ])
    func malformedURLsAreRefused(url: String) {
        #expect(throws: MySQLURLError.self) {
            try MySQLConnectionConfiguration(url: url)
        }
    }
}

extension MySQLConnectionConfiguration.TLSMode {
    /// Test-only helper so the parametrised TLS test can name its expectation.
    init(rawValueName: String) {
        switch rawValueName {
        case "disable": self = .disable
        case "require": self = .require
        default: self = .prefer
        }
    }
}
