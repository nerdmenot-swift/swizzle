// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Swizzle",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "Swizzle", targets: ["Swizzle"]),
        .library(name: "SwizzleMySQL", targets: ["SwizzleMySQL"]),
        .library(name: "SwizzleMigrate", targets: ["SwizzleMigrate"]),
        .library(name: "SwizzleOnlineDDL", targets: ["SwizzleOnlineDDL"]),
        .library(name: "SwizzleMySQLEngine", targets: ["SwizzleMySQLEngine"]),
        .library(name: "SwizzleSQLite", targets: ["SwizzleSQLite"]),
        .library(name: "SwizzleSQLiteEngine", targets: ["SwizzleSQLiteEngine"]),
        .library(name: "SwizzlePostgres", targets: ["SwizzlePostgres"]),
        .executable(name: "swizzle", targets: ["SwizzleCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.82.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "5.0.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.4"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.6.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.4.1"),
        // Executable-only. Pure Swift, so it builds for static musl like the
        // rest, and no library target depends on it.
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.4.0"),
        // postgres-nio used to be here. It was adopted rather than written
        // because it is mature and async-native — and then twice its access
        // control blocked something the wire already carried: the command tag's
        // affected-row count, and `Describe`, which pillar 3 cannot do without.
        // `SwizzlePostgresDriver` replaced it. The connection pool is still
        // postgres-nio's, vendored under `SwizzleConnectionPool`.
    ],
    targets: [
        // Dialects, SQL IR, rendering. No query-builder generics live here.
        .target(name: "SwizzleCore"),

        // The typed builder surface. This is the target whose compile time we care about.
        .target(name: "SwizzleQuery", dependencies: ["SwizzleCore"]),

        // Pillar 1: SQL-first migrations. Depends on SwizzleCore only — not on
        // any driver — so the same migrator runs against MySQL, Postgres and
        // SQLite through `SQLExecutor`.
        .target(
            name: "SwizzleMigrate",
            dependencies: [
                "SwizzleCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(name: "SwizzleMigrateTests", dependencies: ["SwizzleMigrate"]),
        .testTarget(
            name: "SwizzleOnlineDDLTests",
            dependencies: [
                "SwizzleOnlineDDL", "SwizzleMySQLEngine", "SwizzleMigrate",
                "SwizzleMySQL", "SwizzleCore",
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),

        // Umbrella re-export.
        .target(name: "Swizzle", dependencies: ["SwizzleCore", "SwizzleQuery"]),

        // Type-checker spike: realistic worst-case queries, one per function body
        // so -warn-long-function-bodies attributes cost precisely.
        // Zero-downtime ALTER, driven by our own binlog client. Separate module
        // because it needs both the migrator and the MySQL driver, and because
        // it is MySQL-only where SwizzleMigrate is not.
        .target(
            name: "SwizzleOnlineDDL",
            dependencies: ["SwizzleMigrate", "SwizzleMySQL", "SwizzleCore"]
        ),

        // Joins the driver to the migrator. Separate so `SwizzleMySQL` stays
        // usable on its own and `SwizzleMigrate` never learns MySQL exists.
        .target(
            name: "SwizzleMySQLEngine",
            dependencies: [
                "SwizzleMigrate", "SwizzleMySQL", "SwizzleOnlineDDL", "SwizzleCore",
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),

        // Pillar 3: the code generator. Engine-agnostic — it reaches every
        // database through `EngineConnection`, and links no driver.
        .target(
            name: "SwizzleGenerate",
            dependencies: [
                "SwizzleMigrate", "SwizzleCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "SwizzleGenerateTests",
            dependencies: [
                "SwizzleGenerate", "SwizzleSQLite", "SwizzleSQLiteEngine", "SwizzleCore",
                "SwizzleMigrate",
                // The committed generated code in `examples/codegen`, so the
                // golden suite can *call* it rather than only diff its text.
                "SwizzleExamples",
            ]
        ),

        // Postgres, ours. Replaces postgres-nio, whose access control blocked
        // pillar 3 — see docs/postgres-protocol-checklist.md for why, and
        // references/README.md for what it is grounded on.
        .target(
            name: "SwizzlePostgresDriver",
            dependencies: [
                "SwizzleCore", "SwizzleConnectionPool",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                // TLSUserEvent (handshake completion) lives here, not in NIOSSL.
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Metrics", package: "swift-metrics"),
            ]
        ),
        .testTarget(
            name: "SwizzlePostgresDriverTests",
            dependencies: [
                "SwizzlePostgresDriver", "SwizzleCore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        ),

        // SQLite, the driver: connection, values, errors, the reader pool,
        // transactions. `CSQLite` and `SwizzleCore` and nothing else — the same
        // rule the other two drivers follow, so it can be lifted out as a
        // standalone package without dragging the migrator with it.
        .target(
            name: "SwizzleSQLite",
            dependencies: ["CSQLite", "SwizzleCore"]
        ),

        // SQLite, the engine seam: migration dialect, query analyzer, shadow
        // database. Split out because it needs `SwizzleMigrate` and the driver
        // does not — the same split MySQL and Postgres already had, which SQLite
        // was the odd one out in lacking.
        .target(
            name: "SwizzleSQLiteEngine",
            dependencies: ["SwizzleSQLite", "SwizzleMigrate", "SwizzleCore"]
        ),
        .testTarget(
            name: "SwizzleSQLiteTests",
            dependencies: [
                "SwizzleSQLite", "SwizzleSQLiteEngine", "SwizzleMigrate",
                "SwizzleQuery", "SwizzleCore",
            ]
        ),

        // Postgres, the engine seam: URL parsing, executor, introspector,
        // dialect. The driver beneath it is `SwizzlePostgresDriver`, the same
        // split MySQL has.
        .target(
            name: "SwizzlePostgres",
            dependencies: [
                "SwizzleMigrate", "SwizzleCore", "SwizzlePostgresDriver",
                // For the URL's `sslrootcert` / `sslcert` / `sslkey`, which build
                // a `TLSConfiguration` rather than just naming a mode.
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ]
        ),
        .testTarget(
            name: "SwizzlePostgresTests",
            dependencies: [
                "SwizzlePostgres", "SwizzleMigrate", "SwizzleCore",
                "SwizzlePostgresDriver",
            ]
        ),

        // The `swizzle` command-line tool.
        .executableTarget(
            name: "SwizzleCLI",
            dependencies: [
                "SwizzleMigrate",
                "SwizzleMySQLEngine",
                "SwizzleSQLite",
                "SwizzleSQLiteEngine",
                "SwizzleGenerate",
                "SwizzlePostgres",
                "SwizzleCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),

        .executableTarget(name: "SwizzleSpike", dependencies: ["Swizzle"]),

        // A/B control: the same queries written against a deliberately naive builder
        // (types grow per join, operators generic on both operands, arity overloads).
        // Separate module so its operator overloads can't contaminate the measurement.
        .executableTarget(name: "SwizzleNaiveSpike", dependencies: ["SwizzleCore"]),

        // Generic async connection pool, vendored unmodified from postgres-nio
        // (MIT). Self-contained: Atomics + DequeModule only. Serves every
        // dialect — see Sources/SwizzleConnectionPool/README.md.
        .target(
            name: "SwizzleConnectionPool",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "DequeModule", package: "swift-collections"),
            ],
            // Both are kept deliberately — the licence because this is vendored
            // from postgres-nio and the attribution travels with it, the README
            // because it records what was changed. Declared here so SwiftPM
            // stops warning about them on every single build.
            exclude: ["LICENSE-postgres-nio.txt", "README.md"]
        ),

        // The pool arrived vendored *without* upstream's tests, and it showed:
        // 50.7% covered, with the uncovered half being the rare-path logic —
        // establish failure, backoff, keep-alive, idle timeout, graceful
        // shutdown. That is the component every query on both network drivers
        // flows through, and those are exactly the paths that only run when
        // something has already gone wrong.
        .testTarget(name: "SwizzleConnectionPoolTests", dependencies: ["SwizzleConnectionPool"]),

        // libsodium's ref10 Edwards25519, vendored (ISC — see
        // Sources/CSodiumEd25519/LIBSODIUM-LICENSE).
        //
        // Only the ed25519 subset: ~7.4k lines rather than all of libsodium.
        // ref10 is portable C99 with no assembly and no CPU-feature detection,
        // which is what lets it build for static musl as well as macOS and
        // glibc. The platform glue that libsodium keeps in `utils.c` — guarded
        // allocation, mlock, mprotect — is deliberately *not* vendored; see
        // shim.c.
        .target(
            name: "CSodiumEd25519",
            exclude: ["LIBSODIUM-LICENSE"],
            cSettings: [
                .headerSearchPath("vendor"),
                .headerSearchPath("vendor/include"),
                // Silences libsodium's "compiled using an undocumented method"
                // warning. configure sets exactly this.
                .define("CONFIGURED", to: "1"),
                // Selects the fe_51 field implementation (radix 2^51 over
                // __int128) instead of fe_25_5. Guarded on the compiler
                // actually having 128-bit integers, so 32-bit targets fall back
                // rather than fail to build.
                .define("HAVE_TI_MODE", .when(platforms: [.macOS, .iOS, .linux])),
            ]
        ),

        // Zstandard, vendored (BSD — see Sources/CZstd/ZSTD-LICENSE).
        //
        // Unlike zlib, zstd is available *nowhere* by default: not in the macOS
        // SDK, not in Apple's Compression framework (LZFSE/LZ4/LZMA/ZLIB/BROTLI
        // only), not in the static musl sysroot, not in the Swift Docker image.
        // So a `systemLibrary` target has nothing to link against and vendoring
        // is the only way to keep "no system dependencies, builds static musl".
        //
        // File selection and flags follow the recipe in `compressionz`
        // (Apache 2.0, github.com/NerdMeNot/compressionz): 26 sources, no
        // assembly, no threading, no legacy formats.
        .target(
            name: "CZstd",
            exclude: ["ZSTD-LICENSE"],
            cSettings: [
                .headerSearchPath("vendor"),
                .headerSearchPath("vendor/common"),
                .headerSearchPath("vendor/compress"),
                .headerSearchPath("vendor/decompress"),
                // Single-threaded: the multithreaded compressor pulls in
                // pthreads and buys nothing for packet-sized payloads.
                .define("ZSTD_MULTITHREAD", to: "0"),
                // No pre-1.0 frame formats; nothing emits them.
                .define("ZSTD_LEGACY_SUPPORT", to: "0"),
                // The one that matters for portability: zstd's hand-written
                // amd64 assembly is skipped, so the same sources build for
                // aarch64, x86_64 and musl alike.
                .define("ZSTD_DISABLE_ASM", to: "1"),
            ]
        ),

        // zlib, for the compressed wire protocol. System library rather than a
        // vendored copy: it ships in the macOS SDK, in every Linux distribution,
        // and — verified — in the static Linux SDK's musl sysroot, so fully
        // static Linux builds get it too.
        // Only the one-shot entry points are used — see Sources/CZlib/shim.h.
        .systemLibrary(
            name: "CZlib",
            path: "Sources/CZlib",
            providers: [.apt(["zlib1g-dev"]), .yum(["zlib-devel"]), .brew(["zlib"])]
        ),

        // SQLite, vendored (public domain — see Sources/CSQLite/SQLITE-LICENSE).
        // Why vendored rather than linked: Sources/CSQLite/include/shim.h.
        .target(
            name: "CSQLite",
            exclude: ["SQLITE-LICENSE"],
            sources: ["vendor/sqlite3.c"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                // Thread-safe, but without SQLite's own per-connection mutex:
                // every call already goes through one serial queue per
                // connection, so the mutex would be paid for twice.
                .define("SQLITE_THREADSAFE", to: "2"),
                // The features Swizzle's own SQL depends on, made explicit so a
                // build that lacks them fails here rather than at runtime.
                .define("SQLITE_ENABLE_COLUMN_METADATA", to: "1"),
                .define("SQLITE_ENABLE_FTS5", to: "1"),
                .define("SQLITE_ENABLE_JSON1", to: "1"),
                .define("SQLITE_ENABLE_RTREE", to: "1"),
                // `DELETE … LIMIT` is off by default, and the builder gates it
                // behind `SupportsWriteLimit` — which SQLite deliberately does
                // *not* conform to, precisely because it depends on this flag.
                // Left off, so the gate keeps telling the truth.
                .define("SQLITE_OMIT_DEPRECATED", to: "1"),
                .define("SQLITE_DQS", to: "0"),
            ]
        ),

        // Our own MySQL/MariaDB wire protocol implementation. MySQLNIO can't meet
        // the streaming or statement-cache requirements — see docs/driver-spike.md.
        .target(
            name: "SwizzleMySQL",
            dependencies: [
                "SwizzleCore",
                "SwizzleConnectionPool",
                "CZlib",
                "CZstd",
                "CSodiumEd25519",
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                // TLSUserEvent (handshake completion) lives here, not in NIOSSL.
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto"),
                // RSA-OAEP for caching_sha2_password full authentication.
                // Underscored: no API-stability promise, so the version is ranged.
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]
        ),

        // The examples under `examples/`, compiled.
        //
        // No `.library` product, so nothing downstream can import them — they
        // exist to be *read*. Being a build target is what stops them rotting:
        // an example that no longer compiles is worse than no example, because
        // it is the first thing a newcomer copies. goose ships `examples/` the
        // same way, as part of its module rather than as loose files.
        .target(
            name: "SwizzleExamples",
            dependencies: [
                "SwizzleMigrate", "SwizzleCore",
                // A real engine, so the runner example is wired to something
                // that exists rather than to a sketch.
                "SwizzleSQLite", "SwizzleSQLiteEngine",
            ],
            path: "examples",
            // `sources:` alone still leaves SwiftPM warning about the `.sql`
            // files it can see and does not know what to do with.
            exclude: [
                "README.md", "migrations",
                "codegen/README.md", "codegen/migrations", "codegen/queries",
                "codegen/swizzle.lock.json",
            ],
            // Named explicitly rather than letting SwiftPM walk `examples/`,
            // which also holds the `.sql` files the generator reads and the
            // lockfile it writes. `sources:` makes everything else invisible to
            // the build instead of needing an `exclude:` that grows with the
            // directory.
            //
            // `codegen/Generated` is committed *generated* code, compiled here
            // for the reason the emitter exists: the type map produced
            // `[String]` for a Postgres `text[]` once, which does not compile,
            // and nothing caught it until generated code was put in front of the
            // compiler. `CodegenGoldenTests` regenerates it and diffs, so a
            // change to the emitter cannot quietly leave this behind.
            sources: ["swift-migrations", "codegen/Generated"]
        ),
        .testTarget(name: "SwizzleTests", dependencies: ["Swizzle"]),
        .testTarget(
            name: "SwizzleMySQLTests",
            dependencies: [
                "SwizzleMySQL",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ]
        ),

        // Runs against the real servers in docker/. Skips cleanly when they
        // aren't up, so `swift test` stays green without Docker.
        .testTarget(
            name: "SwizzleMySQLIntegrationTests",
            dependencies: [
                "SwizzleMySQL",
                "SwizzleCore",
                "SwizzleQuery",
                "SwizzleMigrate",
                "SwizzleMySQLEngine",
                "SwizzleSQLite",
                "SwizzleOnlineDDL",
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
    ]
)
