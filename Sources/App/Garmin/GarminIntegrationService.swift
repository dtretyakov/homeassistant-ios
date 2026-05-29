import Alamofire
import Foundation
import HAKit
import PromiseKit
import Shared
import UserNotifications

final class GarminIntegrationService {
    typealias ActionExecutor = (MagicItem, Server, @escaping (Swift.Result<Void, GarminIntegrationError>) -> Void) -> Void
    typealias ItemInfoProvider = (MagicItem) -> MagicItem.Info?
    typealias StatusSnapshotProvider = (
        GarminConfig,
        [MagicItem],
        Bool,
        @escaping (Swift.Result<GarminStatusSnapshot, GarminIntegrationError>) -> Void
    ) -> Void
    typealias OverviewSourceProvider = () -> GarminHomeOverviewSource

    private let client: GarminConnectIQClient
    private let actionExecutor: ActionExecutor
    private let overviewSourceProvider: OverviewSourceProvider
    private var currentConfigProvider: (() -> GarminConfig?)?
    private var currentItemInfoProvider: ItemInfoProvider?
    private var currentStatusSnapshotProvider: StatusSnapshotProvider?
    private let promptRegistry = GarminNotificationPromptRegistry()

    var connectionState: GarminConnectionState { client.state }

    init(
        client: GarminConnectIQClient,
        actionExecutor: @escaping ActionExecutor = GarminActionExecutor.execute,
        overviewSourceProvider: @escaping OverviewSourceProvider = { GarminHomeOverviewSource() }
    ) {
        self.client = client
        self.actionExecutor = actionExecutor
        self.overviewSourceProvider = overviewSourceProvider
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
        itemInfo: @escaping (MagicItem) -> MagicItem.Info?,
        completion: @escaping (Swift.Result<Void, GarminIntegrationError>) -> Void
    ) {
        _ = itemInfo
        guard client.state.isReady else {
            completion(.failure(error(for: client.state)))
            return
        }
        completion(.success(()))
    }

    func requestDeviceSelection(force: Bool) {
        client.requestDeviceSelection(force: force)
    }

    func disconnect(config: GarminConfig, completion: @escaping (Swift.Result<Void, GarminIntegrationError>) -> Void) {
        client.disconnect()
        completion(.success(()))
    }

    func handle(_ message: GarminInboundMessage) {
        guard let config = currentConfig() else {
            GarminDiagnostics.recordInbound(message, status: .failed, error: .missingConfig)
            send(.init(id: message.id, correlationId: message.correlationId, state: .failed, error: .missingConfig)) { _ in }
            return
        }
        handle(message, config: config) { _ in }
    }

    func handle(
        _ message: GarminInboundMessage,
        config: GarminConfig,
        completion: @escaping (GarminCommandResult) -> Void
    ) {
        GarminDiagnostics.recordInbound(message, status: .started)
        let recordingCompletion: (GarminCommandResult) -> Void = { result in
            GarminDiagnostics.recordInbound(
                message,
                status: result.state == .success ? .success : .failed,
                error: result.error,
                commandState: result.state
            )
            completion(result)
        }

        guard message.version == GarminProtocolVersion.current else {
            let result = GarminCommandResult(
                id: message.id,
                correlationId: message.correlationId,
                state: .failed,
                error: .unsupportedProtocol
            )
            send(result, completion: recordingCompletion)
            return
        }

        switch message.type {
        case .getSection:
            handleGetSection(message, config: config, completion: recordingCompletion)
        case .callAction:
            handleCallAction(message, config: config, completion: recordingCompletion)
        case .promptResponse:
            handlePromptResponse(message, completion: recordingCompletion)
        }
    }

    func sendNotificationPrompt(
        for content: UNNotificationContent,
        server: Server,
        completion: @escaping (Swift.Result<Void, GarminIntegrationError>) -> Void
    ) {
        guard client.state.isReady else {
            completion(.failure(error(for: client.state)))
            return
        }
        guard let pendingPrompt = GarminNotificationPromptBuilder.pendingPrompt(for: content, server: server) else {
            completion(.success(()))
            return
        }

        promptRegistry.store(pendingPrompt)
        client.sendNotificationPrompt(pendingPrompt.prompt) { [weak self] result in
            if case .failure = result {
                self?.promptRegistry.remove(promptId: pendingPrompt.prompt.id)
            }
            completion(result)
        }
    }

    private func handleGetSection(
        _ message: GarminInboundMessage,
        config: GarminConfig,
        completion: @escaping (GarminCommandResult) -> Void
    ) {
        guard client.state.isReady else {
            completion(.init(id: message.id, correlationId: message.correlationId, state: .failed, error: error(for: client.state)))
            return
        }
        guard let sectionId = message.id else {
            send(.init(id: message.id, correlationId: message.correlationId, state: .failed, error: .commandFailed), completion: completion)
            return
        }

        let overviewSource = overviewSourceProvider()
        let itemInfo = currentItemInfoProvider ?? { _ in nil }
        let visibleValueItems: [MagicItem]

        do {
            visibleValueItems = try overviewSource.valueItems(
                id: sectionId,
                config: config,
                itemInfo: itemInfo
            )
            updateVisibleItems(for: visibleValueItems)
        } catch {
            send(.init(id: sectionId, correlationId: message.correlationId, state: .failed, error: .homeAssistantUnavailable), completion: completion)
            return
        }

        do {
            guard let section = try overviewSource.section(
                id: sectionId,
                config: config,
                itemInfo: itemInfo,
                valueProvider: { _ in nil }
            ) else {
                send(.init(id: sectionId, correlationId: message.correlationId, state: .failed, error: .commandFailed), completion: completion)
                return
            }

            let completeAndRefreshValues: (Swift.Result<Void, GarminIntegrationError>) -> Void = { [weak self] result in
                guard let self else { return }
                self.completeTransportResult(result, correlationId: message.correlationId, completion: completion)
                guard case .success = result else { return }
                self.refreshValues(
                    for: visibleValueItems,
                    config: config,
                    correlationId: message.correlationId
                )
            }

            if message.etag == section.etag {
                client.sendSectionNotModified(
                    sectionId: section.id,
                    correlationId: message.correlationId,
                    completion: completeAndRefreshValues
                )
            } else {
                client.sendSectionSnapshot(
                    section,
                    correlationId: message.correlationId,
                    completion: completeAndRefreshValues
                )
            }
        } catch {
            send(.init(id: sectionId, correlationId: message.correlationId, state: .failed, error: .homeAssistantUnavailable), completion: completion)
        }
    }

    private func refreshValues(
        for items: [MagicItem],
        config: GarminConfig,
        correlationId: String?
    ) {
        let valueItems = Array(items
            .filter(GarminSupportedDomains.supportsStatus)
            .prefix(GarminConfig.maxSectionItems))
        guard !valueItems.isEmpty, let currentStatusSnapshotProvider else {
            return
        }

        currentStatusSnapshotProvider(config, valueItems, true) { [weak self] cachedResult in
            guard let self else { return }
            let cachedValues = self.overviewValues(result: cachedResult, items: valueItems)
            if !cachedValues.isEmpty {
                self.sendValuesIfNeeded(cachedValues, correlationId: correlationId) { _ in }
            }

            currentStatusSnapshotProvider(config, valueItems, false) { [weak self] freshResult in
                guard let self else { return }
                let freshValues = self.overviewValues(result: freshResult, items: valueItems)
                guard !freshValues.isEmpty, freshValues != cachedValues else { return }
                self.sendValuesIfNeeded(freshValues, correlationId: correlationId) { _ in }
            }
        }
    }

    private func overviewValues(
        result: Swift.Result<GarminStatusSnapshot, GarminIntegrationError>,
        items: [MagicItem]
    ) -> [GarminOverviewValue] {
        guard case let .success(snapshot) = result else { return [] }
        let valuesById = Dictionary(uniqueKeysWithValues: snapshot.statuses.map { ($0.id, $0.value) })
        return items.compactMap { item in
            let id = GarminConfig.opaqueItemId(for: item)
            guard let value = valuesById[id] else { return nil }
            return GarminOverviewValue(id: id, value: value)
        }
    }

    private func updateVisibleItems(for items: [MagicItem]) {
        let visibleItems = items
            .filter(GarminSupportedDomains.supportsStatus)
            .prefix(GarminConfig.maxSectionItems)
        visibleItems.forEach {
            GarminOverviewVisibleEntityRegistry.shared.register(item: $0)
        }
        let ids = Set(visibleItems.map { GarminConfig.opaqueItemId(for: $0) })
        GarminOverviewVisibleEntityRegistry.shared.setVisible(ids: ids)
        NotificationCenter.default.post(name: .garminVisibleItemsDidChange, object: nil)
    }

    private func sendValuesIfNeeded(
        _ values: [GarminOverviewValue],
        correlationId: String?,
        completion: @escaping (GarminCommandResult) -> Void
    ) {
        guard !values.isEmpty else {
            completion(.init(correlationId: correlationId, state: .success))
            return
        }
        client.sendValuesDelta(values, valuesRevision: GarminValuesRevisionCounter.shared.next(), isTransient: true) { [weak self] result in
            self?.completeTransportResult(result, correlationId: correlationId, completion: completion)
        }
    }

    private func handleCallAction(
        _ message: GarminInboundMessage,
        config: GarminConfig,
        completion: @escaping (GarminCommandResult) -> Void
    ) {
        guard let itemId = message.id,
              let item = resolveAction(itemId: itemId, config: config) else {
            completeAction(.init(id: message.id, correlationId: message.correlationId, state: .failed, error: .missingAction), completion: completion)
            return
        }
        GarminDiagnostics.record(.actionExecution, status: .started, metadata: [
            "message_type": message.type.rawValue,
            "id": message.correlationId ?? "",
            "protocol_version": message.version,
            "command_state": GarminCommandState.pending.rawValue,
        ])
        guard GarminSupportedDomains.supportsAction(item) else {
            completeAction(.init(id: itemId, correlationId: message.correlationId, state: .failed, error: .unsupportedAction), completion: completion)
            return
        }
        guard let server = Current.servers.server(forServerIdentifier: item.serverId) else {
            completeAction(.init(id: itemId, correlationId: message.correlationId, state: .failed, error: .missingServer), completion: completion)
            return
        }

        actionExecutor(item, server) { [weak self] executionResult in
            let result: GarminCommandResult
            switch executionResult {
            case .success:
                result = .init(id: itemId, correlationId: message.correlationId, state: .success)
            case let .failure(error):
                result = .init(id: itemId, correlationId: message.correlationId, state: .failed, error: error)
            }
            self?.completeAction(result, completion: completion)
        }
    }

    private func handlePromptResponse(
        _ message: GarminInboundMessage,
        completion: @escaping (GarminCommandResult) -> Void
    ) {
        guard let promptId = message.id,
              let actionId = message.actionId,
              let pendingPrompt = promptRegistry.remove(promptId: promptId) else {
            completeAction(.init(id: message.id, correlationId: message.correlationId, state: .failed, error: .missingAction), completion: completion)
            return
        }
        guard !pendingPrompt.isExpired else {
            GarminDiagnostics.record(.notificationPrompt, status: .skipped, metadata: [
                "id": message.correlationId ?? pendingPrompt.prompt.correlationId ?? "",
                "command_state": "expired",
            ])
            completeAction(.init(id: promptId, correlationId: message.correlationId, state: .failed, error: .commandFailed), completion: completion)
            return
        }
        guard let action = pendingPrompt.action(for: actionId) else {
            completeAction(.init(id: promptId, correlationId: message.correlationId, state: .failed, error: .missingAction), completion: completion)
            return
        }
        guard let server = Current.servers.server(forServerIdentifier: pendingPrompt.serverIdentifier),
              let api = Current.api(for: server) else {
            completeAction(.init(id: promptId, correlationId: message.correlationId, state: .failed, error: .missingServer), completion: completion)
            return
        }

        let info = HomeAssistantAPI.PushActionInfo(
            identifier: UNNotificationContent.uncombinedAction(from: action.identifier),
            category: pendingPrompt.category,
            actionData: pendingPrompt.actionData,
            textInput: nil
        )
        GarminDiagnostics.record(.notificationPrompt, status: .started, metadata: [
            "id": message.correlationId ?? pendingPrompt.prompt.correlationId ?? "",
            "action_count": pendingPrompt.prompt.actions.count,
            "command_state": GarminCommandState.pending.rawValue,
        ])
        api.handlePushAction(for: info).pipe { [weak self] result in
            switch result {
            case .fulfilled:
                self?.completeAction(.init(id: promptId, correlationId: message.correlationId, state: .success), completion: completion)
            case let .rejected(error):
                self?.completeAction(.init(
                    id: promptId,
                    correlationId: message.correlationId,
                    state: .failed,
                    error: GarminActionExecutor.map(error: error)
                ), completion: completion)
            }
        }
    }

    private func resolveAction(itemId: String, config: GarminConfig) -> MagicItem? {
        if let item = config.action(for: itemId), isActionUsable(item, config: config) {
            return item
        }
        if let item = resolveEntityAction(itemId: itemId, config: config) {
            return item
        }
        if let item = GarminOverviewActionRegistry.shared.action(for: itemId), isActionUsable(item, config: config) {
            return item
        }
        _ = try? overviewSourceProvider().section(
            id: GarminOverviewSectionID.root,
            config: config,
            itemInfo: currentItemInfoProvider ?? { _ in nil }
        )
        guard let item = GarminOverviewActionRegistry.shared.action(for: itemId),
              isActionUsable(item, config: config) else {
            return nil
        }
        return item
    }

    private func resolveEntityAction(itemId: String, config: GarminConfig) -> MagicItem? {
        guard let selectedServerId = config.selectedServerId else { return nil }
        let entities = (try? HAAppEntity.config()) ?? []
        for entity in entities where entity.serverId == selectedServerId && GarminSupportedDomains.supportsAction(rawDomain: entity.domain) {
            guard GarminConfig.opaqueEntityId(serverId: entity.serverId, entityId: entity.entityId) == itemId else { continue }
            let item = MagicItem(
                id: entity.entityId,
                serverId: entity.serverId,
                type: magicItemType(for: entity.domain),
                displayText: entity.name
            )
            guard isActionUsable(item, config: config) else { return nil }
            return item
        }
        return nil
    }

    private func isActionUsable(_ item: MagicItem, config: GarminConfig) -> Bool {
        guard GarminSupportedDomains.supportsAction(item) else { return false }
        if let selectedServerId = config.selectedServerId, item.serverId != selectedServerId {
            return false
        }
        return true
    }

    private func magicItemType(for domain: String) -> MagicItem.ItemType {
        switch Domain(rawValue: domain) {
        case .script:
            return .script
        case .scene:
            return .scene
        default:
            return .entity
        }
    }

    private func completeAction(
        _ result: GarminCommandResult,
        completion: @escaping (GarminCommandResult) -> Void
    ) {
        GarminDiagnostics.record(.actionExecution, status: result.state == .success ? .success : .failed, metadata: [
            "command_state": result.state.rawValue,
            "error_code": result.error?.rawValue ?? "",
            "id": result.correlationId ?? "",
        ])
        send(result, completion: completion)
    }

    private func completeTransportResult(
        _ result: Swift.Result<Void, GarminIntegrationError>,
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

    private func error(for state: GarminConnectionState) -> GarminIntegrationError {
        switch state {
        case .notConfigured, .selectingDevice, .waitingForWatch, .appUnavailable, .deviceUnavailable:
            return .watchUnavailable
        case .sdkUnavailable:
            return .sdkUnavailable
        case .ready:
            return .commandFailed
        }
    }

    private func currentConfig() -> GarminConfig? {
        if let config = currentConfigProvider?() {
            return config
        }

        var config = GarminConfig()
        config.selectedServerId = Current.servers.all.first?.identifier.rawValue
        return config
    }
}

private final class GarminNotificationPromptRegistry {
    private static let maxStoredPrompts = 20

    private let lock = NSLock()
    private var promptsById: [String: GarminPendingNotificationPrompt] = [:]

    func store(_ prompt: GarminPendingNotificationPrompt) {
        lock.lock()
        defer { lock.unlock() }

        pruneExpiredLocked()
        promptsById[prompt.prompt.id] = prompt
        pruneOverflowLocked()
    }

    func remove(promptId: String) -> GarminPendingNotificationPrompt? {
        lock.lock()
        defer { lock.unlock() }

        pruneExpiredLocked(except: promptId)
        return promptsById.removeValue(forKey: promptId)
    }

    private func pruneExpiredLocked(except promptId: String? = nil) {
        promptsById = promptsById.filter { id, prompt in
            id == promptId || !prompt.isExpired
        }
    }

    private func pruneOverflowLocked() {
        guard promptsById.count > Self.maxStoredPrompts else { return }

        let overflow = promptsById.count - Self.maxStoredPrompts
        let idsToRemove = promptsById
            .sorted { left, right in left.value.createdAt < right.value.createdAt }
            .prefix(overflow)
            .map(\.key)
        idsToRemove.forEach { promptsById.removeValue(forKey: $0) }
    }
}

private struct GarminPendingNotificationPrompt {
    let prompt: GarminNotificationPrompt
    let createdAt: Date
    let serverIdentifier: String
    let category: String?
    let actionData: Any?
    let actionsById: [String: MobileAppConfigPushCategory.Action]

    var isExpired: Bool {
        guard let expiresAt = prompt.expiresAt else { return false }
        return Int(Date().timeIntervalSince1970) > expiresAt
    }

    func action(for id: String) -> MobileAppConfigPushCategory.Action? {
        actionsById[id]
    }
}

private enum GarminNotificationPromptBuilder {
    private static let maxActions = 15
    private static let maxTitleLength = 80
    private static let maxBodyLength = 180
    private static let maxActionLabelLength = 40
    private static let defaultTimeout: TimeInterval = 300

    static func pendingPrompt(for content: UNNotificationContent, server: Server) -> GarminPendingNotificationPrompt? {
        let actionConfigs = Array(content.userInfoActionConfigs.filter(isWatchSafeAction).prefix(maxActions))
        guard !actionConfigs.isEmpty else { return nil }

        let promptId = "p_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let prompt = GarminNotificationPrompt(
            id: promptId,
            correlationId: promptId,
            title: truncated(promptTitle(for: content), maxLength: maxTitleLength),
            body: promptBody(for: content).map { truncated($0, maxLength: maxBodyLength) },
            actions: actionConfigs.map {
                GarminNotificationPromptAction(
                    id: $0.identifier,
                    label: truncated($0.title, maxLength: maxActionLabelLength)
                )
            },
            expiresAt: expiresAt(for: content)
        )

        return GarminPendingNotificationPrompt(
            prompt: prompt,
            createdAt: Date(),
            serverIdentifier: server.identifier.rawValue,
            category: content.categoryIdentifier.isEmpty ? nil : content.categoryIdentifier,
            actionData: content.userInfo["homeassistant"],
            actionsById: Dictionary(uniqueKeysWithValues: actionConfigs.map { ($0.identifier, $0) })
        )
    }

    private static func isWatchSafeAction(_ action: MobileAppConfigPushCategory.Action) -> Bool {
        let behavior = action.behavior.lowercased()
        let activationMode = action.activationMode.lowercased()
        return !action.authenticationRequired
            && !action.destructive
            && behavior != "textinput"
            && action.textInputButtonTitle == nil
            && action.textInputPlaceholder == nil
            && activationMode != "foreground"
            && action.url == nil
    }

    private static func promptTitle(for content: UNNotificationContent) -> String {
        if !content.title.isEmpty {
            return content.title
        }
        if !content.subtitle.isEmpty {
            return content.subtitle
        }
        return "Home Assistant"
    }

    private static func promptBody(for content: UNNotificationContent) -> String? {
        if !content.body.isEmpty {
            return content.body
        }
        if !content.subtitle.isEmpty && content.subtitle != content.title {
            return content.subtitle
        }
        return nil
    }

    private static func expiresAt(for content: UNNotificationContent) -> Int {
        if let explicit = intValue(content.userInfo["expires_at"]) {
            return explicit
        }
        let timeout = timeIntervalValue(content.userInfo["timeout"]) ?? defaultTimeout
        return Int(Date().addingTimeInterval(timeout).timeIntervalSince1970)
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Double:
            return Int(value)
        case let value as Float:
            return Int(value)
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private static func timeIntervalValue(_ value: Any?) -> TimeInterval? {
        switch value {
        case let value as Int:
            return TimeInterval(value)
        case let value as Double:
            return value
        case let value as Float:
            return TimeInterval(value)
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return TimeInterval(value)
        default:
            return nil
        }
    }

    private static func truncated(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength - 3)) + "..."
    }
}

private extension GarminDiagnostics {
    static func recordInbound(
        _ message: GarminInboundMessage,
        status: GarminDiagnostics.Status,
        error: GarminIntegrationError? = nil,
        commandState: GarminCommandState? = nil
    ) {
        record(.inboundMessage, status: status, metadata: [
            "message_type": message.type.rawValue,
            "protocol_version": message.version,
            "id": message.correlationId ?? "",
            "command_state": commandState?.rawValue ?? "",
            "error_code": error?.rawValue ?? "",
        ])
    }
}

private enum GarminActionExecutor {
    static func execute(
        item: MagicItem,
        server: Server,
        completion: @escaping (Swift.Result<Void, GarminIntegrationError>) -> Void
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
            if domain == .lock {
                request = api.connection.send(HATypedRequest<[HAEntity]>.fetchStates()).promise.then { states -> Promise<Void> in
                    guard let state = states.first(where: { $0.entityId == item.id })?.state else {
                        return .value
                    }
                    return api.executeActionForDomainType(domain: domain, entityId: item.id, state: state)
                }
            } else {
                request = api.executeActionForDomainType(domain: domain, entityId: item.id, state: "")
            }
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

    static func map(error: Error) -> GarminIntegrationError {
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

    private static func map(authenticationError: AuthenticationAPI.AuthenticationError) -> GarminIntegrationError {
        switch authenticationError {
        case let .serverError(statusCode, _, _):
            if (400 ... 403).contains(statusCode) {
                return .loginRequired
            }
            return .homeAssistantUnavailable
        }
    }
}
