import Combine
import Foundation
import Shared

#if GARMIN_CONNECTIQ_ENABLED
import ConnectIQ
#endif

final class GarminConnectIQSDKClient: NSObject, GarminConnectIQClient {
    static let appIdentifier = "d9e1631c-a8f3-5fbe-9d16-943f96dc4560"

    private(set) var state: GarminConnectionState = .sdkUnavailable {
        didSet {
            guard state != oldValue else { return }
            stateSubject.send(state)
        }
    }
    var statePublisher: AnyPublisher<GarminConnectionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }
    private let stateSubject = CurrentValueSubject<GarminConnectionState, Never>(.sdkUnavailable)
    private var commandHandler: ((GarminInboundMessage) -> Void)?

    #if GARMIN_CONNECTIQ_ENABLED
    private let connectIQ = ConnectIQ.sharedInstance()!
    private var activeDevice: IQDevice?
    private var activeApp: IQApp?
    private var isInitialized = false
    private var hasRequestedDeviceSelection = false
    private var stateBeforeDeviceSelection: GarminConnectionState?
    #endif

    func setup(commandHandler: @escaping (GarminInboundMessage) -> Void) {
        self.commandHandler = commandHandler

        #if GARMIN_CONNECTIQ_ENABLED
        initializeSDKIfNeeded()
        restoreConfiguredAppIfPossible()
        #else
        state = .sdkUnavailable
        GarminDiagnostics.record(.sdk, status: .unavailable, metadata: [
            "sdk_state": "sdk_unavailable",
            "connection_state": GarminDiagnostics.connectionState(state),
        ])
        #endif
    }

    func sendProfile(_ profile: GarminProfile, completion: @escaping (Result<Void, GarminIntegrationError>) -> Void) {
        send(.init(type: .profileSync, profile: profile), completion: completion)
    }

    func sendStatusSnapshot(_ snapshot: GarminStatusSnapshot, completion: @escaping (Result<Void, GarminIntegrationError>) -> Void) {
        send(.init(type: .statusSnapshot, statusSnapshot: snapshot), completion: completion)
    }

    func sendActionResult(
        _ result: GarminCommandResult,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
        send(.init(type: .actionResult, actionResult: result), completion: completion)
    }

    func sendConnectionStatus(
        _ status: GarminConnectionStatus,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
        send(.init(type: .connectionStatus, connectionStatus: status)) { [weak self] result in
            if case .success = result, status.state == .success {
                #if GARMIN_CONNECTIQ_ENABLED
                completion(self?.persistActiveAppIfPossible() ?? .failure(.watchUnavailable))
                #else
                completion(result)
                #endif
                return
            }
            completion(result)
        }
    }

    func disconnect() {
        commandHandler = nil
        state = .notConfigured
        #if GARMIN_CONNECTIQ_ENABLED
        if let activeApp {
            connectIQ.unregister(forAppMessages: activeApp, delegate: self)
        }
        if let activeDevice {
            connectIQ.unregister(forDeviceEvents: activeDevice, delegate: self)
        }
        activeApp = nil
        activeDevice = nil
        #endif
    }

    func requestDeviceSelection(force: Bool) {
        #if GARMIN_CONNECTIQ_ENABLED
        requestDeviceSelectionIfNeeded(force: force)
        #endif
    }

    func handleDeviceSelectionResponse(_ url: URL) -> Bool {
        #if GARMIN_CONNECTIQ_ENABLED
        guard GarminFeature.canHandleConnectIQURL(url) else { return false }
        hasRequestedDeviceSelection = false
        initializeSDKIfNeeded()
        let devices = connectIQ.parseDeviceSelectionResponse(from: url) as? [IQDevice] ?? []
        guard let device = devices.first, let appIdentifier = UUID(uuidString: Self.appIdentifier) else {
            finishDeviceSelectionFailure(sdkState: "device_selection_no_device")
            return false
        }
        stateBeforeDeviceSelection = nil
        register(device: device, appIdentifier: appIdentifier)
        return true
        #else
        return false
        #endif
    }

    private func send(_ message: GarminOutboundMessage, completion: @escaping (Result<Void, GarminIntegrationError>) -> Void) {
        do {
            guard try GarminPayloadCodec.encodedByteCount(message) <= GarminPayloadLimits.outboundMessageBytes else {
                completion(.failure(.payloadTooLarge))
                return
            }
            let payload = try GarminPayloadCodec.encodeOutboundDictionary(message)
            send(payload, completion: completion)
        } catch {
            completion(.failure(.commandFailed))
        }
    }

    private func send(_ payload: [String: Any], completion: @escaping (Result<Void, GarminIntegrationError>) -> Void) {
        #if GARMIN_CONNECTIQ_ENABLED
        guard let activeApp else {
            requestDeviceSelectionIfNeeded(force: false)
            completion(.failure(error(for: state)))
            return
        }
        connectIQ.sendMessage(payload, to: activeApp, progress: nil) { [weak self] result in
            let mappedResult = self?.result(for: result) ?? .failure(.watchUnavailable)
            if case let .failure(error) = mappedResult {
                GarminDiagnostics.record(.sdk, status: .failed, metadata: [
                    "sdk_state": NSStringFromSendMessageResult(result) ?? "unknown",
                    "connection_state": GarminDiagnostics.connectionState(self?.state ?? .notConfigured),
                    "error_code": error.rawValue,
                ])
            }
            completion(mappedResult)
        }
        #else
        completion(.failure(.sdkUnavailable))
        #endif
    }
}

#if GARMIN_CONNECTIQ_ENABLED
extension GarminConnectIQSDKClient: IQDeviceEventDelegate, IQAppMessageDelegate {
    func deviceStatusChanged(_ device: IQDevice!, status: IQDeviceStatus) {
        let nextState = connectionState(for: status, deviceName: device?.friendlyName ?? device?.modelName)
        if !state.isReady || !nextState.isWaitingForWatch {
            state = nextState
        }
        GarminDiagnostics.record(.sdk, status: state.isReady ? .success : .unavailable, metadata: [
            "connection_state": GarminDiagnostics.connectionState(state),
        ])
    }

    func deviceCharacteristicsDiscovered(_ device: IQDevice!) {
        guard let device else { return }
        if !state.isReady {
            state = .waitingForWatch(deviceName: device.friendlyName ?? device.modelName)
        }
        GarminDiagnostics.record(.sdk, status: .skipped, metadata: [
            "connection_state": GarminDiagnostics.connectionState(state),
        ])
    }

    func receivedMessage(_ message: Any!, from app: IQApp!) {
        guard let app else { return }
        guard isExpected(app: app) else {
            GarminDiagnostics.record(.inboundMessage, status: .failed, metadata: [
                "sdk_state": "unexpected_device",
                "connection_state": GarminDiagnostics.connectionState(state),
                "error_code": GarminIntegrationError.watchUnavailable.rawValue,
            ])
            return
        }
        activeApp = app
        activeDevice = app.device
        if !state.isReady {
            state = .waitingForWatch(deviceName: app.device.friendlyName ?? app.device.modelName)
        }

        guard let payload = message as? [String: Any],
              (try? JSONSerialization.data(withJSONObject: payload).count) ?? Int.max <= GarminPayloadLimits.inboundCommandBytes else {
            GarminDiagnostics.record(.inboundMessage, status: .failed, metadata: [
                "error_code": GarminIntegrationError.payloadTooLarge.rawValue,
                "connection_state": GarminDiagnostics.connectionState(state),
            ])
            return
        }

        do {
            commandHandler?(try GarminPayloadCodec.decodeInboundDictionary(payload))
        } catch {
            GarminDiagnostics.record(.inboundMessage, status: .failed, metadata: [
                "error_code": GarminIntegrationError.commandFailed.rawValue,
                "connection_state": GarminDiagnostics.connectionState(state),
            ])
        }
    }
}

private extension GarminConnectIQSDKClient {
    func initializeSDKIfNeeded() {
        guard !isInitialized else { return }
        connectIQ.initialize(withUrlScheme: GarminFeature.connectIQURLScheme, uiOverrideDelegate: nil)
        isInitialized = true
    }

    func restoreConfiguredAppIfPossible() {
        guard
            let config = try? GarminConfig.config(),
            let deviceIdentifier = config.deviceIdentifier,
            let deviceUUID = UUID(uuidString: deviceIdentifier),
            let appUUID = UUID(uuidString: config.appIdentifier ?? Self.appIdentifier)
        else {
            state = .notConfigured
            GarminDiagnostics.record(.sdk, status: .skipped, metadata: [
                "sdk_state": "missing_device",
                "connection_state": GarminDiagnostics.connectionState(state),
            ])
            return
        }

        guard let device = IQDevice(id: deviceUUID, modelName: "Garmin", friendlyName: "Garmin") else {
            state = .notConfigured
            return
        }
        register(device: device, appIdentifier: appUUID)
    }

    func register(device: IQDevice, appIdentifier: UUID) {
        let app = IQApp(uuid: appIdentifier, store: appIdentifier, device: device)
        activeDevice = device
        activeApp = app
        connectIQ.register(forDeviceEvents: device, delegate: self)
        connectIQ.register(forAppMessages: app, delegate: self)
        state = connectionState(for: connectIQ.getDeviceStatus(device), deviceName: device.friendlyName)

        GarminDiagnostics.record(.sdk, status: state.isReady ? .success : .unavailable, metadata: [
            "connection_state": GarminDiagnostics.connectionState(state),
        ])
    }

    func requestDeviceSelectionIfNeeded(force: Bool) {
        guard !hasRequestedDeviceSelection else { return }
        if !force, state != .notConfigured {
            return
        }
        hasRequestedDeviceSelection = true
        stateBeforeDeviceSelection = state
        state = .selectingDevice
        connectIQ.showDeviceSelection()
        GarminDiagnostics.record(.sdk, status: .skipped, metadata: [
            "sdk_state": "device_selection_requested",
            "connection_state": GarminDiagnostics.connectionState(state),
        ])
    }

    func finishDeviceSelectionFailure(sdkState: String) {
        let previousState = stateBeforeDeviceSelection
        stateBeforeDeviceSelection = nil
        state = fallbackStateAfterDeviceSelectionFailure(previousState)
        GarminDiagnostics.record(.sdk, status: .failed, metadata: [
            "sdk_state": sdkState,
            "connection_state": GarminDiagnostics.connectionState(state),
        ])
    }

    func fallbackStateAfterDeviceSelectionFailure(_ previousState: GarminConnectionState?) -> GarminConnectionState {
        switch previousState {
        case .some(.selectingDevice), .none:
            return .notConfigured
        case let .some(state):
            return state
        }
    }

    func connectionState(for status: IQDeviceStatus, deviceName: String?) -> GarminConnectionState {
        switch status {
        case .connected:
            return .waitingForWatch(deviceName: deviceName)
        case .invalidDevice:
            return .notConfigured
        case .bluetoothNotReady, .notFound, .notConnected:
            return .deviceUnavailable
        @unknown default:
            return .deviceUnavailable
        }
    }

    func result(for sendResult: IQSendMessageResult) -> Result<Void, GarminIntegrationError> {
        switch sendResult {
        case .success:
            return .success(())
        case .failure_AppNotFound:
            state = .appUnavailable
            return .failure(.watchUnavailable)
        case .failure_DeviceNotAvailable, .failure_DeviceIsBusy:
            state = .deviceUnavailable
            return .failure(.watchUnavailable)
        case .failure_UnsupportedType, .failure_InsufficientMemory:
            return .failure(.payloadTooLarge)
        case .failure_Timeout, .failure_MaxRetries:
            return .failure(.watchUnavailable)
        case .failure_Unknown,
             .failure_InternalError,
             .failure_PromptNotDisplayed,
             .failure_AppAlreadyRunning:
            return .failure(.commandFailed)
        @unknown default:
            return .failure(.commandFailed)
        }
    }

    func error(for state: GarminConnectionState) -> GarminIntegrationError {
        switch state {
        case .sdkUnavailable:
            return .sdkUnavailable
        case .notConfigured, .selectingDevice, .waitingForWatch, .appUnavailable, .deviceUnavailable:
            return .watchUnavailable
        case .ready:
            return .commandFailed
        }
    }

    func isExpected(app: IQApp) -> Bool {
        guard
            let config = try? GarminConfig.config(),
            let expectedDeviceIdentifier = config.deviceIdentifier
        else {
            return true
        }

        return app.device.uuid.uuidString == expectedDeviceIdentifier
    }

    func persistActiveAppIfPossible() -> Result<Void, GarminIntegrationError> {
        guard let activeApp else { return .failure(.watchUnavailable) }
        let readyState: GarminConnectionState = .ready(deviceName: activeApp.device.friendlyName ?? activeApp.device.modelName)

        do {
            try Current.database().write { db in
                var config = try GarminConfig.fetchOne(db) ?? GarminConfig()
                config.deviceIdentifier = activeApp.device.uuid.uuidString
                config.appIdentifier = activeApp.uuid.uuidString
                config.lastError = nil
                try config.insert(db, onConflict: .replace)
            }
            state = readyState
            GarminDiagnostics.record(.sdk, status: .success, metadata: [
                "sdk_state": "paired",
                "connection_state": GarminDiagnostics.connectionState(state),
            ])
            return .success(())
        } catch {
            GarminDiagnostics.record(.sdk, status: .failed, metadata: [
                "sdk_state": "pair_persist_failed",
                "connection_state": GarminDiagnostics.connectionState(state),
                "error_code": GarminIntegrationError.commandFailed.rawValue,
            ])
            return .failure(.commandFailed)
        }
    }
}
#endif
