import Alamofire
import Foundation
import PromiseKit
import Shared

final class GarminBridgeService {
    typealias ActionExecutor = (MagicItem, Server, @escaping (Swift.Result<Void, GarminBridgeError>) -> Void) -> Void
    typealias ItemInfoProvider = (MagicItem) -> MagicItem.Info?
    typealias StatusSnapshotProvider = (
        GarminConfig,
        @escaping (Swift.Result<GarminStatusSnapshot, GarminBridgeError>) -> Void
    ) -> Void

    private let client: GarminConnectIQClient
    private let actionExecutor: ActionExecutor
    private var currentConfigProvider: (() -> GarminConfig?)?
    private var currentItemInfoProvider: ItemInfoProvider?
    private var currentStatusSnapshotProvider: StatusSnapshotProvider?

    var connectionState: GarminConnectionState { client.state }

    init(
        client: GarminConnectIQClient = GarminConnectIQSDKClient(),
        actionExecutor: @escaping ActionExecutor = GarminActionExecutor.execute
    ) {
        self.client = client
        self.actionExecutor = actionExecutor
    }

    func setup(
        configProvider: @escaping () -> GarminConfig?,
        itemInfoProvider: ItemInfoProvider? = nil,
        statusSnapshotProvider: StatusSnapshotProvider? = nil
    ) {
        currentConfigProvider = configProvider
        currentItemInfoProvider = itemInfoProvider
        currentStatusSnapshotProvider = statusSnapshotProvider
        client.setup { [weak self] message in
            self?.handle(message)
        }
    }

    func sync(
        config: GarminConfig,
        itemInfo: (MagicItem) -> MagicItem.Info?,
        completion: @escaping (Swift.Result<Void, GarminBridgeError>) -> Void
    ) {
        guard client.state.isReady else {
            completion(.failure(error(for: client.state)))
            return
        }
        client.sendProfile(GarminProfile(config: config, itemInfo: itemInfo), completion: completion)
    }

    func disconnect(config: GarminConfig, completion: @escaping (Swift.Result<Void, GarminBridgeError>) -> Void) {
        client.disconnect()
        completion(.success(()))
    }

    func handle(_ message: GarminInboundMessage) {
        guard let config = currentConfigProvider?() else {
            send(.init(correlationId: message.correlationId, state: .failed, error: .missingConfig)) { _ in }
            return
        }
        handle(message, config: config) { _ in }
    }

    func handle(
        _ message: GarminInboundMessage,
        config: GarminConfig,
        completion: @escaping (GarminCommandResult) -> Void
    ) {
        guard message.version == GarminProtocolVersion.current else {
            let result = GarminCommandResult(
                correlationId: message.correlationId,
                state: .failed,
                error: .unsupportedProtocol
            )
            send(result, completion: completion)
            return
        }

        switch message.type {
        case .ping:
            completion(GarminCommandResult(correlationId: message.correlationId, state: .success))
        case .requestProfile:
            sendProfile(config: config, correlationId: message.correlationId, completion: completion)
        case .requestStatus:
            sendStatusSnapshot(config: config, correlationId: message.correlationId, completion: completion)
        case .callAction:
            handleCallAction(message, config: config, completion: completion)
        }
    }

    private func sendProfile(
        config: GarminConfig,
        correlationId: String?,
        completion: @escaping (GarminCommandResult) -> Void
    ) {
        guard client.state.isReady else {
            completion(.init(correlationId: correlationId, state: .failed, error: error(for: client.state)))
            return
        }
        let profile = GarminProfile(config: config, itemInfo: currentItemInfoProvider ?? { _ in nil })
        client.sendProfile(profile) { [weak self] result in
            self?.completeTransportResult(result, correlationId: correlationId, completion: completion)
        }
    }

    private func sendStatusSnapshot(
        config: GarminConfig,
        correlationId: String?,
        completion: @escaping (GarminCommandResult) -> Void
    ) {
        guard client.state.isReady else {
            completion(.init(correlationId: correlationId, state: .failed, error: error(for: client.state)))
            return
        }
        guard let currentStatusSnapshotProvider else {
            send(.init(correlationId: correlationId, state: .failed, error: .unsupportedStatus), completion: completion)
            return
        }

        currentStatusSnapshotProvider(config) { [weak self] snapshotResult in
            switch snapshotResult {
            case let .success(snapshot):
                self?.client.sendStatusSnapshot(snapshot) { [weak self] result in
                    self?.completeTransportResult(result, correlationId: correlationId, completion: completion)
                }
            case let .failure(error):
                self?.send(.init(correlationId: correlationId, state: .failed, error: error), completion: completion)
            }
        }
    }

    private func handleCallAction(
        _ message: GarminInboundMessage,
        config: GarminConfig,
        completion: @escaping (GarminCommandResult) -> Void
    ) {
        guard let actionId = message.actionId, let item = config.action(for: actionId) else {
            send(.init(correlationId: message.correlationId, state: .failed, error: .missingAction), completion: completion)
            return
        }
        guard GarminSupportedDomains.supportsAction(item) else {
            send(.init(correlationId: message.correlationId, state: .failed, error: .unsupportedAction), completion: completion)
            return
        }
        guard let server = Current.servers.server(forServerIdentifier: item.serverId) else {
            send(.init(correlationId: message.correlationId, state: .failed, error: .missingServer), completion: completion)
            return
        }

        actionExecutor(item, server) { [weak self] executionResult in
            let result: GarminCommandResult
            switch executionResult {
            case .success:
                result = .init(correlationId: message.correlationId, state: .success)
            case let .failure(error):
                result = .init(correlationId: message.correlationId, state: .failed, error: error)
            }
            self?.send(result, completion: completion)
        }
    }

    private func completeTransportResult(
        _ result: Swift.Result<Void, GarminBridgeError>,
        correlationId: String?,
        completion: @escaping (GarminCommandResult) -> Void
    ) {
        switch result {
        case .success:
            completion(.init(correlationId: correlationId, state: .success))
        case let .failure(error):
            completion(.init(correlationId: correlationId, state: .failed, error: error))
        }
    }

    private func send(_ result: GarminCommandResult, completion: @escaping (GarminCommandResult) -> Void) {
        client.sendActionResult(result) { _ in
            completion(result)
        }
    }

    private func error(for state: GarminConnectionState) -> GarminBridgeError {
        switch state {
        case .notConfigured, .appUnavailable, .deviceUnavailable:
            return .watchUnavailable
        case .sdkUnavailable:
            return .sdkUnavailable
        case .ready:
            return .commandFailed
        }
    }
}


private enum GarminActionExecutor {
    static func execute(
        item: MagicItem,
        server: Server,
        completion: @escaping (Swift.Result<Void, GarminBridgeError>) -> Void
    ) {
        guard GarminSupportedDomains.supportsAction(item) else {
            completion(.failure(.unsupportedAction))
            return
        }
        guard let api = Current.api(for: server) else {
            completion(.failure(.homeAssistantUnavailable))
            return
        }

        let request: Promise<Void>?
        switch item.type {
        case .script:
            request = api.turnOnScript(scriptEntityId: item.id, triggerSource: .Garmin)
        case .scene:
            request = api.CallService(
                domain: Domain.scene.rawValue,
                service: Service.turnOn.rawValue,
                serviceData: ["entity_id": item.id],
                triggerSource: .Garmin,
                shouldLog: true
            )
        case .entity:
            guard let domain = item.domain else {
                completion(.failure(.entityRemoved))
                return
            }
            request = api.executeActionForDomainType(domain: domain, entityId: item.id, state: "")
        case .action, .folder, .assistPipeline, .assistPrompt:
            request = nil
        }

        guard let request else {
            completion(.failure(.unsupportedAction))
            return
        }

        request.pipe { result in
            switch result {
            case .fulfilled:
                completion(.success(()))
            case let .rejected(error):
                completion(.failure(map(error: error)))
            }
        }
    }

    private static func map(error: Error) -> GarminBridgeError {
        if let authenticationError = error as? AuthenticationAPI.AuthenticationError {
            return map(authenticationError: authenticationError)
        }
        if let afError = error as? AFError,
           let authenticationError = afError.underlyingError as? AuthenticationAPI.AuthenticationError {
            return map(authenticationError: authenticationError)
        }
        if error is ServerConnectionError {
            return .homeAssistantUnavailable
        }
        return .commandFailed
    }

    private static func map(authenticationError: AuthenticationAPI.AuthenticationError) -> GarminBridgeError {
        switch authenticationError {
        case let .serverError(statusCode, _, _):
            if (400 ... 403).contains(statusCode) {
                return .loginRequired
            }
            return .homeAssistantUnavailable
        }
    }
}
