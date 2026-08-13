import SwizzleCore

/// Conditional building, for the parts of a query that are not always there.
///
/// `.where()` already accumulates and ANDs, so optional *filters* need nothing.
/// What it does not cover is everything else that can be conditional — a join
/// added only when a caller asked to expand a relation, an `ORDER BY` chosen from
/// a request parameter, a `LIMIT` applied only when paginating. Without this you
/// end up with a `var query =` and a stack of `if` statements that breaks the
/// chain in half.
///
/// Kysely calls this `$if` and warns it costs TypeScript compile time. In Swift
/// it is a non-generic method returning `Self`, so it costs the solver nothing.
public protocol SQLConditionallyBuildable {}

extension SQLConditionallyBuildable {
    /// Applies `transform` only when `condition` holds.
    ///
    /// ```swift
    /// db.select(u.id, u.name).from(u)
    ///   .if(includeOrders) { $0.leftJoin(o, on: o.userID == u.id) }
    ///   .if(sortByName)   { $0.orderBy(u.name.asc) }
    /// ```
    public func `if`(_ condition: Bool, _ transform: (Self) -> Self) -> Self {
        condition ? transform(self) : self
    }

    /// Applies `transform` when `value` is non-nil, handing it the unwrapped value.
    ///
    /// The common shape in an HTTP handler, where the filter and the thing being
    /// filtered on arrive together or not at all:
    ///
    /// ```swift
    /// query.ifLet(request.city) { $0.where(u.city == $1) }
    /// ```
    public func ifLet<T>(_ value: T?, _ transform: (Self, T) -> Self) -> Self {
        guard let value else { return self }
        return transform(self, value)
    }
}

extension SelectQuery: SQLConditionallyBuildable {}
extension UpdateQuery: SQLConditionallyBuildable {}
extension DeleteQuery: SQLConditionallyBuildable {}
extension InsertQuery: SQLConditionallyBuildable {}
