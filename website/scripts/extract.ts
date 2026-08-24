/**
 * Pulls the site's content out of the library, so no page has to invent any.
 *
 *     bun run scripts/extract.ts
 *
 * Every SQL string on this site was rendered by the real query builder, and every
 * generated Swift snippet came out of the real generator. Nothing is typed by hand into
 * a code block. The point is narrow and worth stating: Swizzle's central claim is that
 * one expression renders correctly *per dialect*, and a hand-written example proves
 * nothing about that — it only proves somebody once believed it.
 *
 * Three things get extracted:
 *
 *   1. Builder output. One Swift expression, compiled three times against three dialect
 *      types, giving three SQL strings and the bindings each produced.
 *   2. Migration files, read verbatim off disk from `examples/migrations`.
 *   3. Generated code, read verbatim from `examples/codegen/Generated`.
 *
 * Only (1) needs a toolchain. If `swift` is missing the script says so, leaves whatever
 * it wrote last time in place, and exits zero — so `astro dev` works on a fresh clone
 * with no Swift installed, and a stale demo is obvious in the diff rather than silently
 * regenerated as a mock.
 */

import { $ } from 'bun'
import { existsSync, mkdirSync, writeFileSync, readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO = join(HERE, '..', '..')
const OUT = join(HERE, '..', 'src', 'data')

/** The demos, in the order the landing page shows them.
 *
 *  Each is one expression, deliberately: the whole point is that the *same* source
 *  renders differently, so anything that varies between dialects here would defeat the
 *  demonstration. `\(d)` is substituted with the dialect type at build time and is the
 *  only difference between the three compilations.
 */
const DEMOS = [
  {
    id: 'filter',
    title: 'A query',
    blurb: 'Columns are typed, so a predicate that compares a String to an Int is a compile error rather than a runtime surprise.',
    swift: `select(users.id, users.name, users.karma)
    .from(users)
    .where(users.isActive == true && users.karma >= 100)
    .orderBy(users.karma.desc)
    .limit(10)`,
  },
  {
    id: 'join',
    title: 'A join',
    blurb: 'Two tables, and the identifier quoting is the dialect’s own — backticks on MySQL, double quotes elsewhere.',
    swift: `select(posts.id, posts.title, users.name)
    .from(posts)
    .innerJoin(users, on: posts.authorId == users.id)
    .where(posts.isPublished == true)
    .orderBy(posts.createdAt.desc)
    .limit(20)`,
  },
  {
    id: 'aggregate',
    title: 'The one nobody writes by hand',
    blurb: 'Four tables, aggregates, GROUP BY, HAVING. This is where a string-concatenation helper starts producing SQL you have to debug in a terminal.',
    swift: `select(users.id, users.name, countDistinct(posts.id), avg(posts.score))
    .from(users)
    .innerJoin(posts, on: posts.authorId == users.id)
    .leftJoin(comments, on: comments.postId == posts.id)
    .where(users.isActive == true && posts.isPublished == true)
    .groupBy(users.id, users.name)
    .having(countDistinct(posts.id) > 5)
    .orderBy(users.name.asc)
    .limit(100)`,
  },
] as const

const DIALECTS = ['Postgres', 'MySQL', 'SQLite'] as const

/** A throwaway Swift package that imports the real library and prints JSON.
 *
 *  The schema below is the same shape `swizzle generate schema` emits, which keeps the
 *  demo honest: this is what a user's own declarations look like, not a special
 *  arrangement that only works in a demo.
 */
function program(): string {
  const cases = DEMOS.map((demo) =>
    DIALECTS.map(
      (dialect) => `
    do {
        let built = QueryBuilder<${dialect}>().${demo.swift.replace(/\n/g, '\n        ')}
            .build()
        rows.append(Row(demo: "${demo.id}", dialect: "${dialect}",
                        sql: built.sql, bindings: built.bindings.map { "\\($0)" }))
    }`
    ).join('')
  ).join('')

  return `import Swizzle
import SwizzleCore
import Foundation

struct Users: SQLTable {
    static let tableName = "users"
    var tableAlias: String?
    init(as alias: String? = nil) { self.tableAlias = alias }
    var id: SQLExpression<Int64> { column("id") }
    var name: SQLExpression<String> { column("name") }
    var karma: SQLExpression<Int64> { column("karma") }
    var isActive: SQLExpression<Bool> { column("is_active") }
}

struct Posts: SQLTable {
    static let tableName = "posts"
    var tableAlias: String?
    init(as alias: String? = nil) { self.tableAlias = alias }
    var id: SQLExpression<Int64> { column("id") }
    var authorId: SQLExpression<Int64> { column("author_id") }
    var title: SQLExpression<String> { column("title") }
    var score: SQLExpression<Double> { column("score") }
    var isPublished: SQLExpression<Bool> { column("is_published") }
    var createdAt: SQLExpression<Int64> { column("created_at") }
}

struct Comments: SQLTable {
    static let tableName = "comments"
    var tableAlias: String?
    init(as alias: String? = nil) { self.tableAlias = alias }
    var id: SQLExpression<Int64> { column("id") }
    var postId: SQLExpression<Int64> { column("post_id") }
}

let users = Users(), posts = Posts(), comments = Comments()

struct Row: Encodable {
    let demo: String, dialect: String, sql: String, bindings: [String]
}
var rows: [Row] = []
${cases}
let data = try JSONEncoder().encode(rows)
FileHandle.standardOutput.write(data)
`
}

async function buildQueries(): Promise<unknown[] | null> {
  if (!(await $`which swift`.quiet().nothrow()).exitCode) {
    // present
  } else {
    console.warn('  swift not found — leaving the previous extraction in place')
    return null
  }

  const work = join(REPO, '.website-extract')
  mkdirSync(join(work, 'Sources', 'extract'), { recursive: true })
  writeFileSync(
    join(work, 'Package.swift'),
    `// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "extract",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "..")],
    targets: [.executableTarget(name: "extract", dependencies: [
        .product(name: "Swizzle", package: "swizzle"),
    ])]
)
`
  )
  writeFileSync(join(work, 'Sources', 'extract', 'main.swift'), program())

  const run = await $`swift run --package-path ${work} extract`.quiet().nothrow()
  if (run.exitCode !== 0) {
    console.warn('  extraction failed — leaving the previous output in place')
    console.warn(run.stderr.toString().split('\n').slice(-12).join('\n'))
    return null
  }
  return JSON.parse(run.stdout.toString())
}

/** Files read straight off disk. No transformation: the site shows the file. */
function readExample(relative: string): string | null {
  const path = join(REPO, relative)
  return existsSync(path) ? readFileSync(path, 'utf8') : null
}

const queries = await buildQueries()

const payload = {
  generatedAt: null as string | null,
  demos: DEMOS.map((d) => ({ id: d.id, title: d.title, blurb: d.blurb, swift: d.swift })),
  dialects: DIALECTS,
  /** [demo][dialect] -> { sql, bindings } */
  queries,
  migration: readExample('examples/migrations/00001_create_users.sql'),
  queryFile: readExample('examples/codegen/queries/notes.sql'),
  generated: readExample('examples/codegen/Generated/Queries.swift'),
}

mkdirSync(OUT, { recursive: true })
const target = join(OUT, 'demos.json')

if (queries === null && existsSync(target)) {
  // Keep the old builder output rather than blanking the page, but refresh the parts
  // that only needed the filesystem.
  const previous = JSON.parse(readFileSync(target, 'utf8'))
  payload.queries = previous.queries
  payload.generatedAt = previous.generatedAt
}

writeFileSync(target, JSON.stringify(payload, null, 2) + '\n')
console.log(`  wrote ${target}`)
