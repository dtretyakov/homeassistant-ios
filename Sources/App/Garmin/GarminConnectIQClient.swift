import Combine
import Foundation
import Shared

enum GarminFeature {
    static let connectIQURLScheme = "homeassistant-garmin-ciq"

    static var isEnabled: Bool {
        #if GARMIN_CONNECTIQ_ENABLED
        true
        #else
        false
        #endif
    }

    static var supportsStatusItems: Bool { true }

    static func canHandleConnectIQURL(_ url: URL) -> Bool {
        url.scheme == connectIQURLScheme
    }
}

protocol GarminConnectIQClient: AnyObject {
    var state: GarminConnectionState { get }
    var statePublisher: AnyPublisher<GarminConnectionState, Never> { get }
    func setup(commandHandler: @escaping (GarminInboundMessage) -> Void)
    func sendProfile(_ profile: GarminProfile, completion: @escaping (Result<Void, GarminIntegrationError>) -> Void)
    func sendStatusSnapshot(_ snapshot: GarminStatusSnapshot, completion: @escaping (Result<Void, GarminIntegrationError>) -> Void)
    func sendActionResult(_ result: GarminCommandResult, completion: @escaping (Result<Void, GarminIntegrationError>) -> Void)
    func sendConnectionStatus(_ status: GarminConnectionStatus, completion: @escaping (Result<Void, GarminIntegrationError>) -> Void)
    func disconnect()
    func requestDeviceSelection(force: Bool)
    func handleDeviceSelectionResponse(_ url: URL) -> Bool
}

enum GarminConnectionState: Equatable {
    case notConfigured
    case selectingDevice
    case waitingForWatch(deviceName: String?)
    case sdkUnavailable
    case appUnavailable
    case deviceUnavailable
    case ready(deviceName: String?)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isWaitingForWatch: Bool {
        if case .waitingForWatch = self { return true }
        return false
    }
}
