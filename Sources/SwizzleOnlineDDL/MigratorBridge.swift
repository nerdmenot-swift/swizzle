import Foundation
import SwizzleMigrate

extension MySQLOnlineDDL: OnlineDDLRunner {
    public func run(table: String, alterClause: String) async throws {
        try await alter(table: table, alterClause)
    }
}
