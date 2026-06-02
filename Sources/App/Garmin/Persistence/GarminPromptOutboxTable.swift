import GRDB
import Shared

final class GarminPromptOutboxTable: DatabaseTableProtocol {
    var tableName: String { "garminPromptOutbox" }

    var definedColumns: [String] { Column.allCases.map(\.rawValue) }

    func createIfNeeded(database: DatabaseQueue) throws {
        let shouldCreateTable = try database.read { db in
            try !db.tableExists(tableName)
        }
        if shouldCreateTable {
            try database.write { db in
                try db.create(table: tableName) { t in
                    t.primaryKey(Column.id.rawValue, .text).notNull()
                    t.column(Column.pendingPrompt.rawValue, .jsonText).notNull()
                    t.column(Column.attemptCount.rawValue, .integer).notNull()
                    t.column(Column.nextRetryAt.rawValue, .double)
                    t.column(Column.lastError.rawValue, .text)
                    t.column(Column.lastSentAt.rawValue, .double)
                    t.column(Column.deliveredAt.rawValue, .double)
                }
            }
        } else {
            try migrateColumns(database: database)
        }
    }

    enum Column: String, CaseIterable {
        case id
        case pendingPrompt
        case attemptCount
        case nextRetryAt
        case lastError
        case lastSentAt
        case deliveredAt
    }
}
