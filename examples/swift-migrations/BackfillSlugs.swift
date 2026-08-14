import Foundation
import SwizzleCore
import SwizzleMigrate

/// A migration written in Swift, for the case SQL genuinely cannot express.
///
/// The equivalent of goose's `.go` migrations, with one difference in how it is
/// registered: goose calls `goose.AddMigrationContext(Up, Down)` from `func
/// init()` and takes the version from the filename. Here the version and name
/// are declared on the type and the migration is handed to a `SwiftMigrations`
/// source explicitly — more typing, but a migration you forgot to register is a
/// value you did not pass rather than an import nobody made.
///
/// Before reaching for this: **a large backfill inside a migration is an
/// anti-pattern regardless of language.** It holds the deploy open, cannot be
/// throttled against replica lag, times out, and cannot be resumed. The right
/// shape is a separate idempotent job, with a migration doing only the schema
/// change that makes it possible. This example is deliberately small.
struct BackfillSlugs: SwiftMigration {
    static let version: Int64 = 5
    static let name = "backfill_slugs"

    /// Chunked, so no single statement walks the whole table — and **not**
    /// wrapped in a transaction, which is the half that used to be missing.
    ///
    /// Batching exists to keep transactions short. Running every chunk inside
    /// one long-running transaction defeats the point entirely, which is exactly
    /// what happened before `usesTransaction` existed: the helper and the runner
    /// worked against each other on Postgres and SQLite, and the problem was
    /// invisible on MySQL because its DDL is non-transactional and nothing was
    /// wrapped there anyway.
    ///
    /// goose spells the same choice `AddMigrationNoTxContext`.
    static let usesTransaction = false

    func up(_ db: some MigrationContext) async throws {
        // Keyset pagination, not `LIMIT … OFFSET`: offset makes the database
        // walk and discard every skipped row, so the last batch of a
        // ten-million-row table costs ten million rows of work.
        try await db.batches(over: "users", selecting: "id, email", size: 500) { rows in
            for row in rows {
                guard case .int(let id) = row.values[0],
                    case .text(let email) = row.values[1]
                else { continue }

                // The reason this is not SQL: the rule lives in the application.
                let slug = Self.slugify(email)
                try await db.executeUpdate(
                    "UPDATE users SET slug = ? WHERE id = ?", [.text(slug), .int(id)]
                )
            }
        }
    }

    static func slugify(_ value: String) -> String {
        let allowed = value.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        // Collapse runs of the separator, which a naive map leaves behind.
        var result = ""
        var lastWasSeparator = false
        for character in allowed {
            if character == "-" {
                if !lastWasSeparator { result.append(character) }
                lastWasSeparator = true
            } else {
                result.append(character)
                lastWasSeparator = false
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// A migration that really can be reverted says so by conforming to
/// ``ReversibleSwiftMigration``.
///
/// A separate protocol rather than a flag, because `down` having a default
/// implementation makes "did you write one?" unanswerable at run time — and
/// silently doing nothing on `down` is the worst of the three outcomes. Without
/// this conformance, `down` refuses, which matches a SQL migration that has no
/// `-- +swizzle Down` section.
struct NormaliseEmails: ReversibleSwiftMigration {
    static let version: Int64 = 6
    static let name = "normalise_emails"

    func up(_ db: some MigrationContext) async throws {
        try await db.executeUpdate("UPDATE users SET email = LOWER(email)")
    }

    /// Honest about what it can restore. Lower-casing is not reversible — the
    /// original capitalisation is gone — so this reverts the *schema-visible*
    /// effect and nothing more. Anything else would be a lie told in code.
    func down(_ db: some MigrationContext) async throws {
        // Nothing to undo that can be undone; declared so `down` does not refuse
        // the whole rollback for a migration that is safe to step over.
    }
}
