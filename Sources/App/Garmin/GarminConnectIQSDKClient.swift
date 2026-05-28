import Combine
import Foundation
import Shared

#if GARMIN_CONNECTIQ_ENABLED
import ConnectIQ
#endif

final class GarminConnectIQSDKClient: NSObject, GarminConnectIQClient, GarminConnectionDiagnosticsProviding {
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
    private(set) var connectionDiagnostics = GarminConnectionDiagnostics.idle {
        didSet {
            connectionDiagnosticsSubject.send(connectionDiagnostics)
        }
    }
    var connectionDiagnosticsPublisher: AnyPublisher<GarminConnectionDiagnostics, Never> {
        connectionDiagnosticsSubject.eraseToAnyPublisher()
    }
    private let stateSubject = CurrentValueSubject<GarminConnectionState, Never>(.sdkUnavailable)
    private let connectionDiagnosticsSubject = CurrentValueSubject<GarminConnectionDiagnostics, Never>(.idle)
    private var commandHandler: ((GarminInboundMessage) -> Void)?

    #if GARMIN_CONNECTIQ_ENABLED
    private let connectIQ = ConnectIQ.sharedInstance()!
    private var activeDevice: IQDevice?
    private var activeApp: IQApp?
    private var isInitialized = false
    private var hasRequestedDeviceSelection = false
    private var stateBeforeDeviceSelection: GarminConnectionState?
    private let outboundQueue = GarminOutboundMessageQueue()
    #endif

    func setup(commandHandler: @escaping (GarminInboundMessage) -> Void) {
        self.commandHandler = commandHandler

        #if GARMIN_CONNECTIQ_ENABLED
        initializeSDKIfNeeded()
        updateDiagnostics(event: "setup")
        restoreConfiguredAppIfPossible()
        #else
        state = .sdkUnavailable
        GarminDiagnostics.record(.sdk, status: .unavailable, metadata: [
            "sdk_state": "sdk_unavailable",
            "connection_state": GarminDiagnostics.connectionState(state),
        ])
        #endif
    }

    func sendSectionSnapshot(
        _ section: GarminOverviewSection,
        correlationId: String?,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
        send(.init(type: .sectionSnapshot, correlationId: correlationId, section: section), completion: completion)
    }

    func sendSectionNotModified(
        sectionId: String,
        correlationId: String?,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
        send(.init(type: .sectionNotModified, id: sectionId, correlationId: correlationId), completion: completion)
    }

    func sendValuesDelta(
        _ values: [GarminOverviewValue],
        valuesRevision: Int,
        isTransient: Bool,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
        send(.init(type: .valuesDelta, values: values, valuesRevision: valuesRevision), isTransient: isTransient, completion: completion)
    }

    func sendActionResult(
        _ result: GarminCommandResult,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
        send(.init(type: .actionResult, actionResult: result), completion: completion)
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
        outboundQueue
            .cancelAll()
            .forEach { $0.complete(.failure(.watchUnavailable)) }
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
        GarminDiagnostics.record(.sdk, status: .success, metadata: [
            "sdk_state": "device_selected",
            "device_identifier": device.uuid.uuidString,
            "device_model": device.modelName ?? "",
            "device_name": device.friendlyName ?? "",
            "connection_state": GarminDiagnostics.connectionState(state),
        ])
        stateBeforeDeviceSelection = nil
        register(device: device, appIdentifier: appIdentifier)
        return true
        #else
        return false
        #endif
    }

    private func send(
        _ message: GarminOutboundMessage,
        isTransient: Bool = false,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
        do {
            let byteCount = try GarminPayloadCodec.encodedByteCount(message)
            guard byteCount <= GarminPayloadLimits.outboundMessageBytes else {
                updateDiagnostics(
                    event: "tx:too_large",
                    outboundBytes: byteCount,
                    outboundType: message.type.rawValue,
                    sdkResult: GarminIntegrationError.payloadTooLarge.rawValue
                )
                completion(.failure(.payloadTooLarge))
                return
            }
            updateDiagnostics(
                event: "tx:encoded",
                outboundBytes: byteCount,
                outboundType: message.type.rawValue,
                sdkResult: nil
            )
            enqueue(message, isTransient: isTransient, completion: completion)
        } catch {
            updateDiagnostics(event: "tx:bad", sdkResult: "encode_failed")
            completion(.failure(.commandFailed))
        }
    }

    private func enqueue(
        _ message: GarminOutboundMessage,
        isTransient: Bool,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
        #if GARMIN_CONNECTIQ_ENABLED
        let enqueueBlock = { [weak self] in
            guard let self else { return }
            self.outboundQueue.enqueue(message: message, isTransient: isTransient, completion: completion)
            self.updateDiagnostics(
                event: "tx:queued",
                outboundBytes: (try? GarminPayloadCodec.encodedByteCount(message)) ?? 0,
                outboundType: message.type.rawValue,
                sdkResult: nil
            )
            self.processOutboundQueue()
        }
        if Thread.isMainThread {
            enqueueBlock()
        } else {
            DispatchQueue.main.async(execute: enqueueBlock)
        }
        #else
        completion(.failure(.sdkUnavailable))
        #endif
    }

    #if GARMIN_CONNECTIQ_ENABLED
    private func processOutboundQueue() {
        guard let activeApp else {
            let queuedMessages = outboundQueue.cancelAll()
            updateDiagnostics(
                event: "tx:noapp",
                outboundBytes: 0,
                outboundType: queuedMessages.first?.message.type.rawValue,
                sdkResult: "no_active_app"
            )
            requestDeviceSelectionIfNeeded(force: false)
            queuedMessages.forEach { $0.complete(.failure(error(for: state))) }
            return
        }

        guard let queuedMessage = outboundQueue.startNext() else { return }
        let payload: [String: Any]
        do {
            let byteCount = try GarminPayloadCodec.encodedByteCount(queuedMessage.message)
            guard byteCount <= GarminPayloadLimits.outboundMessageBytes else {
                updateDiagnostics(
                    event: "tx:too_large",
                    outboundBytes: byteCount,
                    outboundType: queuedMessage.message.type.rawValue,
                    sdkResult: GarminIntegrationError.payloadTooLarge.rawValue
                )
                queuedMessage.complete(.failure(.payloadTooLarge))
                outboundQueue.finishCurrent()
                processOutboundQueue()
                return
            }
            payload = try GarminPayloadCodec.encodeOutboundDictionary(queuedMessage.message)
        } catch {
            updateDiagnostics(event: "tx:bad", sdkResult: "encode_failed")
            queuedMessage.complete(.failure(.commandFailed))
            outboundQueue.finishCurrent()
            processOutboundQueue()
            return
        }

        updateDiagnostics(
            event: "tx:send",
            outboundBytes: payloadByteCount(payload),
            outboundType: payload["t"] as? String,
            sdkResult: nil
        )
        connectIQ.sendMessage(payload, to: activeApp, progress: nil, completion: { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let mappedResult = self.result(for: result)
                let event: String
                switch mappedResult {
                case .success:
                    event = "tx:ok"
                case .failure:
                    event = "tx:error"
                }
                self.updateDiagnostics(
                    event: event,
                    outboundBytes: self.payloadByteCount(payload),
                    outboundType: payload["t"] as? String,
                    sdkResult: NSStringFromSendMessageResult(result) ?? "unknown"
                )
                if case let .failure(error) = mappedResult {
                    GarminDiagnostics.record(.sdk, status: .failed, metadata: [
                        "sdk_state": NSStringFromSendMessageResult(result) ?? "unknown",
                        "connection_state": GarminDiagnostics.connectionState(self.state),
                        "error_code": error.rawValue,
                    ])
                }
                queuedMessage.complete(mappedResult)
                self.outboundQueue.finishCurrent()
                self.processOutboundQueue()
            }
        }, isTransient: queuedMessage.isTransient)
    }
    #endif
}

final class GarminOutboundMessageQueue {
    private var pending: [QueuedOutboundMessage] = []
    private var current: QueuedOutboundMessage?

    func enqueue(
        message: GarminOutboundMessage,
        isTransient: Bool,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
        if isTransient, message.type == .valuesDelta {
            coalesceQueuedValues(message, completion: completion)
        } else {
            pending.append(.init(message: message, isTransient: isTransient, completions: [completion]))
        }
    }

    func startNext() -> QueuedOutboundMessage? {
        guard current == nil, !pending.isEmpty else { return nil }
        let queuedMessage = pending.removeFirst()
        current = queuedMessage
        return queuedMessage
    }

    func finishCurrent() {
        current = nil
    }

    @discardableResult
    func cancelAll() -> [QueuedOutboundMessage] {
        let queuedMessages = [current].compactMap { $0 } + pending
        current = nil
        pending.removeAll()
        return queuedMessages
    }

    private func coalesceQueuedValues(
        _ message: GarminOutboundMessage,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
        guard let index = pending.indices.last,
              pending[index].isTransient,
              pending[index].message.type == .valuesDelta else {
            pending.append(.init(message: message, isTransient: true, completions: [completion]))
            return
        }

        let existing = pending[index]
        let existingValues = existing.message.values ?? []
        let incomingValues = message.values ?? []
        var valuesById: [String: GarminOverviewValue] = [:]
        existingValues.forEach { valuesById[$0.id] = $0 }
        incomingValues.forEach { valuesById[$0.id] = $0 }

        var orderedIds: [String] = []
        (existingValues + incomingValues).forEach { value in
            if !orderedIds.contains(value.id) {
                orderedIds.append(value.id)
            }
        }

        let coalescedMessage = GarminOutboundMessage(
            type: .valuesDelta,
            values: orderedIds.compactMap { valuesById[$0] },
            valuesRevision: max(existing.message.valuesRevision ?? 0, message.valuesRevision ?? 0)
        )
        pending[index] = .init(
            message: coalescedMessage,
            isTransient: true,
            completions: existing.completions + [completion]
        )
    }
}

struct QueuedOutboundMessage {
    let message: GarminOutboundMessage
    let isTransient: Bool
    let completions: [(Result<Void, GarminIntegrationError>) -> Void]

    func complete(_ result: Result<Void, GarminIntegrationError>) {
        completions.forEach { $0(result) }
    }
}

#if GARMIN_CONNECTIQ_ENABLED
extension GarminConnectIQSDKClient: IQDeviceEventDelegate, IQAppMessageDelegate {
    func deviceStatusChanged(_ device: IQDevice!, status: IQDeviceStatus) {
        let nextState = connectionState(for: status, deviceName: device?.friendlyName ?? device?.modelName)
        if !state.isReady || !nextState.isWaitingForWatch {
            state = nextState
        }
        updateDiagnostics(event: "device:\(GarminDiagnostics.connectionState(nextState))")
        GarminDiagnostics.record(.sdk, status: state.isReady ? .success : .unavailable, metadata: [
            "connection_state": GarminDiagnostics.connectionState(state),
        ])
    }

    func deviceCharacteristicsDiscovered(_ device: IQDevice!) {
        guard let device else { return }
        if !state.isReady {
            state = .waitingForWatch(deviceName: device.friendlyName ?? device.modelName)
        }
        updateDiagnostics(event: "device:chars")
        GarminDiagnostics.record(.sdk, status: .skipped, metadata: [
            "connection_state": GarminDiagnostics.connectionState(state),
        ])
    }

    func receivedMessage(_ message: Any!, from app: IQApp!) {
        guard let app else { return }
        let inboundBytes = payloadByteCount(message)
        let inboundType = (message as? [String: Any])?["t"] as? String
        updateDiagnostics(event: "rx:start", inboundBytes: inboundBytes, inboundType: inboundType)
        guard isExpected(app: app) else {
            updateDiagnostics(event: "rx:unexpected", inboundBytes: inboundBytes, inboundType: inboundType)
            GarminDiagnostics.record(.inboundMessage, status: .failed, metadata: [
                "sdk_state": "unexpected_device",
                "connection_state": GarminDiagnostics.connectionState(state),
                "error_code": GarminIntegrationError.watchUnavailable.rawValue,
            ])
            return
        }
        guard let payload = message as? [String: Any],
              (try? JSONSerialization.data(withJSONObject: payload).count) ?? Int.max <= GarminPayloadLimits.inboundCommandBytes else {
            updateDiagnostics(event: "rx:bad", inboundBytes: inboundBytes, inboundType: inboundType)
            GarminDiagnostics.record(.inboundMessage, status: .failed, metadata: [
                "error_code": GarminIntegrationError.payloadTooLarge.rawValue,
                "connection_state": GarminDiagnostics.connectionState(state),
            ])
            return
        }

        do {
            let decoded = try GarminPayloadCodec.decodeInboundDictionary(payload)
            updateDiagnostics(event: "rx:decoded", inboundBytes: inboundBytes, inboundType: decoded.type.rawValue)
            persistObservedAppCommunication(app: app)
            commandHandler?(decoded)
        } catch {
            updateDiagnostics(event: "rx:bad", inboundBytes: inboundBytes, inboundType: inboundType)
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
        updateDiagnostics(event: "sdk:init")
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

        let deviceName = config.deviceName ?? "Garmin watch"
        guard let device = IQDevice(id: deviceUUID, modelName: deviceName, friendlyName: deviceName) else {
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
        updateDiagnostics(event: "sdk:registered")

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
        updateDiagnostics(event: "select:start")
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

    func persistObservedAppCommunication(app: IQApp) {
        activeApp = app
        activeDevice = app.device
        let deviceName = displayName(for: app.device)
        let readyState: GarminConnectionState = .ready(deviceName: deviceName)

        do {
            try Current.database().write { db in
                var config = try GarminConfig.fetchOne(db) ?? GarminConfig()
                if config.selectedServerId == nil {
                    config.selectedServerId = Current.servers.all.first?.identifier.rawValue
                }
                config.deviceIdentifier = app.device.uuid.uuidString
                config.appIdentifier = app.uuid.uuidString
                config.deviceName = deviceName
                config.lastCommunicationTimestamp = Current.date().timeIntervalSince1970
                config.lastError = nil
                try config.insert(db, onConflict: .replace)
            }
            state = readyState
            updateDiagnostics(event: "paired")
            GarminDiagnostics.record(.sdk, status: .success, metadata: [
                "sdk_state": "paired",
                "connection_state": GarminDiagnostics.connectionState(state),
            ])
        } catch {
            GarminDiagnostics.record(.sdk, status: .failed, metadata: [
                "sdk_state": "communication_persist_failed",
                "connection_state": GarminDiagnostics.connectionState(state),
                "error_code": GarminIntegrationError.commandFailed.rawValue,
            ])
        }
    }

    func displayName(for device: IQDevice) -> String {
        device.friendlyName ?? device.modelName ?? "Garmin watch"
    }

    func payloadByteCount(_ payload: Any?) -> Int {
        guard let payload, JSONSerialization.isValidJSONObject(payload) else { return 0 }
        return (try? JSONSerialization.data(withJSONObject: payload).count) ?? 0
    }

    func updateDiagnostics(
        event: String,
        inboundBytes: Int? = nil,
        outboundBytes: Int? = nil,
        inboundType: String? = nil,
        outboundType: String? = nil,
        sdkResult: String? = nil
    ) {
        connectionDiagnostics = GarminConnectionDiagnostics(
            event: event,
            inboundBytes: inboundBytes ?? connectionDiagnostics.inboundBytes,
            outboundBytes: outboundBytes ?? connectionDiagnostics.outboundBytes,
            inboundType: inboundType ?? connectionDiagnostics.inboundType,
            outboundType: outboundType ?? connectionDiagnostics.outboundType,
            sdkResult: sdkResult
        )
        GarminDiagnostics.record(.sdk, status: .skipped, metadata: [
            "sdk_state": event,
            "connection_state": GarminDiagnostics.connectionState(state),
            "message_type": inboundType ?? outboundType ?? "",
            "inbound_bytes": inboundBytes ?? connectionDiagnostics.inboundBytes,
            "outbound_bytes": outboundBytes ?? connectionDiagnostics.outboundBytes,
            "sdk_result": sdkResult ?? "",
        ])
    }
}
#endif
