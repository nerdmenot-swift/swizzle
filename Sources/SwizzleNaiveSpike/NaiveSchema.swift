import SwizzleCore

struct NUsers: SQLTable {
    static let tableName = "users"
    var tableAlias: String?
    var id: NCol<Int64> { NCol(node: .column(qualifier: "users", name: "id")) }
    var name: NCol<String> { NCol(node: .column(qualifier: "users", name: "name")) }
    var age: NCol<Int64> { NCol(node: .column(qualifier: "users", name: "age")) }
    var isActive: NCol<Bool> { NCol(node: .column(qualifier: "users", name: "is_active")) }
    var countryCode: NCol<String> { NCol(node: .column(qualifier: "users", name: "country_code")) }
}

struct NPosts: SQLTable {
    static let tableName = "posts"
    var tableAlias: String?
    var id: NCol<Int64> { NCol(node: .column(qualifier: "posts", name: "id")) }
    var authorId: NCol<Int64> { NCol(node: .column(qualifier: "posts", name: "author_id")) }
    var viewCount: NCol<Int64> { NCol(node: .column(qualifier: "posts", name: "view_count")) }
    var score: NCol<Double> { NCol(node: .column(qualifier: "posts", name: "score")) }
    var isPublished: NCol<Bool> { NCol(node: .column(qualifier: "posts", name: "is_published")) }
    var createdAt: NCol<Int64> { NCol(node: .column(qualifier: "posts", name: "created_at")) }
}

struct NComments: SQLTable {
    static let tableName = "comments"
    var tableAlias: String?
    var postId: NCol<Int64> { NCol(node: .column(qualifier: "comments", name: "post_id")) }
    var isDeleted: NCol<Bool> { NCol(node: .column(qualifier: "comments", name: "is_deleted")) }
    var createdAt: NCol<Int64> { NCol(node: .column(qualifier: "comments", name: "created_at")) }
}

struct NPostTags: SQLTable {
    static let tableName = "post_tags"
    var tableAlias: String?
    var postId: NCol<Int64> { NCol(node: .column(qualifier: "post_tags", name: "post_id")) }
}

let nusers = NUsers()
let nposts = NPosts()
let ncomments = NComments()
let npostTags = NPostTags()

/// Byte-for-byte the same query as `q04_fourTableAggregate` in the tuned design.
func naive_q04_fourTableAggregate() -> (sql: String, bindings: [SQLValue]) {
    nSelect(
        Postgres.self,
        nusers.id, nusers.name, nCountDistinct(nposts.id), nAvg(nposts.score), nMax(ncomments.createdAt)
    )
    .from(nusers)
    .innerJoin(nposts, on: nposts.authorId == nusers.id)
    .leftJoin(ncomments, on: ncomments.postId == nposts.id)
    .leftJoin(npostTags, on: npostTags.postId == nposts.id)
    .where(
        nusers.isActive == true
            && nposts.isPublished == true
            && (ncomments.isDeleted == false || ncomments.isDeleted.nIsNull)
            && nusers.countryCode.nIn(["US", "GB", "DE", "IN"])
            && nposts.createdAt > 1_700_000_000
    )
    .groupBy(nusers.id, nusers.name)
    .having(nCountDistinct(nposts.id) > 5 && nAvg(nposts.score) > 3.5)
    .orderBy(nusers.name.nAsc, nusers.id.nDesc)
    .limit(100)
    .offset(200)
    .build()
}
