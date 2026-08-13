import SwizzleCore
import Testing
@testable import SwizzlePostgresDriver

@Suite("Postgres SQLSTATE mapping")
struct PostgresErrorMappingTests {

    func error(_ sqlState: String, _ message: String = "boom", constraint: String? = nil)
        -> PostgresConnectionError
    {
        var fields: [UInt8: String] = [0x53: "ERROR", 0x43: sqlState, 0x4D: message]
        if let constraint { fields[0x6E] = constraint }
        return .server(PostgresServerMessage(fields: fields))
    }

    // MARK: - The four constraint kinds a caller branches on

    @Test("integrity violations map to their own kinds")
    func constraintViolations() {
        #expect(error("23505").sqlKind == .uniqueViolation)
        #expect(error("23503").sqlKind == .foreignKeyViolation)
        #expect(error("23502").sqlKind == .notNullViolation)
        #expect(error("23514").sqlKind == .checkViolation)
    }

    /// An exclusion constraint says "this row overlaps one already there", which
    /// is what a caller does about a duplicate too.
    @Test("an exclusion violation is handled like a duplicate")
    func exclusionViolation() {
        #expect(error("23P01").sqlKind == .uniqueViolation)
    }

    /// Postgres names the constraint. MySQL only puts it in the message text,
    /// where it has to be scraped back out.
    @Test("the violated constraint is named")
    func constraintIsNamed() {
        guard case .server(let message) = error("23505", constraint: "users_email_key") else {
            Issue.record("expected a server error"); return
        }
        #expect(message.violatedConstraint == "users_email_key")
    }

    // MARK: - Retry safety, the reason the taxonomy exists

    /// Both are the server picking a victim and telling it to try again.
    @Test("deadlock and serialization failure are safe to retry")
    func retryableFailures() {
        #expect(error("40P01").sqlKind == .deadlock)
        #expect(error("40001").sqlKind == .serializationFailure)
        // Transient and certainly not applied — the conjunction is the point.
        #expect(error("40P01").isSafeToRetry)
        #expect(error("40001").isSafeToRetry)
    }

    /// **Postgres answers this more definitively than MySQL can.** Any error
    /// aborts the transaction and there is no non-transactional storage engine to
    /// leave half a statement behind.
    @Test("a server error means nothing was applied")
    func serverErrorsAppliedNothing() {
        #expect(!error("23505").mayHaveApplied)
        #expect(!error("42601").mayHaveApplied)
        #expect(!error("40P01").mayHaveApplied)
    }

    /// The exception: a shutdown or dropped connection can arrive after the
    /// statement committed, and the wire cannot say which side of the commit it
    /// fell on.
    @Test("a departing server leaves the statement's fate unknown")
    func departingServerIsUnknown() {
        #expect(error("57P01").mayHaveApplied)   // admin_shutdown
        #expect(error("08006").mayHaveApplied)   // connection_failure
        #expect(error("XX000").mayHaveApplied)   // internal_error
        // And so a retry is never automatic, however transient it looks.
        #expect(!error("08006").isSafeToRetry)
    }

    // MARK: - The class fallback

    /// SQLSTATE is **hierarchical** — the first two characters are the class — so
    /// a code Postgres adds tomorrow in class `23` is an integrity violation
    /// today. This is why the table can be short without losing anything.
    @Test("an unknown code still classifies through its class")
    func unknownCodesFallBackToClass() {
        // Invented codes, none of which are in the table.
        #expect(error("23999").sqlKind == .checkViolation)      // class 23, integrity
        #expect(error("08999").sqlKind == .connection)          // class 08
        #expect(error("42ZZZ").sqlKind == .syntax)              // class 42
        #expect(error("28999").sqlKind == .authentication)      // class 28
        #expect(error("40999").sqlKind == .serializationFailure)
    }

    @Test("a class nobody has heard of is other, not a crash")
    func unknownClass() {
        #expect(error("ZZ000").sqlKind == .other)
        #expect(error("").sqlKind == .other)
    }

    // MARK: - The rest of the table

    @Test("syntax and permission are distinguished within class 42")
    func class42IsNotAllSyntax() {
        #expect(error("42601").sqlKind == .syntax)       // syntax_error
        #expect(error("42P01").sqlKind == .syntax)       // undefined_table
        #expect(error("42703").sqlKind == .syntax)       // undefined_column
        // Same class, entirely different response.
        #expect(error("42501").sqlKind == .permission)   // insufficient_privilege
    }

    /// Both `statement_timeout` and a client `CancelRequest` land on 57014, which
    /// is why cancellation and timeout are one kind rather than two.
    @Test("a cancelled query is a timeout")
    func cancellation() {
        #expect(error("57014").sqlKind == .timeout)
        #expect(error("57014").sqlKind.isTransient)
    }

    /// **The exception inside its own class.** Class `57` is operator
    /// intervention, which mostly means the server is going away and the
    /// statement's fate is unknown — but `57014` means it was *cancelled*, which
    /// Postgres implements by aborting it.
    ///
    /// Left in the class, this made every cancelled or timed-out statement look
    /// like it might have landed, so `isSafeToRetry` said no to the one family of
    /// failures that is unambiguously safe to retry.
    @Test("a cancelled statement is known not to have applied, unlike its class")
    func cancellationIsNotApplied() {
        #expect(!error("57014").mayHaveApplied)
        #expect(error("57014").isSafeToRetry)

        // The rest of class 57 is still unknown: a shutdown can arrive after a
        // commit, and the wire cannot say which side of it we are on.
        #expect(error("57P01").mayHaveApplied)
        #expect(error("57P03").mayHaveApplied)
        #expect(!error("57P01").isSafeToRetry)
    }

    @Test("locks, space and read-only map through")
    func remainingCodes() {
        #expect(error("55P03").sqlKind == .lockTimeout)
        #expect(error("53100").sqlKind == .outOfSpace)
        #expect(error("25006").sqlKind == .readOnly)
        #expect(error("22001").sqlKind == .dataTooLong)
        #expect(error("22003").sqlKind == .numericOutOfRange)
        // Too many connections is about the server, not the disk, despite sharing
        // class 53 with the resource exhaustion codes.
        #expect(error("53300").sqlKind == .connection)
    }

    @Test("a missing catalog or schema is a syntax-level failure")
    func missingObjects() {
        #expect(error("3D000").sqlKind == .syntax)   // invalid_catalog_name
        #expect(error("3F000").sqlKind == .syntax)   // invalid_schema_name
    }

    // MARK: - Non-server failures

    @Test("connection-level failures never claim to be statement failures")
    func connectionLevelFailures() {
        let auth = PostgresConnectionError.authentication(.insecureCleartextRefused)
        #expect(auth.sqlKind == .authentication)
        #expect(!auth.sqlKind.isStatementLevel)
        // No statement was ever sent.
        #expect(!auth.mayHaveApplied)

        #expect(PostgresConnectionError.unexpected(during: "query").sqlKind == .connection)
        // Position in the stream is unknown, so the conservative answer stands.
        #expect(PostgresConnectionError.unexpected(during: "query").mayHaveApplied)
    }

    /// Postgres has no numeric error code — SQLSTATE *is* the code. Reporting one
    /// would mean inventing it.
    @Test("SQLSTATE carries through and no native code is invented")
    func codesCarryThrough() {
        #expect(error("23505").sqlState == "23505")
        #expect(error("23505").nativeCode == nil)
        // An error with no SQLSTATE reports none rather than an empty string.
        #expect(PostgresConnectionError.server(PostgresServerMessage(fields: [:])).sqlState == nil)
    }
}
