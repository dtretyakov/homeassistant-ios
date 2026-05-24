import Foundation
import GRDB
import Shared

public struct GarminStatusSnapshotCache: Codable, FetchableRecord, PersistableRecord, Equatable {
    public static var cacheId: String { "garmin-status-snapshot-cache" }

    public var id: String
    public var statusIds: [String]
    public var snapshot: GarminStatusSnapshot

    public init(
        id: String = GarminStatusSnapshotCache.cacheId,
        statusIds: [String],
        snapshot: GarminStatusSnapshot
    ) {
        self.id = id
        self.statusIds = statusIds
        self.snapshot = snapshot
    }

    public static func cachedSnapshot(statusIds: [String]) throws -> GarminStatusSnapshot? {
        try GarminDatabaseSchema.createIfNeeded()
        return try Current.database().read { db -> GarminStatusSnapshot? in
            let cache = try GarminStatusSnapshotCache.fetchOne(db, key: cacheId)
            guard let cache,
                  cache.statusIds == statusIds,
                  cache.snapshot.statuses.map(\.id) == statusIds else {
                return nil
            }
            return cache.snapshot
        }
    }

    public static func save(_ snapshot: GarminStatusSnapshot, statusIds: [String]) throws {
        try GarminDatabaseSchema.createIfNeeded()
        try Current.database().write { db in
            try GarminStatusSnapshotCache(statusIds: statusIds, snapshot: snapshot).save(db)
        }
    }

    public static func clear() throws {
        try GarminDatabaseSchema.createIfNeeded()
        try Current.database().write { db in
            _ = try GarminStatusSnapshotCache.deleteAll(db)
        }
    }
}
