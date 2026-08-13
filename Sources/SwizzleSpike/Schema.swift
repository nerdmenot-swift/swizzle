import Swizzle

// Hand-written in exactly the shape the future `@Table` macro will emit.
// For a type-checker spike this is the correct methodology: macro output is
// plain structs, so expanding a macro here would only add build latency to the
// measurement loop without changing what the solver sees at the call site.

struct Users: SQLTable {
    static let tableName = "users"
    var tableAlias: String?

    init(as alias: String? = nil) { self.tableAlias = alias }

    var id: SQLExpression<Int64> { column("id") }
    var email: SQLExpression<String> { column("email") }
    var name: SQLExpression<String> { column("name") }
    var age: SQLExpression<Int64> { column("age") }
    var isActive: SQLExpression<Bool> { column("is_active") }
    var karma: SQLExpression<Int64> { column("karma") }
    var bio: SQLExpression<String?> { column("bio") }
    var countryCode: SQLExpression<String> { column("country_code") }
    var createdAt: SQLExpression<Int64> { column("created_at") }
    var updatedAt: SQLExpression<Int64> { column("updated_at") }
}

struct Posts: SQLTable {
    static let tableName = "posts"
    var tableAlias: String?

    init(as alias: String? = nil) { self.tableAlias = alias }

    var id: SQLExpression<Int64> { column("id") }
    var authorId: SQLExpression<Int64> { column("author_id") }
    var title: SQLExpression<String> { column("title") }
    var body: SQLExpression<String> { column("body") }
    var viewCount: SQLExpression<Int64> { column("view_count") }
    var score: SQLExpression<Double> { column("score") }
    var isPublished: SQLExpression<Bool> { column("is_published") }
    var publishedAt: SQLExpression<Int64?> { column("published_at") }
    var createdAt: SQLExpression<Int64> { column("created_at") }
}

struct Comments: SQLTable {
    static let tableName = "comments"
    var tableAlias: String?

    init(as alias: String? = nil) { self.tableAlias = alias }

    var id: SQLExpression<Int64> { column("id") }
    var postId: SQLExpression<Int64> { column("post_id") }
    var authorId: SQLExpression<Int64> { column("author_id") }
    var body: SQLExpression<String> { column("body") }
    var score: SQLExpression<Double> { column("score") }
    var isDeleted: SQLExpression<Bool> { column("is_deleted") }
    var createdAt: SQLExpression<Int64> { column("created_at") }
}

struct PostTags: SQLTable {
    static let tableName = "post_tags"
    var tableAlias: String?

    init(as alias: String? = nil) { self.tableAlias = alias }

    var postId: SQLExpression<Int64> { column("post_id") }
    var tagId: SQLExpression<Int64> { column("tag_id") }
}

struct Tags: SQLTable {
    static let tableName = "tags"
    var tableAlias: String?

    init(as alias: String? = nil) { self.tableAlias = alias }

    var id: SQLExpression<Int64> { column("id") }
    var slug: SQLExpression<String> { column("slug") }
    var label: SQLExpression<String> { column("label") }
    var useCount: SQLExpression<Int64> { column("use_count") }
}

let users = Users()
let posts = Posts()
let comments = Comments()
let postTags = PostTags()
let tags = Tags()

let pg = QueryBuilder<Postgres>()
let my = QueryBuilder<MySQL>()
let lite = QueryBuilder<SQLite>()
