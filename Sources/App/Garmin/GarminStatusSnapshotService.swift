import Foundation
import Shared

final class GarminStatusSnapshotService {
    typealias ItemInfoProvider = (MagicItem) -> MagicItem.Info?
    typealias StateProvider = (MagicItem, Server) async throws -> ControlEntityProvider.State?

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
        itemInfo: ItemInfoProvider
    ) async throws -> GarminStatusSnapshot {
        let updatedAt = dateProvider().timeIntervalSince1970
        var values: [GarminStatusValue] = []
        let statusItems = config.statusItems.prefix(GarminConfig.maxStatusItems)

        for item in statusItems where GarminSupportedDomains.supportsStatus(item) {
            let info = itemInfo(item)
            let label = item.name(info: info ?? .fallback(for: item))
            let iconName = item.customization?.icon ?? info?.iconName

            guard let server = Current.servers.server(forServerIdentifier: item.serverId) else {
                values.append(statusValue(for: item, label: label, value: "Unavailable", iconName: iconName))
                continue
            }

            let state = try await stateProvider(item, server)
            values.append(statusValue(for: item, label: label, value: displayValue(for: state), iconName: iconName))
        }

        return GarminStatusSnapshot(statuses: values, updatedAt: updatedAt)
    }

    func snapshotWithCacheFallback(
        config: GarminConfig,
        itemInfo: ItemInfoProvider
    ) async -> Result<GarminStatusSnapshot, GarminBridgeError> {
        let statusIds = Self.statusIds(for: config)
        do {
            let snapshot = try await snapshot(config: config, itemInfo: itemInfo)
            do {
                try GarminStatusSnapshotCache.save(snapshot, statusIds: statusIds)
            } catch {
                Current.Log.error("Failed to cache Garmin status snapshot: \(error)")
            }
            GarminDiagnostics.record(.statusSnapshot, status: .success, metadata: [
                "cache_status": "fresh",
                "status_count": snapshot.statuses.count,
            ])
            return .success(snapshot)
        } catch {
            if let cachedSnapshot = try? GarminStatusSnapshotCache.cachedSnapshot(statusIds: statusIds) {
                GarminDiagnostics.record(.statusSnapshot, status: .success, metadata: [
                    "cache_status": "fallback",
                    "status_count": cachedSnapshot.statuses.count,
                ])
                return .success(cachedSnapshot)
            }
            let bridgeError = (error as? GarminBridgeError) ?? .homeAssistantUnavailable
            GarminDiagnostics.record(.statusSnapshot, status: .failed, metadata: [
                "cache_status": "unavailable",
                "error_code": bridgeError.rawValue,
                "status_count": statusIds.count,
            ])
            return .failure(bridgeError)
        }
    }

    static func statusIds(for config: GarminConfig) -> [String] {
        config.statusItems
            .prefix(GarminConfig.maxStatusItems)
            .filter { GarminSupportedDomains.supportsStatus($0) }
            .map { GarminConfig.opaqueStatusId(for: $0) }
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
            id: GarminConfig.opaqueStatusId(for: item),
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
}

private extension MagicItem.Info {
    static func fallback(for item: MagicItem) -> MagicItem.Info {
        .init(id: item.type.rawValue, name: item.displayText ?? item.type.rawValue, iconName: "")
    }
}
