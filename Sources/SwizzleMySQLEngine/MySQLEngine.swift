import Foundation
import NIOCore
import NIOPosix
import SwizzleCore
import SwizzleMigrate
import SwizzleMySQL
import SwizzleOnlineDDL

/// MySQL and MariaDB as a pluggable engine.
///
/// This module exists so the driver stays standalone: someone who wants
/// `SwizzleMySQL` to run queries should not have to link the migrator, and
/// `SwizzleMigrate` should not have to know MySQL exists. Everything that joins
/// the two lives here.
public enum MySQLEngine: DatabaseEngine {
    public static let name = "mysql"

    /// Both spellings, because which one a deployment writes is taste rather
    /// than meaning — they are the same wire protocol.
    public static let urlSchemes = ["mysql", "mariadb"]

    public static var lintRules: [any LintRule] { LintRules.all }

    public static func connect(url: String) async throws -> any EngineConnection {
        let configuration = try MySQLConnectionConfiguration(url: url)
        let connection = try await MySQLConnection.connect(
            configuration: configuration, on: MultiThreadedEventLoopGroup.singleton.next()
        )
        return MySQLEngineConnection(connection: connection, url: url)
    }
}

/// One MySQL connection, presented as an engine connection.
struct MySQLEngineConnection: EngineConnection {
    let connection: MySQLConnection
    let url: String

    /// The server tells us which flavour it is, so nobody has to configure it.
    var isMariaDB: Bool { connection.metadata.isMariaDB }

    var analyzer: (any QueryAnalyzer)? { MySQLQueryAnalyzer(connection) }

    var executor: AnySQLExecutor {
        // `executor(_:)` validates the flavour, and it cannot fail here because
        // the flavour is the one the server just reported.
        isMariaDB
            ? (try! connection.executor(MariaDB.self)).erased
            : (try! connection.executor(MySQL.self)).erased
    }

    var dialect: AnyMigrationDialect {
        isMariaDB ? MariaDB.erased : MySQL.erased
    }

    var introspector: (any SchemaIntrospector)? {
        isMariaDB
            ? MySQLIntrospector(executor: try! connection.executor(MariaDB.self))
            : MySQLIntrospector(executor: try! connection.executor(MySQL.self))
    }

    /// The only engine with one, for now. It needs its own connections — the
    /// binlog stream holds one for its whole life — so it is handed the URL
    /// rather than this connection.
    func onlineRunner(serverID: UInt32) -> (any OnlineDDLRunner)? {
        var settings = MySQLOnlineDDL.Configuration()
        settings.serverID = serverID
        let url = self.url
        return MySQLOnlineDDL(
            connect: {
                try await MySQLConnection.connect(
                    configuration: try MySQLConnectionConfiguration(url: url),
                    on: MultiThreadedEventLoopGroup.singleton.next()
                )
            },
            configuration: settings
        )
    }

    func close() { connection.closeImmediately() }
}
