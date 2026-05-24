import Combine
import Foundation
@testable import HomeAssistant
@testable import Shared
import Testing

@Suite(.serialized)
struct GarminDiagnosticsTests {
    @Test func garminEventTypeHasDisplayText() {
        #expect(ClientEvent.EventType.allCases.contains(.garmin))
        #expect(!ClientEvent.EventType.garmin.displayText.isEmpty)
    }

    @Test func recorderStoresOnlyAllowlistedMetadata() throws {
        try withClientEventStore { store in
            GarminDiagnostics.record(.sync, status: .failed, metadata: [
                "error_code": GarminIntegrationError.sdkUnavailable.rawValue,
                "action_count": 1,
                "status_count": 2,
                "token": "secret",
                "url": "https://example.invalid",
                "entity_id": "light.kitchen",
                "service_data": ["entity_id": "light.kitchen"],
            ])

            let event = try #require(store.events.first)
            let payload = event.jsonPayloadJSONObject()

            #expect(event.type == .garmin)
            #expect(event.text == "sync: failed")
            #expect((payload["event_type"] as? String) == "sync")
            #expect((payload["status"] as? String) == "failed")
            #expect((payload["error_code"] as? String) == GarminIntegrationError.sdkUnavailable.rawValue)
            #expect((payload["action_count"] as? Int) == 1)
            #expect((payload["status_count"] as? Int) == 2)
            #expect(payload["token"] == nil)
            #expect(payload["url"] == nil)
            #expect(payload["entity_id"] == nil)
            #expect(payload["service_data"] == nil)
        }
    }

    @Test func viewModelFiltersAndCopiesGarminEvents() throws {
        try withClientEventStore { store in
            store.events = [
                ClientEvent(
                    text: "sync: success https://example.invalid token=rawtoken",
                    type: .garmin,
                    payload: [
                        "status": "success",
                        "token": "secret",
                        "nested": ["entity_id": "light.kitchen"],
                    ]
                ),
                ClientEvent(text: "settings changed", type: .settings, payload: ["status": "success"]),
            ]

            let viewModel = ClientEventsLogViewModel(initialTypeFilter: .garmin)
            viewModel.loadEvents()
            let copyText = viewModel.copyFilteredEventsText()

            #expect(viewModel.filteredEvents.map(\.type) == [.garmin])
            #expect(viewModel.visibleEvents.map(\.type) == [.garmin])
            #expect(copyText.contains("type=garmin"))
            #expect(copyText.contains("status=sync: success"))
            #expect(copyText.contains("[redacted]"))
            #expect(!copyText.contains("secret"))
            #expect(!copyText.contains("rawtoken"))
            #expect(!copyText.contains("https://example.invalid"))
            #expect(!copyText.contains("light.kitchen"))
            #expect(!copyText.contains("settings changed"))
        }
    }

    @Test func integrationActionFailureWritesSanitizedDiagnostic() throws {
        try withClientEventStore { store in
            let client = DiagnosticsGarminClient()
            let service = GarminIntegrationService(client: client)
            let message = GarminInboundMessage(
                type: .callAction,
                actionId: "garmin_action_missing",
                correlationId: "c1"
            )

            service.handle(message, config: GarminConfig()) { _ in }

            let events = store.events.filter { $0.type == .garmin }
            let matchingActionEvent = events.first(where: { event in
                let payload = event.jsonPayloadJSONObject()
                let isActionFailure = event.text == "action_execution: failed"
                let hasCorrelationId = (payload["correlation_id"] as? String) == "c1"
                return isActionFailure && hasCorrelationId
            })
            let actionEvent = try #require(matchingActionEvent)
            let payload = actionEvent.jsonPayloadJSONObject()
            let payloadText = String(describing: payload)
            let correlationId = payload["correlation_id"] as? String

            #expect(payloadText.contains(GarminIntegrationError.missingAction.rawValue))
            #expect(correlationId == "c1")
            #expect(!payloadText.contains("garmin_action_missing"))
            #expect(!payloadText.contains("entity_id"))
            #expect(!payloadText.contains("service_data"))
        }
    }

    @Test func garminVisibleEventsAreCappedAtDiagnosticsLimit() throws {
        try withClientEventStore { store in
            store.events = (0...ClientEventsLogViewModel.garminDiagnosticsLimit).map { index in
                ClientEvent(text: "sync: \(index)", type: .garmin)
            }

            let viewModel = ClientEventsLogViewModel(initialTypeFilter: .garmin)
            viewModel.loadEvents()

            #expect(viewModel.filteredEvents.count == ClientEventsLogViewModel.garminDiagnosticsLimit + 1)
            #expect(viewModel.visibleEvents.count == ClientEventsLogViewModel.garminDiagnosticsLimit)
        }
    }

    @Test func statusObserverSendFailureWritesDiagnostic() async throws {
        try GarminStatusSnapshotCache.clear()
        try await withClientEventStore { store in
            let item = MagicItem(id: "sensor.temperature", serverId: "server-1", type: .entity, displayText: "Temperature")
            let snapshot = GarminStatusSnapshot(
                statuses: [
                    .init(id: GarminConfig.opaqueStatusId(for: item), label: "Temperature", value: "20 C"),
                ],
                updatedAt: 1
            )
            let client = DiagnosticsGarminClient(statusSendResult: .failure(.watchUnavailable))
            let service = GarminStatusObservationService(
                client: client,
                configProvider: { GarminConfig(statusItems: [item]) },
                snapshotProvider: { _, completion in completion(.success(snapshot)) },
                subscriptionProvider: { _, _, _ in nil },
                isAppActive: { true },
                debounceInterval: 0,
                observeDatabase: false
            )
            defer { service.stop() }

            service.start()

            try await waitUntil {
                store.events.contains {
                    $0.type == .garmin && $0.text == "status_send: failed"
                }
            }
            let event = try #require(store.events.first {
                $0.type == .garmin && $0.text == "status_send: failed"
            })
            let payload = event.jsonPayloadJSONObject()
            #expect((payload["error_code"] as? String) == GarminIntegrationError.watchUnavailable.rawValue)
            #expect((payload["status_count"] as? Int) == 1)
        }
    }

    private func withClientEventStore(
        _ body: (DiagnosticsClientEventStore) throws -> Void
    ) throws {
        let previousStore = Current.clientEventStore
        let store = DiagnosticsClientEventStore()
        Current.clientEventStore = store
        defer { Current.clientEventStore = previousStore }

        try body(store)
    }

    private func withClientEventStore(
        _ body: (DiagnosticsClientEventStore) async throws -> Void
    ) async throws {
        let previousStore = Current.clientEventStore
        let store = DiagnosticsClientEventStore()
        Current.clientEventStore = store
        defer { Current.clientEventStore = previousStore }

        try await body(store)
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

private final class DiagnosticsClientEventStore: ClientEventStoreProtocol {
    var events: [ClientEvent] = []

    func addEvent(_ event: ClientEvent) {
        events.append(event)
    }

    func getEvents() -> [ClientEvent] {
        events
    }

    func clearAllEvents() {
        events.removeAll()
    }
}

private final class DiagnosticsGarminClient: GarminConnectIQClient {
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
    var statusSendResult: Result<Void, GarminIntegrationError>

    init(statusSendResult: Result<Void, GarminIntegrationError> = .success(())) {
        self.statusSendResult = statusSendResult
    }

    func setup(commandHandler: @escaping (GarminInboundMessage) -> Void) {}

    func sendProfile(_ profile: GarminProfile, completion: @escaping (Result<Void, GarminIntegrationError>) -> Void) {
        completion(.success(()))
    }

    func sendStatusSnapshot(
        _ snapshot: GarminStatusSnapshot,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
        completion(statusSendResult)
    }

    func sendActionResult(
        _ result: GarminCommandResult,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
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
}
