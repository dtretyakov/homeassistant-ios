import Foundation
import GRDB
import Shared

final class GarminConfigTable: DatabaseTableProtocol {
    var tableName: String { "garminConfig" }

    var definedColumns: [String] { Column.allCases.map(\.rawValue) }

    func createIfNeeded(database: DatabaseQueue) throws {
        let shouldCreateTable = try database.read { db in
            try !db.tableExists(tableName)
        }
        if shouldCreateTable {
            try database.write { db in
                try db.create(table: tableName) { t in
                    t.primaryKey(Column.id.rawValue, .text).notNull()
                    t.column(Column.selectedServerId.rawValue, .text)
                    t.column(Column.actionItems.rawValue, .jsonText).notNull()
                    t.column(Column.statusItems.rawValue, .jsonText).notNull()
                    t.column(Column.deviceIdentifier.rawValue, .text)
                    t.column(Column.appIdentifier.rawValue, .text)
                    t.column(Column.lastSyncTimestamp.rawValue, .double)
                    t.column(Column.lastError.rawValue, .text)
                }
            }
        } else {
            try migrateColumns(database: database)
        }
    }

    enum Column: String, CaseIterable {
        case id
        case selectedServerId
        case actionItems
        case statusItems
        case deviceIdentifier
        case appIdentifier
        case lastSyncTimestamp
        case lastError
    }
}
