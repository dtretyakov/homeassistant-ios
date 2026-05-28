import Foundation
import Shared

final class GarminStatusSnapshotService {
    typealias ItemInfoProvider = (MagicItem) -> MagicItem.Info?
    typealias StateProvider = (MagicItem, Server) async throws -> ControlEntityProvider.State?

    private static let maxParallelFetches = 16

    private let stateProvider: StateProvider
    private let dateProvider: () -> Date

    init(dateProvider: @escaping () -> Date = Date.init) {
        self.stateProvider = { item, server in
            try await GarminStatusSnapshotService.defaultStateProvider(item: item, server: server)
        }
        self.dateProvider = dateProvider
    }

    init(
        stateProvider: @escaping StateProvider,
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.stateProvider = stateProvider
        self.dateProvider = dateProvider
    }

    func snapshot(
        config: GarminConfig,
        itemInfo: @escaping ItemInfoProvider
    ) async throws -> GarminStatusSnapshot {
        await snapshotResult(items: Self.statusItems(for: config), itemInfo: itemInfo).snapshot
    }

    func snapshot(
        items: [MagicItem],
        itemInfo: @escaping ItemInfoProvider
    ) async -> GarminStatusSnapshot {
        await snapshotResult(items: items, itemInfo: itemInfo).snapshot
    }

    func snapshotWithCacheFallback(
        config: GarminConfig,
        itemInfo: @escaping ItemInfoProvider,
        items: [MagicItem]? = nil
    ) async -> Result<GarminStatusSnapshot, GarminIntegrationError> {
        let selectedItems = items ?? Self.statusItems(for: config)
        let statusIds = Self.statusIds(for: selectedItems)
        let result = await snapshotResult(items: selectedItems, itemInfo: itemInfo)
        if result.hasFetchFailure,
           let cachedSnapshot = try? GarminStatusSnapshotCache.cachedSnapshot(statusIds: statusIds) {
            let snapshot = mergeCachedValues(
                cachedSnapshot,
                into: result.snapshot,
                failedStatusIds: result.failedStatusIds
            )
            cacheSnapshot(result.snapshot, statusIds: statusIds, excluding: result.failedStatusIds)
            GarminDiagnostics.record(.valueSnapshot, status: .success, metadata: [
                "cache_status": "fallback",
                "status_count": snapshot.statuses.count,
            ])
            return .success(snapshot)
        }

        cacheSnapshot(result.snapshot, statusIds: statusIds, excluding: result.failedStatusIds)
        GarminDiagnostics.record(.valueSnapshot, status: .success, metadata: [
            "cache_status": "fresh",
            "status_count": result.snapshot.statuses.count,
        ])
        return .success(result.snapshot)
    }

    func cachedSnapshot(
        config: GarminConfig,
        items: [MagicItem]? = nil
    ) -> Result<GarminStatusSnapshot, GarminIntegrationError> {
        let selectedItems = items ?? Self.statusItems(for: config)
        let statusIds = Self.statusIds(for: selectedItems)
        guard let cachedSnapshot = try? GarminStatusSnapshotCache.cachedSnapshot(statusIds: statusIds) else {
            GarminDiagnostics.record(.valueSnapshot, status: .failed, metadata: [
                "cache_status": "miss",
                "error_code": GarminIntegrationError.homeAssistantUnavailable.rawValue,
                "status_count": statusIds.count,
            ])
            return .failure(.homeAssistantUnavailable)
        }
        GarminDiagnostics.record(.valueSnapshot, status: .success, metadata: [
            "cache_status": "cached_fast",
            "status_count": cachedSnapshot.statuses.count,
        ])
        return .success(cachedSnapshot)
    }

    static func statusIds(for config: GarminConfig) -> [String] {
        statusIds(for: statusItems(for: config))
    }

    static func statusIds(for items: [MagicItem]) -> [String] {
        statusItems(from: items)
            .filter { GarminSupportedDomains.supportsStatus($0) }
            .map { GarminConfig.opaqueItemId(for: $0) }
    }

    private static func statusItems(for config: GarminConfig) -> [MagicItem] {
        statusItems(from: GarminOverviewVisibleEntityRegistry.shared.visibleStatusItems(limit: GarminConfig.maxSectionItems) + config.customStatusItems)
    }

    private static func statusItems(from items: [MagicItem]) -> [MagicItem] {
        var seen = Set<String>()
        return Array(items
            .filter { GarminSupportedDomains.supportsStatus($0) }
            .filter { item in
                guard !seen.contains(item.serverUniqueId) else { return false }
                seen.insert(item.serverUniqueId)
                return true
            }
            .prefix(GarminConfig.maxStatusItems))
    }

    private func snapshotResult(
        items: [MagicItem],
        itemInfo: @escaping ItemInfoProvider
    ) async -> SnapshotResult {
        let updatedAt = dateProvider().timeIntervalSince1970
        let statusItems = Self.statusItems(from: items)
        var valuesByIndex: [Int: GarminStatusValue] = [:]
        var hasFetchFailure = false
        var failedStatusIds = Set<String>()

        await withTaskGroup(of: ItemSnapshotResult.self) { group in
            var nextIndex = 0

            func enqueueNext() {
                guard nextIndex < statusItems.count else { return }
                let index = nextIndex
                let item = statusItems[index]
                nextIndex += 1
                group.addTask {
                    await self.statusValue(for: item, index: index, itemInfo: itemInfo)
                }
            }

            for _ in 0..<min(Self.maxParallelFetches, statusItems.count) {
                enqueueNext()
            }

            while let result = await group.next() {
                valuesByIndex[result.index] = result.value
                hasFetchFailure = hasFetchFailure || result.hadFetchFailure
                if result.hadFetchFailure {
                    failedStatusIds.insert(result.value.id)
                }
                enqueueNext()
            }
        }

        let values = valuesByIndex.keys.sorted().compactMap { valuesByIndex[$0] }
        return SnapshotResult(
            snapshot: GarminStatusSnapshot(statuses: values, updatedAt: updatedAt),
            hasFetchFailure: hasFetchFailure,
            failedStatusIds: failedStatusIds
        )
    }

    private func mergeCachedValues(
        _ cachedSnapshot: GarminStatusSnapshot,
        into freshSnapshot: GarminStatusSnapshot,
        failedStatusIds: Set<String>
    ) -> GarminStatusSnapshot {
        var cachedValuesById: [String: GarminStatusValue] = [:]
        cachedSnapshot.statuses.forEach { cachedValuesById[$0.id] = $0 }
        let statuses = freshSnapshot.statuses.map { status in
            guard failedStatusIds.contains(status.id),
                  let cachedStatus = cachedValuesById[status.id] else {
                return status
            }
            return cachedStatus
        }
        return GarminStatusSnapshot(statuses: statuses, updatedAt: freshSnapshot.updatedAt)
    }

    private func cacheSnapshot(
        _ snapshot: GarminStatusSnapshot,
        statusIds: [String],
        excluding skippedStatusIds: Set<String>
    ) {
        let cacheableStatuses = snapshot.statuses.filter { !skippedStatusIds.contains($0.id) }
        guard !cacheableStatuses.isEmpty else { return }

        do {
            try GarminStatusSnapshotCache.save(
                GarminStatusSnapshot(statuses: cacheableStatuses, updatedAt: snapshot.updatedAt),
                statusIds: statusIds
            )
        } catch {
            Current.Log.error("Failed to cache Garmin status snapshot: \(error)")
        }
    }

    private func statusValue(
        for item: MagicItem,
        index: Int,
        itemInfo: ItemInfoProvider
    ) async -> ItemSnapshotResult {
        let info = itemInfo(item)
        let label = item.name(info: info ?? .fallback(for: item))
        let iconName = item.customization?.icon ?? info?.iconName

        guard let server = Current.servers.server(forServerIdentifier: item.serverId) else {
            return .init(
                index: index,
                value: statusValue(for: item, label: label, value: "Unavailable", iconName: iconName),
                hadFetchFailure: true
            )
        }

        do {
            let state = try await stateProvider(item, server)
            return .init(
                index: index,
                value: statusValue(for: item, label: label, value: displayValue(for: state), iconName: iconName),
                hadFetchFailure: false
            )
        } catch {
            return .init(
                index: index,
                value: statusValue(for: item, label: label, value: "Unavailable", iconName: iconName),
                hadFetchFailure: true
            )
        }
    }

    private static func defaultStateProvider(
        item: MagicItem,
        server: Server
    ) async throws -> ControlEntityProvider.State? {
        try await ControlEntityProvider(domains: []).stateResult(server: server, entityId: item.id)
    }

    private func statusValue(
        for item: MagicItem,
        label: String,
        value: String,
        iconName: String?
    ) -> GarminStatusValue {
        GarminStatusValue(
            id: GarminConfig.opaqueItemId(for: item),
            label: label,
            value: value,
            iconName: iconName
        )
    }

    private func displayValue(for state: ControlEntityProvider.State?) -> String {
        guard let state else { return "Unavailable" }
        let value = state.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "Unavailable" }

        if let unit = state.unitOfMeasurement?.trimmingCharacters(in: .whitespacesAndNewlines),
           !unit.isEmpty,
           !value.contains(unit) {
            return "\(value) \(unit)"
        }
        return value
    }

    private struct SnapshotResult {
        let snapshot: GarminStatusSnapshot
        let hasFetchFailure: Bool
        let failedStatusIds: Set<String>
    }

    private struct ItemSnapshotResult {
        let index: Int
        let value: GarminStatusValue
        let hadFetchFailure: Bool
    }
}

private extension MagicItem.Info {
    static func fallback(for item: MagicItem) -> MagicItem.Info {
        .init(id: item.type.rawValue, name: item.displayText ?? item.type.rawValue, iconName: "")
    }
}
