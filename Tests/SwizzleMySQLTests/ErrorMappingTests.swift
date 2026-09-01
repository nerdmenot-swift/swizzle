import Testing
@testable import SwizzleMySQL

/// Classifying a server error, and the one distinction that makes automatic
/// retry safe.
///
/// ## Why `mayHaveApplied` is the interesting half
///
/// `isSafeToRetry` is `isTransient && !mayHaveApplied`, and the conjunction is
/// the whole point: a deadlock is transient *and* rolled back, so retrying it
/// is free; a connection that dropped mid-statement is transient but may have
/// applied, so retrying could double a payment.
///
/// Getting either half wrong has a direction. Too permissive duplicates writes.
/// Too conservative refuses to retry the failures that exist to be retried —
/// which is the shape the Postgres pass found in `57014`.
@Suite("MySQL error mapping")
struct MySQLErrorMappingTests {

    static func server(_ code: UInt16, _ state: String = "HY000") -> MySQLProtocolError {
        .server(code: code, sqlState: state, message: "test")
    }

    // MARK: - Retry safety

    /// The two codes InnoDB rolls back before reporting. They are the only
    /// server errors this driver will retry automatically, and the reason is
    /// the rollback rather than the transience.
    @Test("deadlock and lock timeout are the retryable server errors")
    func retryableServerErrors() {
        for code: UInt16 in [1213, 1205] {
            #expect(!Self.server(code).mayHaveApplied, "\(code) rolls back")
            #expect(Self.server(code).sqlKind.isTransient, "\(code) is worth retrying")
            #expect(Self.server(code).isSafeToRetry, "\(code)")
        }
    }

    /// Everything else that reaches the server is conservative, because a MySQL
    /// statement is not atomic in general — a multi-row INSERT that hits a
    /// duplicate key has already written the rows before it, and a
    /// non-transactional engine does not roll back at all.
    @Test("an ordinary server error is not assumed to have applied nothing")
    func ordinaryServerErrorsAreConservative() {
        for code: UInt16 in [1062, 1064, 1146, 1451, 1048, 1406] {
            #expect(
                Self.server(code).mayHaveApplied,
                "\(code): MySQL cannot promise a partially-applied statement was undone"
            )
            #expect(!Self.server(code).isSafeToRetry, "\(code) must not retry automatically")
        }
    }

    /// A connection failure is transient but its statement's fate is unknown,
    /// which is exactly the combination that must not retry.
    @Test("a connection failure is transient but never safe to retry")
    func connectionFailures() {
        for code: UInt16 in [2006, 2013, 1053, 1077] {
            #expect(Self.server(code).sqlKind == .connection, "\(code)")
            #expect(Self.server(code).sqlKind.isTransient)
            #expect(Self.server(code).mayHaveApplied)
            #expect(!Self.server(code).isSafeToRetry, "\(code) could double a write")
        }
        #expect(MySQLProtocolError.connectionClosed("peer went away").sqlKind == .connection)
        #expect(MySQLProtocolError.connectionClosed("peer went away").mayHaveApplied)
    }

    // MARK: - The timeout codes

    /// **MariaDB reports its own code**, and it was not mapped — so a MariaDB
    /// statement timeout arrived as `.other`: not transient, not recognisable
    /// as a timeout by any caller deciding what to do about it.
    ///
    /// The codes were read off the running fixtures rather than taken from the
    /// error tables. MySQL 8.0, 8.4 and 9.1 all report 3024; MariaDB 11.4 and
    /// 12.3 report 1969.
    @Test("both flavours' execution-timeout codes are recognised")
    func executionTimeouts() {
        #expect(Self.server(3024).sqlKind == .timeout, "MySQL max_execution_time")
        #expect(Self.server(1969, "70100").sqlKind == .timeout, "MariaDB max_statement_time")
        #expect(Self.server(1317).sqlKind == .timeout, "KILL QUERY")
        for code: UInt16 in [3024, 1969, 1317] {
            #expect(Self.server(code).sqlKind.isTransient, "\(code)")
        }
    }

    /// A timed-out statement is **not** treated as certainly-not-applied, which
    /// is the opposite of the Postgres driver's answer for `57014`.
    ///
    /// Pinned as a decision rather than left implicit: Postgres cancels by
    /// aborting, so nothing applied. MariaDB's `max_statement_time` is not
    /// restricted to `SELECT`, and neither it nor a `KILL QUERY` can promise a
    /// non-transactional table was left alone.
    @Test("a timed-out statement is not assumed to have been rolled back")
    func timeoutsAreConservative() {
        for code: UInt16 in [3024, 1969, 1317] {
            #expect(Self.server(code).mayHaveApplied, "\(code)")
            #expect(!Self.server(code).isSafeToRetry, "\(code)")
        }
    }

    // MARK: - The rest of the taxonomy

    @Test("constraint violations are named rather than lumped together")
    func constraintViolations() {
        #expect(Self.server(1062).sqlKind == .uniqueViolation)
        #expect(Self.server(1586).sqlKind == .uniqueViolation)
        #expect(Self.server(1451).sqlKind == .foreignKeyViolation)
        #expect(Self.server(1452).sqlKind == .foreignKeyViolation)
        #expect(Self.server(1048).sqlKind == .notNullViolation)
        #expect(Self.server(1364).sqlKind == .notNullViolation)
        #expect(Self.server(3819).sqlKind == .checkViolation)
    }

    /// Corruption is separated from `.other` because the answer is a repair or
    /// a backup, not a retry — and a caller that cannot tell them apart will
    /// retry a damaged table forever.
    @Test("corruption is distinguished from an unrecognised error")
    func corruption() {
        for code: UInt16 in [1034, 1194, 1195, 1712, 1877] {
            #expect(Self.server(code).sqlKind == .dataCorrupted, "\(code)")
            #expect(!Self.server(code).sqlKind.isTransient, "retrying will not help")
        }
        #expect(Self.server(9999).sqlKind == .other, "an unmapped code is not invented")
    }

    @Test("the diagnostic fields carry through")
    func diagnostics() {
        let error = Self.server(1062, "23000")
        #expect(error.nativeCode == 1062)
        #expect(error.sqlState == "23000")
        #expect(MySQLProtocolError.connectionClosed("peer went away").nativeCode == nil)
        #expect(MySQLProtocolError.connectionClosed("peer went away").sqlState == nil)
    }

    /// Every mapped code, asserted to be transient or not exactly once — so a
    /// code added to the wrong group is caught here rather than by a caller
    /// retrying something it should not.
    @Test("only the intended codes are transient")
    func transientSetIsExact() {
        let transient: Set<UInt16> = [1213, 1205, 1317, 3024, 1969, 2006, 2013, 1053, 1077]
        let mapped: [UInt16] = [
            1062, 1586, 1451, 1452, 1216, 1217, 1048, 1364, 3819, 3813,
            1213, 1205, 1406, 1265, 1264, 1690, 1044, 1045, 1142, 1143, 1227,
            1064, 1146, 1054, 1051, 1109, 1021, 1114, 3, 1290, 1836,
            1317, 3024, 1969, 2006, 2013, 1053, 1077, 1034, 1194, 1195, 1712, 1877,
        ]
        for code in mapped {
            #expect(
                Self.server(code).sqlKind.isTransient == transient.contains(code),
                "\(code) is on the wrong side of the transient line"
            )
        }
    }
}
