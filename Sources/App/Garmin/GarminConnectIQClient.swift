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
    func sendSectionSnapshot(_ section: GarminOverviewSection, correlationId: String?, completion: @escaping (Result<Void, GarminIntegrationError>) -> Void)
    func sendSectionNotModified(sectionId: String, correlationId: String?, completion: @escaping (Result<Void, GarminIntegrationError>) -> Void)
    func sendValuesDelta(_ values: [GarminOverviewValue], valuesRevision: Int, completion: @escaping (Result<Void, GarminIntegrationError>) -> Void)
    func sendActionResult(_ result: GarminCommandResult, completion: @escaping (Result<Void, GarminIntegrationError>) -> Void)
    func disconnect()
    func requestDeviceSelection(force: Bool)
    func handleDeviceSelectionResponse(_ url: URL) -> Bool
}

extension GarminConnectIQClient {
    func sendSectionSnapshot(
        _ section: GarminOverviewSection,
        correlationId: String?,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
        completion(.success(()))
    }

    func sendSectionNotModified(
        sectionId: String,
        correlationId: String?,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
        completion(.success(()))
    }

    func sendValuesDelta(
        _ values: [GarminOverviewValue],
        valuesRevision: Int,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
        completion(.success(()))
    }
}

struct GarminConnectionDiagnostics: Equatable {
    static let idle = GarminConnectionDiagnostics()

    var event = "idle"
    var inboundBytes = 0
    var outboundBytes = 0
    var inboundType: String?
    var outboundType: String?
    var sdkResult: String?

    var displayText: String {
        var parts = [
            event,
            "in:\(inboundBytes)b",
            "out:\(outboundBytes)b",
        ]
        if let inboundType {
            parts.append("rx:\(inboundType)")
        }
        if let outboundType {
            parts.append("tx:\(outboundType)")
        }
        if let sdkResult {
            parts.append("sdk:\(sdkResult)")
        }
        return parts.joined(separator: " ")
    }
}

protocol GarminConnectionDiagnosticsProviding: AnyObject {
    var connectionDiagnostics: GarminConnectionDiagnostics { get }
    var connectionDiagnosticsPublisher: AnyPublisher<GarminConnectionDiagnostics, Never> { get }
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
