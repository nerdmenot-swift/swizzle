import Foundation
import SwizzleCore
import SwizzleMigrate

/// Builds a throwaway database from the migrations and hands back its connection.
///
/// Engine-agnostic on purpose: it asks the engine for a shadow, runs the migrator
/// into it, and never learns which database it is talking to — the same seam the
/// migrator and the CLI already go through.
public enum ShadowRunner {
    /// Creates a shadow, migrates it, runs `body` against it, and destroys it.
    ///
    /// Checksum verification is off inside the shadow: it is empty, so there is no
    /// journal to disagree with, and leaving it on makes a first run fail for a
    /// reason that has nothing to do with the caller.
    public static func withMigratedShadow<T>(
        engine: any DatabaseEngine.Type,
        url: String,
        migrations: any MigrationSource,
        label: String = "codegen",
        _ body: (any EngineConnection) async throws -> T
    ) async throws -> T {
        let shadow = try await engine.makeShadow(url: url, label: label)
        do {
            var configuration = Migrator.Configuration()
            configuration.verifyChecksums = false
            let migrator = Migrator(
                executor: shadow.connection.executor,
                dialect: shadow.connection.dialect,
                source: migrations,
                configuration: configuration
            )
            _ = try await migrator.up()

            let result = try await body(shadow.connection)
            await shadow.destroy()
            return result
        } catch {
            // Destroyed on the failure path too, or a broken migration leaves a
            // scratch database behind on every run.
            await shadow.destroy()
            throw error
        }
    }
}
