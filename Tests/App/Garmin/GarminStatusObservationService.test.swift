import Combine
import Foundation
import HAKit
@testable import HomeAssistant
@testable import Shared
import Testing

@Suite(.serialized)
struct GarminStatusObservationServiceTests {
    @Test func startCachesAndSendsInitialSnapshot() async throws {
        try GarminStatusSnapshotCache.clear()
        let item = statusItem("sensor.temperature")
        let snapshot = statusSnapshot(item: item, value: "20 °C", updatedAt: 1)
        let client = RecordingGarminStatusClient()
        let service = makeService(
            client: client,
            configProvider: { GarminConfig(statusItems: [item]) },
            snapshotProvider: { _, completion in completion(.success(snapshot)) }
        )
        defer { service.stop() }

        service.start()

        try await waitUntil { client.sentStatusSnapshots.count == 1 }
        #expect(client.sentStatusSnapshots == [snapshot])
        let cached = try GarminStatusSnapshotCache.cachedSnapshot(statusIds: [GarminConfig.opaqueStatusId(for: item)])
        #expect(cached == snapshot)
    }

    @Test func equivalentSnapshotsAreDeduplicatedIgnoringUpdatedAt() async throws {
        try GarminStatusSnapshotCache.clear()
        let item = statusItem("sensor.temperature")
        var onStateChange: (() -> Void)?
        var snapshots = [
            statusSnapshot(item: item, value: "20 °C", updatedAt: 1),
            statusSnapshot(item: item, value: "20 °C", updatedAt: 2),
        ]
        let client = RecordingGarminStatusClient()
        let service = makeService(
            client: client,
            configProvider: { GarminConfig(statusItems: [item]) },
            snapshotProvider: { _, completion in completion(.success(snapshots.removeFirst())) },
            subscriptionProvider: { _, stateChange, _ in
                onStateChange = stateChange
                return TestHACancellable()
            },
            debounceInterval: 0
        )
        defer { service.stop() }

        service.start()
        try await waitUntil { client.sentStatusSnapshots.count == 1 }
        onStateChange?()

        try await waitUntil { snapshots.isEmpty }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(client.sentStatusSnapshots.count == 1)
    }

    @Test func sameConfigurationRefreshDoesNotDuplicateEquivalentSnapshotSend() async throws {
        try GarminStatusSnapshotCache.clear()
        let item = statusItem("sensor.temperature")
        var refreshCount = 0
        let client = RecordingGarminStatusClient()
        let service = makeService(
            client: client,
            configProvider: { GarminConfig(statusItems: [item]) },
            snapshotProvider: { _, completion in
                refreshCount += 1
                completion(.success(statusSnapshot(item: item, value: "20 °C", updatedAt: TimeInterval(refreshCount))))
            }
        )
        defer { service.stop() }

        service.start()
        try await waitUntil { client.sentStatusSnapshots.count == 1 }
        service.refreshConfiguration()

        try await waitUntil { refreshCount == 2 }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(client.sentStatusSnapshots.count == 1)
    }

    @Test func notReadyGarminClientCachesSnapshotWithoutSending() async throws {
        try GarminStatusSnapshotCache.clear()
        let item = statusItem("sensor.temperature")
        let snapshot = statusSnapshot(item: item, value: "20 °C")
        let client = RecordingGarminStatusClient()
        client.state = .deviceUnavailable
        let service = makeService(
            client: client,
            configProvider: { GarminConfig(statusItems: [item]) },
            snapshotProvider: { _, completion in completion(.success(snapshot)) }
        )
        defer { service.stop() }

        service.start()

        try await waitUntil {
            (try? GarminStatusSnapshotCache.cachedSnapshot(
                statusIds: [GarminConfig.opaqueStatusId(for: item)]
            )) == snapshot
        }
        #expect(client.sentStatusSnapshots.isEmpty)
    }

    @Test func stateBurstsAreDebouncedAndSendLatestSnapshot() async throws {
        try GarminStatusSnapshotCache.clear()
        let item = statusItem("sensor.temperature")
        var onStateChange: (() -> Void)?
        var currentValue = "20 °C"
        var refreshCount = 0
        let client = RecordingGarminStatusClient()
        let service = makeService(
            client: client,
            configProvider: { GarminConfig(statusItems: [item]) },
            snapshotProvider: { _, completion in
                refreshCount += 1
                completion(.success(statusSnapshot(item: item, value: currentValue, updatedAt: TimeInterval(refreshCount))))
            },
            subscriptionProvider: { _, stateChange, _ in
                onStateChange = stateChange
                return TestHACancellable()
            },
            debounceInterval: 0.05
        )
        defer { service.stop() }

        service.start()
        try await waitUntil { client.sentStatusSnapshots.count == 1 }

        currentValue = "21 °C"
        onStateChange?()
        currentValue = "22 °C"
        onStateChange?()
        currentValue = "23 °C"
        onStateChange?()

        try await waitUntil { client.sentStatusSnapshots.count == 2 }
        #expect(client.sentStatusSnapshots.map { $0.statuses.first?.value } == ["20 °C", "23 °C"])
    }

    @Test func sendPipelineIsSingleFlightAndLatestWins() async throws {
        try GarminStatusSnapshotCache.clear()
        let item = statusItem("sensor.temperature")
        var onStateChange: (() -> Void)?
        var currentValue = "20 °C"
        var refreshCount = 0
        let client = RecordingGarminStatusClient(automaticallyCompleteSends: false)
        let service = makeService(
            client: client,
            configProvider: { GarminConfig(statusItems: [item]) },
            snapshotProvider: { _, completion in
                refreshCount += 1
                completion(.success(statusSnapshot(item: item, value: currentValue, updatedAt: TimeInterval(refreshCount))))
            },
            subscriptionProvider: { _, stateChange, _ in
                onStateChange = stateChange
                return TestHACancellable()
            },
            debounceInterval: 0
        )
        defer { service.stop() }

        service.start()
        try await waitUntil { client.sentStatusSnapshots.count == 1 }

        currentValue = "21 °C"
        onStateChange?()
        currentValue = "22 °C"
        onStateChange?()

        try await waitUntil { refreshCount == 3 }
        #expect(client.sentStatusSnapshots.count == 1)

        client.completeNextSend(.success(()))

        try await waitUntil { client.sentStatusSnapshots.count == 2 }
        #expect(client.sentStatusSnapshots.map { $0.statuses.first?.value } == ["20 °C", "22 °C"])
    }

    @Test func subscriptionFailureTriggersSnapshotFallbackRefresh() async throws {
        try GarminStatusSnapshotCache.clear()
        let item = statusItem("sensor.temperature")
        var onFailure: ((GarminIntegrationError) -> Void)?
        var currentValue = "20 °C"
        let client = RecordingGarminStatusClient()
        let service = makeService(
            client: client,
            configProvider: { GarminConfig(statusItems: [item]) },
            snapshotProvider: { _, completion in
                completion(.success(statusSnapshot(item: item, value: currentValue)))
            },
            subscriptionProvider: { _, _, failure in
                onFailure = failure
                return TestHACancellable()
            },
            debounceInterval: 0
        )
        defer { service.stop() }

        service.start()
        try await waitUntil { client.sentStatusSnapshots.count == 1 }

        currentValue = "21 °C"
        onFailure?(.homeAssistantUnavailable)

        try await waitUntil { client.sentStatusSnapshots.count == 2 }
        #expect(client.sentStatusSnapshots.map { $0.statuses.first?.value } == ["20 °C", "21 °C"])
    }

    @Test func configurationRefreshCancelsOldSubscriptionAndObservesNewStatuses() async throws {
        try GarminStatusSnapshotCache.clear()
        let first = statusItem("sensor.temperature")
        let second = statusItem("binary_sensor.front_door")
        var config = GarminConfig(statusItems: [first])
        var subscriptions: [TestHACancellable] = []
        let client = RecordingGarminStatusClient()
        let service = makeService(
            client: client,
            configProvider: { config },
            snapshotProvider: { config, completion in
                let item = config.statusItems[0]
                completion(.success(statusSnapshot(item: item, value: item.id)))
            },
            subscriptionProvider: { _, _, _ in
                let cancellable = TestHACancellable()
                subscriptions.append(cancellable)
                return cancellable
            },
            debounceInterval: 0
        )
        defer { service.stop() }

        service.start()
        try await waitUntil { subscriptions.count == 1 && client.sentStatusSnapshots.count == 1 }

        config = GarminConfig(statusItems: [second])
        service.refreshConfiguration()

        try await waitUntil { subscriptions.count == 2 && client.sentStatusSnapshots.count == 2 }
        #expect(subscriptions[0].isCancelled)
        #expect(client.sentStatusSnapshots.map { $0.statuses.first?.id } == [
            GarminConfig.opaqueStatusId(for: first),
            GarminConfig.opaqueStatusId(for: second),
        ])
    }

    @Test func observedEntityTrackerIgnoresInitialAndUnrelatedStateChanges() throws {
        let tracker = GarminObservedEntityStateTracker(entityIds: ["sensor.temperature"])

        #expect(!tracker.shouldRefresh(states: [
            try entity("sensor.temperature", state: "20"),
            try entity("switch.unrelated", state: "off"),
        ]))
        #expect(!tracker.shouldRefresh(states: [
            try entity("sensor.temperature", state: "20"),
            try entity("switch.unrelated", state: "on"),
        ]))
        #expect(tracker.shouldRefresh(states: [
            try entity("sensor.temperature", state: "21"),
            try entity("switch.unrelated", state: "on"),
        ]))
        #expect(tracker.shouldRefresh(states: [
            try entity("sensor.temperature", state: "21", attributes: ["unit_of_measurement": "°C"]),
            try entity("switch.unrelated", state: "on"),
        ]))
        #expect(!tracker.shouldRefresh(states: [
            try entity("sensor.temperature", state: "21", attributes: ["unit_of_measurement": "°C"]),
            try entity("switch.unrelated", state: "off"),
        ]))
    }

    private func makeService(
        client: GarminConnectIQClient,
        configProvider: @escaping GarminStatusObservationService.ConfigProvider,
        snapshotProvider: @escaping GarminStatusObservationService.SnapshotProvider,
        subscriptionProvider: @escaping GarminStatusObservationService.SubscriptionProvider = { _, _, _ in
            TestHACancellable()
        },
        debounceInterval: TimeInterval = 0
    ) -> GarminStatusObservationService {
        GarminStatusObservationService(
            client: client,
            configProvider: configProvider,
            snapshotProvider: snapshotProvider,
            subscriptionProvider: subscriptionProvider,
            isAppActive: { true },
            debounceInterval: debounceInterval,
            observeDatabase: false
        )
    }

    private func statusItem(_ entityId: String) -> MagicItem {
        MagicItem(id: entityId, serverId: "server-1", type: .entity, displayText: entityId)
    }

    private func statusSnapshot(
        item: MagicItem,
        value: String,
        updatedAt: TimeInterval = 1_710_000_000
    ) -> GarminStatusSnapshot {
        GarminStatusSnapshot(
            statuses: [
                .init(
                    id: GarminConfig.opaqueStatusId(for: item),
                    label: item.displayText ?? item.id,
                    value: value
                ),
            ],
            updatedAt: updatedAt
        )
    }

    private func entity(
        _ entityId: String,
        state: String,
        attributes: [String: Any] = [:]
    ) throws -> HAEntity {
        try HAEntity(
            entityId: entityId,
            state: state,
            lastChanged: Date(),
            lastUpdated: Date(),
            attributes: attributes,
            context: .init(id: "context", userId: "user", parentId: nil)
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping () -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition() {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private final class RecordingGarminStatusClient: GarminConnectIQClient {
    var state: GarminConnectionState = .ready(deviceName: "Test Garmin") {
        didSet {
            guard state != oldValue else { return }
            stateSubject.send(state)
        }
    }
    var statePublisher: AnyPublisher<GarminConnectionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }
    private let stateSubject = CurrentValueSubject<GarminConnectionState, Never>(.ready(deviceName: "Test Garmin"))
    var sentProfiles: [GarminProfile] = []
    var sentStatusSnapshots: [GarminStatusSnapshot] = []
    var sentResults: [GarminCommandResult] = []

    private let automaticallyCompleteSends: Bool
    private var sendCompletions: [(Swift.Result<Void, GarminIntegrationError>) -> Void] = []

    init(automaticallyCompleteSends: Bool = true) {
        self.automaticallyCompleteSends = automaticallyCompleteSends
    }

    func setup(commandHandler: @escaping (GarminInboundMessage) -> Void) {}

    func sendProfile(_ profile: GarminProfile, completion: @escaping (Result<Void, GarminIntegrationError>) -> Void) {
        sentProfiles.append(profile)
        completion(.success(()))
    }

    func sendStatusSnapshot(
        _ snapshot: GarminStatusSnapshot,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
        sentStatusSnapshots.append(snapshot)
        if automaticallyCompleteSends {
            completion(.success(()))
        } else {
            sendCompletions.append(completion)
        }
    }

    func sendActionResult(
        _ result: GarminCommandResult,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
        sentResults.append(result)
        completion(.success(()))
    }

    func sendConnectionStatus(
        _ status: GarminConnectionStatus,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
        completion(.success(()))
    }

    func disconnect() {
        state = .notConfigured
    }

    func requestDeviceSelection(force: Bool) {}

    func handleDeviceSelectionResponse(_ url: URL) -> Bool {
        false
    }

    func completeNextSend(_ result: Swift.Result<Void, GarminIntegrationError>) {
        guard !sendCompletions.isEmpty else {
            Issue.record("Expected pending Garmin send completion")
            return
        }
        sendCompletions.removeFirst()(result)
    }
}

private final class TestHACancellable: HACancellable {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}
