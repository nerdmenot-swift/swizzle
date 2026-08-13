import NIOCore

/// Result of reconciling what the server offers with what we ask for.
public struct MySQLNegotiatedCapabilities: Sendable, Equatable {
    /// Standard capabilities: the intersection of server and client.
    ///
    /// Intersection, never union — asking for a capability the server lacks
    /// makes it misparse our handshake response.
    public var capabilities: MySQLCapabilities
    /// MariaDB extended capabilities, empty unless the server both is MariaDB
    /// and signalled that its extended block is meaningful.
    public var mariaDBCapabilities: MySQLCapabilities
    public var isMariaDB: Bool
}

public enum MySQLCapabilityNegotiation {
    /// Reconciles a server greeting against our desired capability set.
    ///
    /// The MariaDB rule is non-obvious and comes from `mysql_async`'s
    /// `handle_handshake`: MariaDB indicates that its extended capability block
    /// is meaningful by **not** setting `CLIENT_LONG_PASSWORD`. Reading the
    /// extended bits whenever they happen to be non-zero would misinterpret a
    /// MySQL server that left non-zero bytes in its reserved block.
    public static func negotiate(
        handshake: MySQLHandshakeV10,
        desired: MySQLCapabilities = .swizzleDefault,
        desiredMariaDB: MySQLCapabilities = .swizzleMariaDBDefault
    ) -> MySQLNegotiatedCapabilities {
        let standard = handshake.capabilities.intersection(desired)
        let isMariaDB = handshake.isMariaDB

        var mariaDB: MySQLCapabilities = []
        if isMariaDB && !handshake.capabilities.contains(.longPassword) {
            mariaDB = handshake.mariaDBExtendedCapabilities.intersection(desiredMariaDB)
        }

        return MySQLNegotiatedCapabilities(
            capabilities: standard,
            mariaDBCapabilities: mariaDB,
            isMariaDB: isMariaDB
        )
    }
}

extension MySQLCapabilities {
    /// MariaDB extensions we request.
    ///
    /// Never advertise a capability that isn't implemented. Requesting
    /// `MARIADB_CLIENT_EXTENDED_METADATA` makes MariaDB append extra fields to
    /// every `ColumnDefinition41`; without a parser for them every subsequent
    /// field is read at the wrong offset, so column type, charset and length
    /// all come back as plausible-looking garbage rather than an error. That is
    /// how this list came to be empty in the first place.
    ///
    /// `.mariaDBStmtBulkOperations` is here because `COM_STMT_BULK_EXECUTE` now
    /// exists (see `BulkExecute.swift`). Unlike extended metadata it changes
    /// nothing about how the server frames its replies — it only permits a
    /// command we would otherwise be refused — so enabling it cannot corrupt
    /// anything the way that one did.
    ///
    /// Still gated on their implementations:
    ///   - `.mariaDBExtendedMetadata` — needs extended column-metadata parsing
    ///   - `.mariaDBCacheMetadata`    — needs prepared-statement metadata caching
    ///   - `.mariaDBBulkUnitResults`  — needs per-row bulk results (MariaDB 11.5.1+)
    public static let swizzleMariaDBDefault: MySQLCapabilities = [.mariaDBStmtBulkOperations]
}
