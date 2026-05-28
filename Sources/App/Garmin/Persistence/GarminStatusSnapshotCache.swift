import Foundation
import GRDB
import Shared

public struct GarminStatusSnapshotCache: Codable, FetchableRecord, PersistableRecord, Equatable {
    public static var cacheId: String { "garmin-status-snapshot-cache" }
    private static let itemCachePrefix = "item:"

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
            var statusesById: [String: GarminStatusValue] = [:]
            var updatedAt: TimeInterval = 0

            for statusId in statusIds {
                guard let cache = try GarminStatusSnapshotCache.fetchOne(db, key: itemCacheId(for: statusId)),
                      cache.statusIds == [statusId],
                      let status = cache.snapshot.statuses.first,
                      status.id == statusId else {
                    continue
                }
                statusesById[statusId] = status
                updatedAt = max(updatedAt, cache.snapshot.updatedAt)
            }

            let itemStatuses = statusIds.compactMap { statusesById[$0] }
            if !itemStatuses.isEmpty {
                return GarminStatusSnapshot(statuses: itemStatuses, updatedAt: updatedAt)
            }

            guard let legacyCache = try GarminStatusSnapshotCache.fetchOne(db, key: cacheId) else { return nil }
            var legacyStatusesById: [String: GarminStatusValue] = [:]
            legacyCache.snapshot.statuses.forEach { legacyStatusesById[$0.id] = $0 }
            let legacyStatuses = statusIds.compactMap { legacyStatusesById[$0] }
            guard !legacyStatuses.isEmpty else { return nil }
            return GarminStatusSnapshot(statuses: legacyStatuses, updatedAt: legacyCache.snapshot.updatedAt)
        }
    }

    public static func save(_ snapshot: GarminStatusSnapshot, statusIds: [String]) throws {
        try GarminDatabaseSchema.createIfNeeded()
        try Current.database().write { db in
            let requestedStatusIds = Set(statusIds)
            for status in snapshot.statuses where requestedStatusIds.contains(status.id) {
                let itemSnapshot = GarminStatusSnapshot(statuses: [status], updatedAt: snapshot.updatedAt)
                try GarminStatusSnapshotCache(
                    id: itemCacheId(for: status.id),
                    statusIds: [status.id],
                    snapshot: itemSnapshot
                ).save(db)
            }
        }
    }

    public static func clear() throws {
        try GarminDatabaseSchema.createIfNeeded()
        try Current.database().write { db in
            _ = try GarminStatusSnapshotCache.deleteAll(db)
        }
    }

    private static func itemCacheId(for statusId: String) -> String {
        itemCachePrefix + statusId
    }
}
