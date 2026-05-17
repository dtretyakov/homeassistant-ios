import Foundation
import Shared

enum GarminFeature {
    static var isEnabled: Bool {
        #if GARMIN_CONNECTIQ_ENABLED
        true
        #else
        false
        #endif
    }

    static var supportsStatusItems: Bool { false }
}

protocol GarminConnectIQClient: AnyObject {
    var state: GarminConnectionState { get }
    func setup(commandHandler: @escaping (GarminInboundMessage) -> Void)
    func sendProfile(_ profile: GarminProfile, completion: @escaping (Result<Void, GarminBridgeError>) -> Void)
    func sendStatusSnapshot(_ snapshot: GarminStatusSnapshot, completion: @escaping (Result<Void, GarminBridgeError>) -> Void)
    func sendActionResult(_ result: GarminCommandResult, completion: @escaping (Result<Void, GarminBridgeError>) -> Void)
    func disconnect()
}

enum GarminConnectionState: Equatable {
    case notConfigured
    case sdkUnavailable
    case appUnavailable
    case deviceUnavailable
    case ready(deviceName: String?)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}
