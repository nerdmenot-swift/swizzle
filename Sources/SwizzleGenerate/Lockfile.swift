import Crypto
import Foundation
import SwizzleCore
import SwizzleMigrate

/// What was generated, and from what.
///
/// ## Why a lockfile exists at all
///
/// Asking the database is what makes this generator correct without a SQL parser,
/// and it is also its one cost: generation needs a live server. A CI job that had
/// to stand up MySQL to check that committed code was current would be paying
/// that cost on every push, for a check that is really about files.
///
/// So the signatures are written down. `--verify` recomputes the keys from the
/// files on disk, re-emits Swift from the **stored** signatures, and byte-compares
/// against what is committed. No database, and it catches all three ways the tree
/// can go stale: a query edited without regenerating, a migration added without
/// regenerating, and generated code edited by hand.
///
/// What it deliberately cannot prove is that the *database* agrees with the
/// migrations. That is drift detection's job, and the honest safety net is a
/// scheduled `swizzle generate` against a real server.
public struct Lockfile: Codable, Sendable, Equatable {
    /// Bumped when the on-disk shape changes, so an old file fails loudly rather
    /// than decoding into something subtly different.
    public var version: Int
    public var engine: String
    /// Identifies the schema the signatures were derived from.
    public var schemaFingerprint: String
    public var queries: [Entry]

    public static let currentVersion = 1

    public struct Entry: Codable, Sendable, Equatable {
        public var name: String
        public var file: String
        /// Hash of everything that could change this query's shape.
        public var key: String
        public var signature: QuerySignature

        public init(name: String, file: String, key: String, signature: QuerySignature) {
            self.name = name
            self.file = file
            self.key = key
            self.signature = signature
        }
    }

    public init(
        version: Int = Lockfile.currentVersion,
        engine: String, schemaFingerprint: String, queries: [Entry]
    ) {
        self.version = version
        self.engine = engine
        self.schemaFingerprint = schemaFingerprint
        self.queries = queries
    }
}

extension Lockfile {
    /// Identifies the schema **without a database**.
    ///
    /// Hashes the ordered `(identifier, checksum)` pairs of the migrations, both
    /// of which the migrator already computes. Fingerprinting the *introspected*
    /// schema would have been the obvious alternative and is wrong: that output
    /// varies with server version and with settings nobody changed, so the
    /// fingerprint would churn and `--verify` would cry wolf.
    ///
    /// It also means the check that matters most — "has a migration been added
    /// since this was generated" — costs a directory read.
    public static func fingerprint(of migrations: [Migration]) -> String {
        var hasher = SHA256()
        for migration in migrations {
            hasher.update(data: Data(migration.identifier.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(migration.checksum.utf8))
            hasher.update(data: Data([0]))
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Everything that could change what a query generates.
    ///
    /// The generator version is in there so a change to the *emitter* invalidates
    /// the lockfile too — otherwise improving the output would leave every
    /// project's committed code stale with nothing to notice.
    public static func key(
        for query: ParsedQuery, engine: String, schemaFingerprint: String,
        generatorVersion: String
    ) -> String {
        var hasher = SHA256()
        for part in [
            query.name, query.sql, query.cardinality.rawValue,
            query.parameters.map { "\($0.name):\($0.type)" }.joined(separator: ","),
            query.notNull.sorted().joined(separator: ","),
            query.nullable.sorted().joined(separator: ","),
            // Sorted, because a dictionary has no order and an unsorted rendering
            // would make the key differ between runs on identical input. Included
            // at all because a `Type` directive changes the emitted Swift: leaving
            // it out would let `--verify` pass on output that no longer matches
            // the file it came from, which is the one thing the lockfile exists to
            // catch.
            query.types.sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value.declaredName)" }
                .joined(separator: ","),
            engine, schemaFingerprint, generatorVersion,
        ] {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The generator's own version, bumped when emitted output changes.
    public static let generatorVersion = "1"
}

// MARK: - Reading and writing

extension Lockfile {
    /// Sorted keys and a trailing newline: a lockfile is read in diffs, so a
    /// stable byte order matters more than compactness.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    public static func read(from path: String) throws -> Lockfile {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let lockfile = try JSONDecoder().decode(Lockfile.self, from: data)
        guard lockfile.version == Lockfile.currentVersion else {
            throw LockfileError(
                reason: "lockfile is version \(lockfile.version), this swizzle writes "
                    + "version \(Lockfile.currentVersion) — regenerate with `swizzle generate`"
            )
        }
        return lockfile
    }

    public func write(to path: String) throws {
        try encoded().write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

public struct LockfileError: Error, Sendable, CustomStringConvertible {
    public let reason: String
    public var description: String { reason }
}

// MARK: - Verification

extension Lockfile {
    /// What `--verify` found.
    public struct Verification: Sendable {
        public var staleQueries: [String] = []
        public var missingFromLockfile: [String] = []
        public var removedFromQueries: [String] = []
        public var schemaChanged = false

        public var isClean: Bool {
            staleQueries.isEmpty && missingFromLockfile.isEmpty
                && removedFromQueries.isEmpty && !schemaChanged
        }

        /// A message that says what to do, not merely what is wrong.
        ///
        /// When the schema changed, the per-query stale list is suppressed: every
        /// key contains the schema fingerprint, so a new migration makes all of
        /// them differ at once. Listing thirty queries as "edited" when none were
        /// touched buries the one fact that matters.
        public var report: String {
            guard !isClean else { return "lockfile is current" }
            var lines: [String] = []
            if schemaChanged {
                lines.append("  the migrations have changed since this was generated")
            } else {
                for name in staleQueries { lines.append("  '\(name)' has been edited") }
            }
            for name in missingFromLockfile { lines.append("  '\(name)' is new since this was generated") }
            for name in removedFromQueries { lines.append("  '\(name)' is in the lockfile but no longer defined") }
            return "generated code is stale — run `swizzle generate`:\n"
                + lines.joined(separator: "\n")
        }
    }

    /// Compares the lockfile against the files on disk. **No database.**
    public func verify(
        against queries: [ParsedQuery], migrations: [Migration], engine: String
    ) -> Verification {
        var result = Verification()

        let currentFingerprint = Lockfile.fingerprint(of: migrations)
        result.schemaChanged = currentFingerprint != schemaFingerprint || engine != self.engine

        let recorded = Dictionary(uniqueKeysWithValues: self.queries.map { ($0.name, $0) })
        for query in queries {
            guard let entry = recorded[query.name] else {
                result.missingFromLockfile.append(query.name)
                continue
            }
            let key = Lockfile.key(
                for: query, engine: engine, schemaFingerprint: currentFingerprint,
                generatorVersion: Lockfile.generatorVersion
            )
            if key != entry.key { result.staleQueries.append(query.name) }
        }

        let defined = Set(queries.map(\.name))
        for entry in self.queries where !defined.contains(entry.name) {
            result.removedFromQueries.append(entry.name)
        }
        return result
    }

    /// The signatures, ready to re-emit from without a database.
    public func resolved(matching queries: [ParsedQuery]) -> [ResolvedQuery] {
        let declarations = Dictionary(uniqueKeysWithValues: queries.map { ($0.name, $0) })
        return self.queries.compactMap { entry in
            guard let declaration = declarations[entry.name] else { return nil }
            return ResolvedQuery(declaration: declaration, signature: entry.signature)
        }
    }
}
