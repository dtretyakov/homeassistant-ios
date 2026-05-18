import Foundation
import GRDB

final class GarminStatusSnapshotCacheTable: DatabaseTableProtocol {
    var tableName: String { GRDBDatabaseTable.garminStatusSnapshotCache.rawValue }

    var definedColumns: [String] { DatabaseTables.GarminStatusSnapshotCache.allCases.map(\.rawValue) }

    func createIfNeeded(database: DatabaseQueue) throws {
        let shouldCreateTable = try database.read { db in
            try !db.tableExists(tableName)
        }
        if shouldCreateTable {
            try database.write { db in
                try db.create(table: tableName) { t in
                    t.primaryKey(DatabaseTables.GarminStatusSnapshotCache.id.rawValue, .text).notNull()
                    t.column(DatabaseTables.GarminStatusSnapshotCache.statusIds.rawValue, .jsonText).notNull()
                    t.column(DatabaseTables.GarminStatusSnapshotCache.snapshot.rawValue, .jsonText).notNull()
                }
            }
        } else {
            try migrateColumns(database: database)
        }
    }
}
