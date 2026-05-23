import Foundation
import Shared

final class GarminConnectIQSDKClient: GarminConnectIQClient {
    private(set) var state: GarminConnectionState = .sdkUnavailable
    private var commandHandler: ((GarminInboundMessage) -> Void)?

    func setup(commandHandler: @escaping (GarminInboundMessage) -> Void) {
        self.commandHandler = commandHandler
        state = .sdkUnavailable
        GarminDiagnostics.record(.sdk, status: .unavailable, metadata: [
            "sdk_state": "sdk_unavailable",
            "connection_state": GarminDiagnostics.connectionState(state),
        ])
    }

    func sendProfile(_ profile: GarminProfile, completion: @escaping (Result<Void, GarminBridgeError>) -> Void) {
        completion(.failure(.sdkUnavailable))
    }

    func sendStatusSnapshot(_ snapshot: GarminStatusSnapshot, completion: @escaping (Result<Void, GarminBridgeError>) -> Void) {
        completion(.failure(.sdkUnavailable))
    }

    func sendActionResult(_ result: GarminCommandResult, completion: @escaping (Result<Void, GarminBridgeError>) -> Void) {
        completion(.failure(.sdkUnavailable))
    }

    func disconnect() {
        commandHandler = nil
        state = .notConfigured
    }
}
