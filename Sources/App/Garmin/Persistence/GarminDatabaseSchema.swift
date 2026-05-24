import GRDB
import Shared

enum GarminDatabaseSchema {
    static func createIfNeeded(database: DatabaseQueue = Current.database()) throws {
        try GarminConfigTable().createIfNeeded(database: database)
        try GarminStatusSnapshotCacheTable().createIfNeeded(database: database)
    }
}
