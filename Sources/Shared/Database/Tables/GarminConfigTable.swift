import Foundation
import GRDB

final class GarminConfigTable: DatabaseTableProtocol {
    var tableName: String { GRDBDatabaseTable.garminConfig.rawValue }

    var definedColumns: [String] { DatabaseTables.GarminConfig.allCases.map(\.rawValue) }

    func createIfNeeded(database: DatabaseQueue) throws {
        let shouldCreateTable = try database.read { db in
            try !db.tableExists(tableName)
        }
        if shouldCreateTable {
            try database.write { db in
                try db.create(table: tableName) { t in
                    t.primaryKey(DatabaseTables.GarminConfig.id.rawValue, .text).notNull()
                    t.column(DatabaseTables.GarminConfig.selectedServerId.rawValue, .text)
                    t.column(DatabaseTables.GarminConfig.actionItems.rawValue, .jsonText).notNull()
                    t.column(DatabaseTables.GarminConfig.statusItems.rawValue, .jsonText).notNull()
                    t.column(DatabaseTables.GarminConfig.deviceIdentifier.rawValue, .text)
                    t.column(DatabaseTables.GarminConfig.appIdentifier.rawValue, .text)
                    t.column(DatabaseTables.GarminConfig.lastSyncTimestamp.rawValue, .double)
                    t.column(DatabaseTables.GarminConfig.lastError.rawValue, .text)
                }
            }
        } else {
            try migrateColumns(database: database)
        }
    }
}
