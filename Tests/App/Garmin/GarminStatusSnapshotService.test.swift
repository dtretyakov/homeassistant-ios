import Foundation
import HAKit
@testable import HomeAssistant
@testable import Shared
import Testing

@Suite(.serialized)
struct GarminStatusSnapshotServiceTests {
    @Test func snapshotBuildsDisplayReadyValuesInConfiguredOrder() async throws {
        try GarminStatusSnapshotCache.clear()
        try await withServer(identifier: "server-1") {
            let fixedDate = Date(timeIntervalSince1970: 1_710_000_000)
            let first = MagicItem(id: "sensor.temperature", serverId: "server-1", type: .entity, displayText: "Temp")
            let second = MagicItem(
                id: "binary_sensor.front_door",
                serverId: "server-1",
                type: .entity,
                displayText: "Door"
            )
            let service = GarminStatusSnapshotService(
                stateProvider: { item, _ in
                    if item.id == "sensor.temperature" {
                        return .init(value: "22.4", unitOfMeasurement: "°C", domainState: nil)
                    }
                    return .init(value: "Open", unitOfMeasurement: nil, domainState: .on)
                },
                dateProvider: { fixedDate }
            )

            let snapshot = try await service.snapshot(
                config: config(statusItems: [first, second]),
                itemInfo: { _ in nil }
            )

            #expect(snapshot.updatedAt == 1_710_000_000)
            #expect(snapshot.statuses.map(\.id) == [
                GarminConfig.opaqueItemId(for: first),
                GarminConfig.opaqueItemId(for: second),
            ])
            #expect(snapshot.statuses.map(\.label) == ["Temp", "Door"])
            #expect(snapshot.statuses.map(\.value) == ["22.4 °C", "Open"])
        }
    }

    @Test func snapshotUsesProductionStateFormattingPath() async throws {
        try GarminStatusSnapshotCache.clear()
        try await withServer(identifier: "server-1") {
            let server = try #require(Current.servers.server(forServerIdentifier: "server-1"))
            let api = HomeAssistantAPI(server: server)
            let connection = HAMockConnection()
            api.connection = connection
            Current.setCachedApi(api, for: server.identifier)

            let item = MagicItem(id: "sensor.temperature", serverId: "server-1", type: .entity, displayText: "Temp")
            let service = GarminStatusSnapshotService(dateProvider: {
                Date(timeIntervalSince1970: 1_710_000_010)
            })

            async let snapshotTask = service.snapshot(
                config: config(statusItems: [item]),
                itemInfo: { _ in nil }
            )
            for _ in 0..<100 where connection.pendingRequests.isEmpty {
                try await Task.sleep(nanoseconds: 1_000_000)
            }

            let pendingRequest = try #require(connection.pendingRequests.first)
            #expect(pendingRequest.request.type == .rest(.get, "states/sensor.temperature"))
            pendingRequest.completion(.success(.dictionary([
                "entity_id": "sensor.temperature",
                "state": "22.456",
                "attributes": [
                    "friendly_name": "Temperature",
                    "unit_of_measurement": "°C",
                ],
                "last_changed": "2026-05-18T10:00:00Z",
                "last_updated": "2026-05-18T10:00:00Z",
                "context": [
                    "id": "context-id",
                ],
            ])))
            let result = try await snapshotTask

            #expect(result.updatedAt == 1_710_000_010)
            #expect(result.statuses.first?.id == GarminConfig.opaqueItemId(for: item))
            #expect(result.statuses.first?.value == "22.456 °C")
        }
    }

    @Test func snapshotLimitsItemsAndHandlesMissingServer() async throws {
        try GarminStatusSnapshotCache.clear()
        let items = (0 ... GarminConfig.maxStatusItems).map { index in
            MagicItem(
                id: "sensor.value_\(index)",
                serverId: "missing-server",
                type: .entity,
                displayText: "Value \(index)"
            )
        }
        let service = GarminStatusSnapshotService(
            stateProvider: { _, _ in
                Issue.record("Missing server should not call state provider")
                return nil
            },
            dateProvider: { Date(timeIntervalSince1970: 1_710_000_001) }
        )

        let snapshot = try await service.snapshot(config: config(statusItems: items), itemInfo: { _ in nil })

        #expect(snapshot.statuses.count == GarminConfig.maxStatusItems)
        #expect(snapshot.statuses.allSatisfy { $0.value == "Unavailable" })
    }

    @Test func snapshotWithCacheFallbackSavesFreshSnapshot() async throws {
        try GarminStatusSnapshotCache.clear()
        try await withServer(identifier: "server-1") {
            let item = MagicItem(id: "sensor.temperature", serverId: "server-1", type: .entity, displayText: "Temp")
            let service = GarminStatusSnapshotService(
                stateProvider: { _, _ in .init(value: "21", unitOfMeasurement: "°C", domainState: nil) },
                dateProvider: { Date(timeIntervalSince1970: 1_710_000_002) }
            )

            let result = await service.snapshotWithCacheFallback(
                config: config(statusItems: [item]),
                itemInfo: { _ in nil }
            )

            let snapshot = try result.get()
            let statusIds = GarminStatusSnapshotService.statusIds(for: config(statusItems: [item]))
            let maybeCachedSnapshot = try GarminStatusSnapshotCache.cachedSnapshot(statusIds: statusIds)
            let cachedSnapshot = try #require(maybeCachedSnapshot)
            #expect(snapshot == cachedSnapshot)
            #expect(cachedSnapshot.statuses.first?.value == "21 °C")
        }
    }

    @Test func snapshotWithCacheFallbackReturnsCachedSnapshotWhenFreshFails() async throws {
        try GarminStatusSnapshotCache.clear()

        try await withServer(identifier: "server-1") {
            let item = MagicItem(id: "sensor.temperature", serverId: "server-1", type: .entity, displayText: "Temp")
            let statusIds = GarminStatusSnapshotService.statusIds(for: config(statusItems: [item]))
            let statusId = try #require(statusIds.first)
            let cachedSnapshot = GarminStatusSnapshot(
                statuses: [.init(id: statusId, label: "Temp", value: "20 °C")],
                updatedAt: 1_710_000_003
            )
            try GarminStatusSnapshotCache.save(
                cachedSnapshot,
                statusIds: statusIds
            )
            let service = GarminStatusSnapshotService(
                stateProvider: { _, _ in throw GarminIntegrationError.homeAssistantUnavailable },
                dateProvider: { Date(timeIntervalSince1970: 1_710_000_004) }
            )

            let result = await service.snapshotWithCacheFallback(
                config: config(statusItems: [item]),
                itemInfo: { _ in nil }
            )

            let snapshot = try result.get()
            #expect(snapshot == cachedSnapshot)
        }
    }

    @Test func snapshotWithCacheFallbackUsesCacheWhenProductionStateRequestFails() async throws {
        try GarminStatusSnapshotCache.clear()

        try await withServer(identifier: "server-1") {
            let server = try #require(Current.servers.server(forServerIdentifier: "server-1"))
            let api = HomeAssistantAPI(server: server)
            let connection = HAMockConnection()
            api.connection = connection
            Current.setCachedApi(api, for: server.identifier)

            let item = MagicItem(id: "sensor.temperature", serverId: "server-1", type: .entity, displayText: "Temp")
            let statusIds = GarminStatusSnapshotService.statusIds(for: config(statusItems: [item]))
            let statusId = try #require(statusIds.first)
            let cachedSnapshot = GarminStatusSnapshot(
                statuses: [.init(id: statusId, label: "Temp", value: "20 °C")],
                updatedAt: 1_710_000_003
            )
            try GarminStatusSnapshotCache.save(cachedSnapshot, statusIds: statusIds)

            let service = GarminStatusSnapshotService()
            let resultTask = Task {
                await service.snapshotWithCacheFallback(
                    config: config(statusItems: [item]),
                    itemInfo: { _ in nil }
                )
            }

            for _ in 0..<100 where connection.pendingRequests.isEmpty {
                try await Task.sleep(nanoseconds: 1_000_000)
            }

            let pendingRequest = try #require(connection.pendingRequests.first)
            pendingRequest.completion(.failure(.internal(debugDescription: "unit-test")))

            let snapshot = try await resultTask.value.get()
            #expect(snapshot == cachedSnapshot)
        }
    }

    @Test func snapshotWithCacheFallbackRejectsMismatchedCachedSnapshot() async throws {
        try GarminStatusSnapshotCache.clear()
        let cachedSnapshot = GarminStatusSnapshot(
            statuses: [.init(id: "garmin_status_cached", label: "Cached", value: "Stale")],
            updatedAt: 1_710_000_003
        )
        try GarminStatusSnapshotCache.save(cachedSnapshot, statusIds: ["garmin_status_old"])

        try await withServer(identifier: "server-1") {
            let item = MagicItem(id: "sensor.temperature", serverId: "server-1", type: .entity, displayText: "Temp")
            let service = GarminStatusSnapshotService(
                stateProvider: { _, _ in throw GarminIntegrationError.homeAssistantUnavailable }
            )

            let result = await service.snapshotWithCacheFallback(
                config: config(statusItems: [item]),
                itemInfo: { _ in nil }
            )

            guard case let .failure(error) = result else {
                Issue.record("Expected mismatched cache to be rejected")
                return
            }
            #expect(error == .homeAssistantUnavailable)
        }
    }

    @Test func snapshotWithCacheFallbackReturnsErrorWhenFreshAndCacheFail() async throws {
        try GarminStatusSnapshotCache.clear()
        try await withServer(identifier: "server-1") {
            let item = MagicItem(id: "sensor.temperature", serverId: "server-1", type: .entity, displayText: "Temp")
            let service = GarminStatusSnapshotService(
                stateProvider: { _, _ in throw GarminIntegrationError.homeAssistantUnavailable }
            )

            let result = await service.snapshotWithCacheFallback(
                config: config(statusItems: [item]),
                itemInfo: { _ in nil }
            )

            guard case let .failure(error) = result else {
                Issue.record("Expected snapshot failure when no fresh or cached snapshot exists")
                return
            }
            #expect(error == .homeAssistantUnavailable)
        }
    }

    @Test func snapshotEncodingDoesNotExposeHomeAssistantInternals() throws {
        let snapshot = GarminStatusSnapshot(
            statuses: [.init(id: "garmin_status_1", label: "Kitchen", value: "On", iconName: "mdi:lightbulb")],
            updatedAt: 1_710_000_005
        )
        let encoded = try String(decoding: JSONEncoder().encode(snapshot), as: UTF8.self)

        #expect(encoded.contains("\"updated_at\""))
        #expect(encoded.contains("\"icon_name\""))
        #expect(!encoded.contains("entity_id"))
        #expect(!encoded.contains("server_id"))
        #expect(!encoded.contains("http://"))
        #expect(!encoded.contains("https://"))
        #expect(!encoded.contains("access_token"))
    }

    private func config(statusItems: [MagicItem]) -> GarminConfig {
        GarminConfig(
            selectedServerId: "server-1",
            serverConfigs: [.init(serverId: "server-1", customSections: [
                .init(
                    id: "custom-1",
                    title: "Quick",
                    items: statusItems.map { GarminCustomSectionItem(item: $0) }
                ),
            ])]
        )
    }

    private func withServer(
        identifier: String,
        _ body: () async throws -> Void
    ) async throws {
        let previousServers = Current.servers
        let previousCachedApis = Current.cachedApis
        defer {
            Current.servers = previousServers
            Current.cachedApis = previousCachedApis
        }

        let servers = FakeServerManager()
        _ = servers.add(identifier: .init(rawValue: identifier), serverInfo: .fake())
        Current.servers = servers
        Current.cachedApis = [:]

        try await body()
    }
}
