import HAKit
@testable import HomeAssistant
@testable import Shared
import Testing

final class FakeGarminConnectIQClient: GarminConnectIQClient {
    var state: GarminConnectionState = .ready(deviceName: "Test Garmin")
    var sentResults: [GarminCommandResult] = []
    var sentProfiles: [GarminProfile] = []
    var sentStatusSnapshots: [GarminStatusSnapshot] = []
    private var commandHandler: ((GarminInboundMessage) -> Void)?

    func setup(commandHandler: @escaping (GarminInboundMessage) -> Void) {
        self.commandHandler = commandHandler
    }

    func sendProfile(_ profile: GarminProfile, completion: @escaping (Result<Void, GarminBridgeError>) -> Void) {
        sentProfiles.append(profile)
        completion(.success(()))
    }

    func sendStatusSnapshot(
        _ snapshot: GarminStatusSnapshot,
        completion: @escaping (Result<Void, GarminBridgeError>) -> Void
    ) {
        sentStatusSnapshots.append(snapshot)
        completion(.success(()))
    }

    func sendActionResult(
        _ result: GarminCommandResult,
        completion: @escaping (Result<Void, GarminBridgeError>) -> Void
    ) {
        sentResults.append(result)
        completion(.success(()))
    }

    func disconnect() {
        state = .notConfigured
    }
}

@Suite(.serialized)
struct GarminBridgeServiceTests {
    @Test func unsupportedProtocolFails() throws {
        let client = FakeGarminConnectIQClient()
        let service = GarminBridgeService(client: client)
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
        let service = GarminBridgeService(client: client)
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
        let service = GarminBridgeService(client: client)
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
        let service = GarminBridgeService(client: client)
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
        let service = GarminBridgeService(client: client)
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
        let service = GarminBridgeService(client: client)
        service.setup { nil }

        service.handle(GarminInboundMessage(type: .requestProfile, correlationId: "c1"))

        #expect(client.sentResults.count == 1)
        #expect(client.sentResults.first?.correlationId == "c1")
        #expect(client.sentResults.first?.error == .missingConfig)
    }

    @Test func missingActionFailsWithoutExecuting() throws {
        let client = FakeGarminConnectIQClient()
        var didExecute = false
        let service = GarminBridgeService(client: client) { _, _, completion in
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
        let service = GarminBridgeService(client: client) { _, _, completion in
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
        try withServer(identifier: "server-1") {
            let client = FakeGarminConnectIQClient()
            let item = MagicItem(id: "light.kitchen", serverId: "server-1", type: .entity)
            let config = GarminConfig(actionItems: [item])
            let service = GarminBridgeService(client: client) { _, _, completion in
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
        try withServer(identifier: "server-1") {
            let client = FakeGarminConnectIQClient()
            var didExecute = false
            let item = MagicItem(id: "light.kitchen", serverId: "missing-server", type: .entity)
            let config = GarminConfig(actionItems: [item])
            let service = GarminBridgeService(client: client) { _, _, completion in
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
        try withServer(identifier: "server-1") {
            let client = FakeGarminConnectIQClient()
            let item = MagicItem(id: "light.kitchen", serverId: "server-1", type: .entity)
            let config = GarminConfig(actionItems: [item])
            let service = GarminBridgeService(client: client) { _, _, completion in
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
            let service = GarminBridgeService(client: client)
            let message = GarminInboundMessage(
                type: .callAction,
                actionId: GarminConfig.opaqueActionId(for: item),
                correlationId: "c1"
            )

            service.handle(message, config: config) { _ in }

            let request = try #require(capturedRequests().first)
            #expect(request.type == "call_service")
            #expect(request.data["domain"] as? String == "script")
            #expect(request.data["service"] as? String == "turn_on")
            #expect((request.data["service_data"] as? [String: Any])?["entity_id"] as? String == "script.good_night")
        }
    }

    @Test func sceneActionUsesSceneTurnOnWithEntityId() throws {
        try withWebhookCapture { capturedRequests in
            let client = FakeGarminConnectIQClient()
            let item = MagicItem(id: "scene.movie", serverId: "server-1", type: .scene)
            let config = GarminConfig(actionItems: [item])
            let service = GarminBridgeService(client: client)
            let message = GarminInboundMessage(
                type: .callAction,
                actionId: GarminConfig.opaqueActionId(for: item),
                correlationId: "c1"
            )

            service.handle(message, config: config) { _ in }

            let request = try #require(capturedRequests().first)
            #expect(request.type == "call_service")
            #expect(request.data["domain"] as? String == "scene")
            #expect(request.data["service"] as? String == "turn_on")
            #expect((request.data["service_data"] as? [String: Any])?["entity_id"] as? String == "scene.movie")
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
            let service = GarminBridgeService(client: client)
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
            let service = GarminBridgeService(client: client)
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
        let service = GarminBridgeService(client: client)
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
            let webhooks = FakeWebhookManager()
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
