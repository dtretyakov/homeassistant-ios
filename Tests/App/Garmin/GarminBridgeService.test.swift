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

    func sendStatusSnapshot(_ snapshot: GarminStatusSnapshot, completion: @escaping (Result<Void, GarminBridgeError>) -> Void) {
        sentStatusSnapshots.append(snapshot)
        completion(.success(()))
    }

    func sendActionResult(_ result: GarminCommandResult, completion: @escaping (Result<Void, GarminBridgeError>) -> Void) {
        sentResults.append(result)
        completion(.success(()))
    }

    func disconnect() {
        state = .notConfigured
    }
}

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
        #expect(!didExecute)
    }

    @Test func typedExecutorFailureIsPreserved() throws {
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
}
