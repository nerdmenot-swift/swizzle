import NIOCore

/// `COM_STMT_BULK_EXECUTE` — MariaDB's array binding.
///
/// One round trip carries many parameter sets for a single prepared statement,
/// where `COM_STMT_EXECUTE` needs one round trip each. On a high-latency link
/// that is the difference between an insert loop being latency-bound and being
/// throughput-bound.
///
/// MariaDB only, from 10.2, and gated on `MARIADB_CLIENT_STMT_BULK_OPERATIONS`.
/// MySQL has no equivalent.
///
/// ```
/// int<1>  0xFA
/// int<4>  statement id
/// int<2>  flags
/// if flags & SEND_TYPES_TO_SERVER:
///   for each parameter:  int<1> column type, int<1> flags
/// for each row:
///   for each parameter:  int<1> indicator [, binary value if indicator == 0]
/// ```
public struct MySQLBulkExecuteRequest: Sendable {

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        /// Ask for a result set per row rather than one aggregate OK.
        /// MariaDB 11.5.1+, and requires `MARIADB_CLIENT_BULK_UNIT_RESULTS`.
        public static let sendUnitResults = Flags(rawValue: 64)
        public static let sendTypesToServer = Flags(rawValue: 128)
    }

    /// Precedes every value. `none` means a value follows; the rest stand in
    /// for one and occupy no further bytes.
    public enum Indicator: UInt8, Sendable {
        case none = 0x00
        case null = 0x01
        /// Use the column's `DEFAULT`.
        case `default` = 0x02
        /// Leave the column untouched — only meaningful for `UPDATE`.
        case ignore = 0x03
    }

    public var statementID: UInt32
    public var rows: [[MySQLValue]]
    public var sendTypes: Bool
    public var sendUnitResults: Bool

    public init(
        statementID: UInt32,
        rows: [[MySQLValue]],
        sendTypes: Bool = true,
        sendUnitResults: Bool = false
    ) {
        self.statementID = statementID
        self.rows = rows
        self.sendTypes = sendTypes
        self.sendUnitResults = sendUnitResults
    }

    /// One type per parameter, chosen to cover **every** row.
    ///
    /// This is the part that is easy to get wrong. Taking the types from the
    /// first row alone works until a column is NULL there and an integer two
    /// rows later — the server would then have been told `MYSQL_TYPE_NULL` for a
    /// column that carries values, and rejects the batch with a thoroughly
    /// unhelpful "Incorrect arguments to mysqld_stmt_bulk_execute".
    ///
    /// So: `NULL` is a placeholder any concrete type displaces, and flags are
    /// unioned — one unsigned value in one row makes the whole column unsigned.
    static func columnTypes(for rows: [[MySQLValue]]) -> [(MySQLColumnType, UInt8)] {
        guard let first = rows.first else { return [] }
        var types = first.map { MySQLStatementCommands.parameterType($0) }

        for row in rows.dropFirst() {
            for (index, value) in row.enumerated() where index < types.count {
                let candidate = MySQLStatementCommands.parameterType(value)
                if types[index].0 == .null {
                    types[index] = candidate
                } else if candidate.0 == .null {
                    continue
                } else if types[index].0 == candidate.0 {
                    types[index].1 |= candidate.1
                }
                // Genuinely different types for one parameter is a caller error.
                // The server reports it; guessing a winner here would only make
                // the failure harder to trace.
            }
        }
        return types
    }

    public enum BulkError: Error, Sendable, Equatable {
        case noRows
        case noParameters
        case mixedArity(expected: Int, found: Int)
    }

    public func serialize(into buffer: inout ByteBuffer) throws {
        guard let first = rows.first else { throw BulkError.noRows }
        // MariaDB rejects a bulk request with no parameters outright, so this is
        // caught here rather than surfacing as a server error.
        guard !first.isEmpty else { throw BulkError.noParameters }

        let arity = first.count
        for row in rows where row.count != arity {
            throw BulkError.mixedArity(expected: arity, found: row.count)
        }

        buffer.writeInteger(MySQLCommand.stmtBulkExecute.rawValue)
        buffer.writeInteger(statementID, endianness: .little)

        var flags: Flags = []
        if sendTypes { flags.insert(.sendTypesToServer) }
        if sendUnitResults { flags.insert(.sendUnitResults) }
        buffer.writeInteger(flags.rawValue, endianness: .little)

        if sendTypes {
            for (type, typeFlags) in Self.columnTypes(for: rows) {
                buffer.writeInteger(type.rawValue)
                buffer.writeInteger(typeFlags)
            }
        }

        for row in rows {
            for value in row {
                if value.isNull {
                    buffer.writeInteger(Indicator.null.rawValue)
                } else {
                    buffer.writeInteger(Indicator.none.rawValue)
                    MySQLStatementCommands.encodeBinary(value, into: &buffer)
                }
            }
        }
    }

    /// Serialised size, so a caller can split a batch before it exceeds
    /// `max_allowed_packet`.
    public var estimatedSize: Int {
        // 1 command byte + 4 statement id + 2 flags.
        var total = 7
        if sendTypes, let first = rows.first { total += first.count * 2 }
        for row in rows {
            for value in row {
                total += 1                                    // indicator
                if !value.isNull { total += MySQLStatementCommands.binaryLength(value) }
            }
        }
        return total
    }

    /// Splits `rows` into batches that each fit inside `maxAllowedPacket`.
    ///
    /// Bulk execute exists to make large inserts cheap, so the batch that is too
    /// large to send is the expected case, not an edge one. A row that cannot
    /// fit on its own is a caller error and is returned in a batch of its own so
    /// the server's rejection names it.
    public static func batches(
        rows: [[MySQLValue]],
        maxAllowedPacket: Int,
        sendTypes: Bool = true
    ) -> [[[MySQLValue]]] {
        guard !rows.isEmpty else { return [] }
        let overhead = 7 + (sendTypes ? (rows[0].count * 2) : 0)
        let limit = max(maxAllowedPacket - 4, 1)

        var batches: [[[MySQLValue]]] = []
        var current: [[MySQLValue]] = []
        var size = overhead

        for row in rows {
            var rowSize = 0
            for value in row {
                rowSize += 1
                if !value.isNull { rowSize += MySQLStatementCommands.binaryLength(value) }
            }
            if !current.isEmpty && size + rowSize > limit {
                batches.append(current)
                current = []
                size = overhead
            }
            current.append(row)
            size += rowSize
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
}
