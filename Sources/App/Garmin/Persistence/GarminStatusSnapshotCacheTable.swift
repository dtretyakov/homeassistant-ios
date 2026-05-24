import Foundation
import GRDB
import Shared

final class GarminStatusSnapshotCacheTable: DatabaseTableProtocol {
    var tableName: String { "garminStatusSnapshotCache" }

    var definedColumns: [String] { Column.allCases.map(\.rawValue) }

    func createIfNeeded(database: DatabaseQueue) throws {
        let shouldCreateTable = try database.read { db in
            try !db.tableExists(tableName)
        }
        if shouldCreateTable {
            try database.write { db in
                try db.create(table: tableName) { t in
                    t.primaryKey(Column.id.rawValue, .text).notNull()
                    t.column(Column.statusIds.rawValue, .jsonText).notNull()
                    t.column(Column.snapshot.rawValue, .jsonText).notNull()
                }
            }
        } else {
            try migrateColumns(database: database)
        }
    }

    enum Column: String, CaseIterable {
        case id
        case statusIds
        case snapshot
    }
}
