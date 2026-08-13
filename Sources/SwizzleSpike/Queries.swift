import Swizzle

// Each query lives in its own function so -warn-long-function-bodies attributes
// cost to exactly one construct. Escalating difficulty, plus two deliberate A/B
// pairs: operator-vs-function booleans, and projection pack width.

// MARK: - Baseline

func q01_trivial() -> (sql: String, bindings: [SQLValue]) {
    pg.select(users.id, users.name)
        .from(users)
        .where(users.isActive == true)
        .build()
}

// MARK: - Literal-heavy predicates (integer literal inference stress)

func q02_literalHeavy() -> (sql: String, bindings: [SQLValue]) {
    pg.select(users.id, users.name, users.karma)
        .from(users)
        .where(users.age > 18 && users.age < 65 && users.karma >= 100 && users.karma <= 10_000)
        .orderBy(users.karma.desc, users.name.asc)
        .limit(50)
        .build()
}

// MARK: - Two-table join

func q03_join() -> (sql: String, bindings: [SQLValue]) {
    pg.select(posts.id, posts.title, users.name)
        .from(posts)
        .innerJoin(users, on: posts.authorId == users.id)
        .where(posts.isPublished == true && users.isActive == true)
        .orderBy(posts.createdAt.desc)
        .limit(20)
        .build()
}

// MARK: - The realistic worst case
// 4-table join, aggregates, GROUP BY, HAVING, nested boolean predicate, ORDER BY, LIMIT.

func q04_fourTableAggregate() -> (sql: String, bindings: [SQLValue]) {
    pg.select(users.id, users.name, countDistinct(posts.id), avg(posts.score), max(comments.createdAt))
        .from(users)
        .innerJoin(posts, on: posts.authorId == users.id)
        .leftJoin(comments, on: comments.postId == posts.id)
        .leftJoin(postTags, on: postTags.postId == posts.id)
        .where(
            users.isActive == true
                && posts.isPublished == true
                && (comments.isDeleted == false || comments.isDeleted.isNull)
                && users.countryCode.in(["US", "GB", "DE", "IN"])
                && posts.createdAt > 1_700_000_000
        )
        .groupBy(users.id, users.name)
        .having(countDistinct(posts.id) > 5 && avg(posts.score) > 3.5)
        .orderBy(users.name.asc, users.id.desc)
        .limit(100)
        .offset(200)
        .build()
}

// MARK: - A/B pair: same query, `and(...)` instead of `&&`

func q05_fourTableAggregate_functionForm() -> (sql: String, bindings: [SQLValue]) {
    pg.select(users.id, users.name, countDistinct(posts.id), avg(posts.score), max(comments.createdAt))
        .from(users)
        .innerJoin(posts, on: posts.authorId == users.id)
        .leftJoin(comments, on: comments.postId == posts.id)
        .leftJoin(postTags, on: postTags.postId == posts.id)
        .where(
            and(
                users.isActive == true,
                posts.isPublished == true,
                or(comments.isDeleted == false, comments.isDeleted.isNull),
                users.countryCode.in(["US", "GB", "DE", "IN"]),
                posts.createdAt > 1_700_000_000
            )
        )
        .groupBy(users.id, users.name)
        .having(and(countDistinct(posts.id) > 5, avg(posts.score) > 3.5))
        .orderBy(users.name.asc, users.id.desc)
        .limit(100)
        .offset(200)
        .build()
}

// MARK: - Correlated subquery via EXISTS

func q06_correlatedExists() -> (sql: String, bindings: [SQLValue]) {
    let recentComment = pg.select(comments.id)
        .from(comments)
        .where(
            comments.postId == posts.id
                && comments.isDeleted == false
                && comments.createdAt > 1_700_000_000
        )

    return pg.select(posts.id, posts.title, posts.viewCount)
        .from(posts)
        .where(posts.isPublished == true && exists(recentComment))
        .orderBy(posts.viewCount.desc)
        .limit(25)
        .build()
}

// MARK: - Self-join with aliases + subquery source

func q07_aliasedSelfJoin() -> (sql: String, bindings: [SQLValue]) {
    let author = Users(as: "author")
    let commenter = Users(as: "commenter")

    return pg.select(author.name, commenter.name, countStar())
        .from(comments)
        .innerJoin(posts, on: comments.postId == posts.id)
        .innerJoin(author, on: posts.authorId == author.id)
        .innerJoin(commenter, on: comments.authorId == commenter.id)
        .where(author.id != commenter.id && comments.isDeleted == false)
        .groupBy(author.name, commenter.name)
        .having(countStar() > 3)
        .orderBy(countStar().desc)
        .limit(10)
        .build()
}

// MARK: - Projection pack width A/B: 2 vs 8 vs 16 columns

func q08_packWidth2() -> (sql: String, bindings: [SQLValue]) {
    pg.select(users.id, users.name)
        .from(users)
        .build()
}

func q09_packWidth8() -> (sql: String, bindings: [SQLValue]) {
    pg.select(
        users.id, users.email, users.name, users.age,
        users.isActive, users.karma, users.bio, users.countryCode
    )
    .from(users)
    .where(users.isActive == true && users.age > 21)
    .build()
}

func q10_packWidth16() -> (sql: String, bindings: [SQLValue]) {
    pg.select(
        users.id, users.email, users.name, users.age,
        users.isActive, users.karma, users.bio, users.countryCode,
        posts.id, posts.title, posts.body, posts.viewCount,
        posts.score, posts.isPublished, posts.publishedAt, posts.createdAt
    )
    .from(users)
    .innerJoin(posts, on: posts.authorId == users.id)
    .where(users.isActive == true && posts.isPublished == true)
    .orderBy(posts.createdAt.desc)
    .limit(50)
    .build()
}

// MARK: - Dialect capability gating (the design's core claim)

func q11_postgresOnlyDistinctOn() -> (sql: String, bindings: [SQLValue]) {
    pg.select(posts.authorId, posts.id, posts.title)
        .from(posts)
        .distinctOn(posts.authorId)
        .where(posts.isPublished == true)
        .orderBy(posts.authorId.asc, posts.createdAt.desc)
        .build()
}

func q12_sqliteAndMysqlRenderDifferently() -> [(String, [SQLValue])] {
    let sqliteQuery = lite.select(users.id, users.name)
        .from(users)
        .where(users.age > 18)
        .limit(10)
        .build()

    let mysqlQuery = my.select(users.id, users.name)
        .from(users)
        .where(users.age > 18)
        .limit(10)
        .build()

    return [(sqliteQuery.sql, sqliteQuery.bindings), (mysqlQuery.sql, mysqlQuery.bindings)]
}

func q13_capabilityGatedInserts() -> [String] {
    // Postgres: ON CONFLICT + RETURNING both available.
    let pgInsert = InsertQuery<Postgres, Users>(into: users)
        .values { $0.set(users.email, to: "a@b.com"); $0.set(users.name, to: "Ada") }
        .onConflict(users.email).doNothing()
        .returning(users.id, users.createdAt)

    // MySQL: ON DUPLICATE KEY UPDATE + INSERT IGNORE, no RETURNING.
    let myInsert = InsertQuery<MySQL, Users>(into: users)
        .values { $0.set(users.email, to: "a@b.com"); $0.set(users.name, to: "Ada") }
        .orIgnore()
        .onDuplicateKeyUpdate { $0.set(users.name, to: $0.values(users.name)) }

    // MariaDB: MySQL's upsert syntax *and* RETURNING.
    let mariaInsert = InsertQuery<MariaDB, Users>(into: users)
        .values { $0.set(users.email, to: "a@b.com") }
        .onDuplicateKeyUpdate { $0.set(users.name, to: "Ada") }
        .returning(users.id)

    return [
        "pg returning cols: \(pgInsert.insert.returning.count)",
        "mysql ignore: \(myInsert.ignoreDuplicates)",
        "mariadb returning cols: \(mariaInsert.insert.returning.count)",
    ]
}

// These must NOT compile. Uncomment individually to verify the gating is real.
//
// func negative_mysqlCannotReturn() {
//     _ = InsertQuery<MySQL, Users>(into: users).returning(users.id)
//     //                                         ^ referencing instance method 'returning'
//     //                                           requires that 'MySQL' conform to 'SupportsReturning'
// }
//
// func negative_mysqlHasNoDistinctOn() {
//     _ = my.select(users.id).from(users).distinctOn(users.id)
//     //                                  ^ requires 'MySQL' conform to 'SupportsDistinctOn'
// }
//
// func negative_postgresHasNoOnDuplicateKey() {
//     _ = InsertQuery<Postgres, Users>(into: users).onDuplicateKeyUpdate([])
//     //                                           ^ requires 'Postgres' conform to
//     //                                             'SupportsOnDuplicateKeyUpdate'
// }
