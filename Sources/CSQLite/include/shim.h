// SQLite, vendored.
//
// ## Why vendored rather than linked from the system
//
// The first attempt was a `systemLibrary` target, on the assumption — copied from
// the zlib note without checking — that libsqlite3 is present everywhere. It is
// not: the **static Linux SDK's musl sysroot has no SQLite at all**, so a
// `--swift-sdk …-musl` build failed at `#include <sqlite3.h>`. Fully static Linux
// binaries are a property this project keeps, and losing them for one engine is
// not a trade worth making.
//
// Having to vendor turned out to be the better answer anyway, for a reason that
// has nothing to do with musl: **version skew**. Swizzle's SQLite support needs
// `RETURNING` (3.35, 2021) for the migration lock and `pragma_table_info` (3.16)
// for introspection. Distributions ship whatever they ship, and a system SQLite
// too old for either fails at runtime, on one machine, with an error that points
// at our SQL rather than at the library. A pinned copy makes the feature set a
// fact rather than a hope.
//
// Public domain — see Sources/CSQLite/SQLITE-LICENSE.
#include "sqlite3.h"
