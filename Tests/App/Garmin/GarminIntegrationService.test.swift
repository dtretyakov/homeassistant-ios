import Combine
import HAKit
@testable import HomeAssistant
import PromiseKit
@testable import Shared
import Testing

final class FakeGarminConnectIQClient: GarminConnectIQClient {
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
    var sentResults: [GarminCommandResult] = []
    var sentConnectionStatuses: [GarminConnectionStatus] = []
    var sentProfiles: [GarminProfile] = []
    var sentStatusSnapshots: [GarminStatusSnapshot] = []
    var didRequestDeviceSelection = false
    private var commandHandler: ((GarminInboundMessage) -> Void)?

    func setup(commandHandler: @escaping (GarminInboundMessage) -> Void) {
        self.commandHandler = commandHandler
    }

    func sendProfile(_ profile: GarminProfile, completion: @escaping (Swift.Result<Void, GarminIntegrationError>) -> Void) {
        sentProfiles.append(profile)
        completion(.success(()))
    }

    func sendStatusSnapshot(
        _ snapshot: GarminStatusSnapshot,
        completion: @escaping (Swift.Result<Void, GarminIntegrationError>) -> Void
    ) {
        sentStatusSnapshots.append(snapshot)
        completion(.success(()))
    }

    func sendActionResult(
        _ result: GarminCommandResult,
        completion: @escaping (Swift.Result<Void, GarminIntegrationError>) -> Void
    ) {
        sentResults.append(result)
        completion(.success(()))
    }

    func sendConnectionStatus(
        _ status: GarminConnectionStatus,
        completion: @escaping (Swift.Result<Void, GarminIntegrationError>) -> Void
    ) {
        sentConnectionStatuses.append(status)
        completion(.success(()))
    }

    func disconnect() {
        state = .notConfigured
    }

    func requestDeviceSelection(force: Bool) {
        didRequestDeviceSelection = true
        state = .selectingDevice
    }

    func handleDeviceSelectionResponse(_ url: URL) -> Bool {
        false
    }
}

private final class GarminFakeWebhookManager: WebhookManager {
    var sendRequestHandler: ((WebhookResponseIdentifier, Server, WebhookRequest, Resolver<Void>) -> Void)?

    override func send(
        identifier: WebhookResponseIdentifier = .unhandled,
        server: Server,
        request: WebhookRequest
    ) -> Promise<Void> {
        let (promise, seal) = Promise<Void>.pending()
        sendRequestHandler?(identifier, server, request, seal)
        return promise
    }
}

@Suite(.serialized)
struct GarminIntegrationServiceTests {
    @Test func pingSendsConnectionStatusWithoutConfig() throws {
        let client = FakeGarminConnectIQClient()
        let service = GarminIntegrationService(client: client)
        service.setup { nil }

        service.handle(GarminInboundMessage(type: .ping, correlationId: "h1"))

        #expect(client.sentConnectionStatuses == [
            GarminConnectionStatus(correlationId: "h1", state: .success),
        ])
        #expect(client.sentResults.isEmpty)
    }

    @Test func unsupportedPingProtocolSendsConnectionStatusError() throws {
        let client = FakeGarminConnectIQClient()
        let service = GarminIntegrationService(client: client)
        service.setup { nil }

        service.handle(GarminInboundMessage(version: 999, type: .ping, correlationId: "h1"))

        #expect(client.sentConnectionStatuses == [
            GarminConnectionStatus(correlationId: "h1", state: .failed, error: .unsupportedProtocol),
        ])
        #expect(client.sentResults.isEmpty)
    }

    @Test func sdkClientRejectsOversizedProfileBeforeTransportSend() throws {
        let client = GarminConnectIQSDKClient()
        let oversizedLabel = String(repeating: "A", count: GarminPayloadLimits.outboundMessageBytes)
        let profile = GarminProfile(actions: [
            .init(id: "garmin_action_1", label: oversizedLabel),
        ])
        var sendResult: Swift.Result<Void, GarminIntegrationError>?

        client.sendProfile(profile) { result in
            sendResult = result
        }

        guard case let .failure(error) = sendResult else {
            Issue.record("Expected oversized payload to fail")
            return
        }
        #expect(error == .payloadTooLarge)
    }

    @Test func syncDoesNotRequestDeviceSelectionWhenNotConfigured() throws {
        let client = FakeGarminConnectIQClient()
        client.state = .notConfigured
        let service = GarminIntegrationService(client: client)
        var syncResult: Swift.Result<Void, GarminIntegrationError>?

        service.sync(config: GarminConfig(), itemInfo: { _ in nil }) { result in
            syncResult = result
        }

        guard case let .failure(error) = syncResult else {
            Issue.record("Expected sync to fail until Garmin device is selected")
            return
        }
        #expect(error == .watchUnavailable)
        #expect(!client.didRequestDeviceSelection)
    }

    @Test func connectionCheckRequestsDeviceSelection() throws {
        let client = FakeGarminConnectIQClient()
        let service = GarminIntegrationService(client: client)

        service.requestDeviceSelection(force: true)

        #expect(client.didRequestDeviceSelection)
    }

    @Test func connectIQURLFilterRejectsHomeAssistantDeepLinks() throws {
        #expect(GarminFeature.canHandleConnectIQURL(URL(string: "homeassistant-garmin-ciq://device-select-resp")!))
        #expect(!GarminFeature.canHandleConnectIQURL(URL(string: "homeassistant://perform_action")!))
        #expect(!GarminFeature.canHandleConnectIQURL(URL(string: "homeassistant-dev://auth-callback")!))
    }

    @Test func unsupportedProtocolFails() throws {
        let client = FakeGarminConnectIQClient()
        let service = GarminIntegrationService(client: client)
        let message = GarminInboundMessage(version: 999, type: .callAction, correlationId: "c1")
        var handledResult: GarminCommandResult?

        service.handle(message, config: GarminConfig()) { result in
            handledResult = result
        }

        #expect(handledResult?.state == .failed)
        #expect(handledResult?.error == .unsupportedProtocol)
    }

    @Test func requestProfileSendsSanitizedProfile() throws {
        let client = FakeGarminConnectIQClient()
        let service = GarminIntegrationService(client: client)
        let item = MagicItem(id: "light.kitchen", serverId: "server-1", type: .entity, displayText: "Kitchen")
        let message = GarminInboundMessage(type: .requestProfile, correlationId: "c1")
        var handledResult: GarminCommandResult?

        service.handle(message, config: GarminConfig(actionItems: [item])) { result in
            handledResult = result
        }

        #expect(handledResult?.state == .success)
        #expect(client.sentProfiles.count == 1)
        #expect(client.sentProfiles.first?.actions.first?.label == "Kitchen")
    }

    @Test func requestStatusWithoutProviderFailsWithoutEmptySnapshot() throws {
        let client = FakeGarminConnectIQClient()
        let service = GarminIntegrationService(client: client)
        let item = MagicItem(id: "sensor.temperature", serverId: "server-1", type: .entity, displayText: "Temperature")
        let message = GarminInboundMessage(type: .requestStatus, correlationId: "c1")
        var handledResult: GarminCommandResult?

        service.handle(message, config: GarminConfig(statusItems: [item])) { result in
            handledResult = result
        }

        #expect(handledResult?.state == .failed)
        #expect(handledResult?.error == .unsupportedStatus)
        #expect(client.sentStatusSnapshots.isEmpty)
    }

    @Test func requestStatusSendsProviderSnapshot() throws {
        let client = FakeGarminConnectIQClient()
        let service = GarminIntegrationService(client: client)
        let snapshot = GarminStatusSnapshot(
            statuses: [.init(id: "garmin_status_1", label: "Temperature", value: "22 °C")],
            updatedAt: 1_710_000_000
        )
        let message = GarminInboundMessage(type: .requestStatus, correlationId: "c1")
        var handledResult: GarminCommandResult?

        service.setup(
            configProvider: { GarminConfig() },
            statusSnapshotProvider: { _, completion in completion(.success(snapshot)) }
        )
        service.handle(message, config: GarminConfig()) { result in
            handledResult = result
        }

        #expect(handledResult?.state == .success)
        #expect(handledResult?.correlationId == "c1")
        #expect(client.sentStatusSnapshots == [snapshot])
    }

    @Test func requestStatusProviderFailureSendsExplicitError() throws {
        let client = FakeGarminConnectIQClient()
        let service = GarminIntegrationService(client: client)
        let message = GarminInboundMessage(type: .requestStatus, correlationId: "c1")
        var handledResult: GarminCommandResult?

        service.setup(
            configProvider: { GarminConfig() },
            statusSnapshotProvider: { _, completion in completion(.failure(.homeAssistantUnavailable)) }
        )
        service.handle(message, config: GarminConfig()) { result in
            handledResult = result
        }

        #expect(handledResult?.state == .failed)
        #expect(handledResult?.error == .homeAssistantUnavailable)
        #expect(handledResult?.correlationId == "c1")
        #expect(client.sentStatusSnapshots.isEmpty)
        #expect(client.sentResults.first?.error == .homeAssistantUnavailable)
    }

    @Test func missingConfigSendsResultForInboundMessage() throws {
        let client = FakeGarminConnectIQClient()
        let service = GarminIntegrationService(client: client)
        service.setup { nil }

        service.handle(GarminInboundMessage(type: .requestProfile, correlationId: "c1"))

        #expect(client.sentResults.count == 1)
        #expect(client.sentResults.first?.correlationId == "c1")
        #expect(client.sentResults.first?.error == .missingConfig)
    }

    @Test func missingActionFailsWithoutExecuting() throws {
        let client = FakeGarminConnectIQClient()
        var didExecute = false
        let service = GarminIntegrationService(client: client) { _, _, completion in
            didExecute = true
            completion(.success(()))
        }
        let message = GarminInboundMessage(type: .callAction, actionId: "garmin_action_missing", correlationId: "c1")
        var handledResult: GarminCommandResult?

        service.handle(message, config: GarminConfig()) { result in
            handledResult = result
        }

        #expect(handledResult?.state == .failed)
        #expect(handledResult?.error == .missingAction)
        #expect(handledResult?.correlationId == "c1")
        #expect(!didExecute)
    }

    @Test func unsupportedActionFailsWithoutExecuting() throws {
        let client = FakeGarminConnectIQClient()
        var didExecute = false
        let item = MagicItem(id: "climate.hallway", serverId: "server-1", type: .entity)
        let config = GarminConfig(actionItems: [item])
        let service = GarminIntegrationService(client: client) { _, _, completion in
            didExecute = true
            completion(.success(()))
        }
        let message = GarminInboundMessage(
            type: .callAction,
            actionId: GarminConfig.opaqueActionId(for: item),
            correlationId: "c1"
        )
        var handledResult: GarminCommandResult?

        service.handle(message, config: config) { result in
            handledResult = result
        }

        #expect(handledResult?.state == .failed)
        #expect(handledResult?.error == .unsupportedAction)
        #expect(handledResult?.correlationId == "c1")
        #expect(!didExecute)
    }

    @Test func typedExecutorFailureIsPreserved() throws {
        try withServer(identifier: "server-1") { _ in
            let client = FakeGarminConnectIQClient()
            let item = MagicItem(id: "light.kitchen", serverId: "server-1", type: .entity)
            let config = GarminConfig(actionItems: [item])
            let service = GarminIntegrationService(client: client) { _, _, completion in
                completion(.failure(.loginRequired))
            }
            let message = GarminInboundMessage(
                type: .callAction,
                actionId: GarminConfig.opaqueActionId(for: item),
                correlationId: "c1"
            )
            var handledResult: GarminCommandResult?

            service.handle(message, config: config) { result in
                handledResult = result
            }

            #expect(handledResult?.state == .failed)
            #expect(handledResult?.error == .loginRequired)
            #expect(handledResult?.correlationId == "c1")
        }
    }

    @Test func missingServerFailsWithoutExecuting() throws {
        try withServer(identifier: "server-1") { _ in
            let client = FakeGarminConnectIQClient()
            var didExecute = false
            let item = MagicItem(id: "light.kitchen", serverId: "missing-server", type: .entity)
            let config = GarminConfig(actionItems: [item])
            let service = GarminIntegrationService(client: client) { _, _, completion in
                didExecute = true
                completion(.success(()))
            }
            let message = GarminInboundMessage(
                type: .callAction,
                actionId: GarminConfig.opaqueActionId(for: item),
                correlationId: "c1"
            )
            var handledResult: GarminCommandResult?

            service.handle(message, config: config) { result in
                handledResult = result
            }

            #expect(handledResult?.state == .failed)
            #expect(handledResult?.error == .missingServer)
            #expect(handledResult?.correlationId == "c1")
            #expect(!didExecute)
        }
    }

    @Test func executorSuccessSendsSuccessWithCorrelationId() throws {
        try withServer(identifier: "server-1") { _ in
            let client = FakeGarminConnectIQClient()
            let item = MagicItem(id: "light.kitchen", serverId: "server-1", type: .entity)
            let config = GarminConfig(actionItems: [item])
            let service = GarminIntegrationService(client: client) { _, _, completion in
                completion(.success(()))
            }
            let message = GarminInboundMessage(
                type: .callAction,
                actionId: GarminConfig.opaqueActionId(for: item),
                correlationId: "c1"
            )
            var handledResult: GarminCommandResult?

            service.handle(message, config: config) { result in
                handledResult = result
            }

            #expect(handledResult?.state == .success)
            #expect(handledResult?.correlationId == "c1")
            #expect(client.sentResults.first?.state == .success)
            #expect(client.sentResults.first?.correlationId == "c1")
        }
    }

    @Test func scriptActionUsesScriptTurnOnWithEntityId() throws {
        try withWebhookCapture { capturedRequests in
            let client = FakeGarminConnectIQClient()
            let item = MagicItem(id: "script.good_night", serverId: "server-1", type: .script)
            let config = GarminConfig(actionItems: [item])
            let service = GarminIntegrationService(client: client)
            let message = GarminInboundMessage(
                type: .callAction,
                actionId: GarminConfig.opaqueActionId(for: item),
                correlationId: "c1"
            )

            service.handle(message, config: config) { _ in }

            let request = try #require(capturedRequests().first)
            let data = try #require(request.data as? [String: Any])
            let serviceData = try #require(data["service_data"] as? [String: Any])
            #expect(request.type == "call_service")
            #expect(data["domain"] as? String == "script")
            #expect(data["service"] as? String == "turn_on")
            #expect(serviceData["entity_id"] as? String == "script.good_night")
        }
    }

    @Test func sceneActionUsesSceneTurnOnWithEntityId() throws {
        try withWebhookCapture { capturedRequests in
            let client = FakeGarminConnectIQClient()
            let item = MagicItem(id: "scene.movie", serverId: "server-1", type: .scene)
            let config = GarminConfig(actionItems: [item])
            let service = GarminIntegrationService(client: client)
            let message = GarminInboundMessage(
                type: .callAction,
                actionId: GarminConfig.opaqueActionId(for: item),
                correlationId: "c1"
            )

            service.handle(message, config: config) { _ in }

            let request = try #require(capturedRequests().first)
            let data = try #require(request.data as? [String: Any])
            let serviceData = try #require(data["service_data"] as? [String: Any])
            #expect(request.type == "call_service")
            #expect(data["domain"] as? String == "scene")
            #expect(data["service"] as? String == "turn_on")
            #expect(serviceData["entity_id"] as? String == "scene.movie")
        }
    }

    @Test func entityActionUsesDomainMainActionPath() throws {
        try withServer(identifier: "server-1") { server in
            let client = FakeGarminConnectIQClient()
            let api = HomeAssistantAPI(server: server)
            let connection = HAMockConnection()
            api.connection = connection
            Current.setCachedApi(api, for: server.identifier)

            let item = MagicItem(id: "light.kitchen", serverId: "server-1", type: .entity)
            let config = GarminConfig(actionItems: [item])
            let service = GarminIntegrationService(client: client)
            let message = GarminInboundMessage(
                type: .callAction,
                actionId: GarminConfig.opaqueActionId(for: item),
                correlationId: "c1"
            )

            service.handle(message, config: config) { _ in }

            let request = try #require(connection.pendingRequests.first?.request)
            #expect(request.type.command == "call_service")
            #expect(request.data["domain"] as? String == "light")
            #expect(request.data["service"] as? String == "toggle")
            #expect((request.data["target"] as? [String: Any])?["entity_id"] as? String == "light.kitchen")
        }
    }

    @Test func coverActionUsesDomainMainActionPath() throws {
        try withServer(identifier: "server-1") { server in
            let client = FakeGarminConnectIQClient()
            let api = HomeAssistantAPI(server: server)
            let connection = HAMockConnection()
            api.connection = connection
            Current.setCachedApi(api, for: server.identifier)

            let item = MagicItem(id: "cover.garage", serverId: "server-1", type: .entity)
            let config = GarminConfig(actionItems: [item])
            let service = GarminIntegrationService(client: client)
            let message = GarminInboundMessage(
                type: .callAction,
                actionId: GarminConfig.opaqueActionId(for: item),
                correlationId: "c1"
            )

            service.handle(message, config: config) { _ in }

            let request = try #require(connection.pendingRequests.first?.request)
            #expect(request.type.command == "call_service")
            #expect(request.data["domain"] as? String == "cover")
            #expect(request.data["service"] as? String == "toggle")
            #expect((request.data["target"] as? [String: Any])?["entity_id"] as? String == "cover.garage")
        }
    }

    @Test func inboundCallActionDoesNotContainConfirmedProtocolField() throws {
        let data = try JSONEncoder().encode(GarminInboundMessage(
            type: .callAction,
            actionId: "garmin_action_1",
            correlationId: "c1"
        ))
        let payload = try #require(String(data: data, encoding: .utf8))

        #expect(!payload.contains("confirmed"))
        #expect(!payload.contains("confirmation_required"))
    }

    @Test func syncSendsSanitizedProfile() throws {
        let client = FakeGarminConnectIQClient()
        let service = GarminIntegrationService(client: client)
        let item = MagicItem(id: "light.kitchen", serverId: "server-1", type: .entity, displayText: "Kitchen")
        var didSync = false

        service.sync(config: GarminConfig(actionItems: [item]), itemInfo: { _ in nil }) { result in
            guard case .success = result else {
                Issue.record("Expected sync success")
                return
            }
            didSync = true
        }

        #expect(didSync)
        #expect(client.sentProfiles.count == 1)
        #expect(client.sentProfiles.first?.actions.first?.label == "Kitchen")
    }

    private func withServer(
        identifier: String,
        _ body: (Server) throws -> Void
    ) throws {
        let previousServers = Current.servers
        let previousCachedApis = Current.cachedApis
        defer {
            Current.servers = previousServers
            Current.cachedApis = previousCachedApis
        }

        let servers = FakeServerManager()
        let server = servers.add(identifier: .init(rawValue: identifier), serverInfo: .fake())
        Current.servers = servers
        Current.cachedApis = [:]

        try body(server)
    }

    private func withWebhookCapture(
        _ body: (() -> [WebhookRequest]) throws -> Void
    ) throws {
        try withServer(identifier: "server-1") { _ in
            let previousWebhooks = Current.webhooks
            let webhooks = GarminFakeWebhookManager()
            var capturedRequests: [WebhookRequest] = []
            webhooks.sendRequestHandler = { _, _, request, resolver in
                capturedRequests.append(request)
                resolver.fulfill(())
            }
            Current.webhooks = webhooks
            defer {
                Current.webhooks = previousWebhooks
            }

            try body({ capturedRequests })
        }
    }
}
