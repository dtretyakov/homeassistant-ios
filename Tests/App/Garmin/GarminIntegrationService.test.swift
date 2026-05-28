import Combine
import HAKit
@testable import HomeAssistant
import PromiseKit
@testable import Shared
import Testing

final class FakeGarminConnectIQClient: GarminConnectIQClient {
    var state: GarminConnectionState = .ready(deviceName: "Test Garmin") {
        didSet {
            guard state != oldValue else { return }
            stateSubject.send(state)
        }
    }
    var statePublisher: AnyPublisher<GarminConnectionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }
    private let stateSubject = CurrentValueSubject<GarminConnectionState, Never>(.ready(deviceName: "Test Garmin"))
    var sentResults: [GarminCommandResult] = []
    var sentSections: [(section: GarminOverviewSection, correlationId: String?)] = []
    var sentSectionNotModifiedIds: [(sectionId: String, correlationId: String?)] = []
    var sentValuesDeltas: [(values: [GarminOverviewValue], revision: Int, isTransient: Bool)] = []
    var didRequestDeviceSelection = false
    private var commandHandler: ((GarminInboundMessage) -> Void)?

    func setup(commandHandler: @escaping (GarminInboundMessage) -> Void) {
        self.commandHandler = commandHandler
    }

    func sendSectionSnapshot(
        _ section: GarminOverviewSection,
        correlationId: String?,
        completion: @escaping (Swift.Result<Void, GarminIntegrationError>) -> Void
    ) {
        sentSections.append((section, correlationId))
        completion(.success(()))
    }

    func sendSectionNotModified(
        sectionId: String,
        correlationId: String?,
        completion: @escaping (Swift.Result<Void, GarminIntegrationError>) -> Void
    ) {
        sentSectionNotModifiedIds.append((sectionId, correlationId))
        completion(.success(()))
    }

    func sendValuesDelta(
        _ values: [GarminOverviewValue],
        valuesRevision: Int,
        isTransient: Bool,
        completion: @escaping (Swift.Result<Void, GarminIntegrationError>) -> Void
    ) {
        sentValuesDeltas.append((values: values, revision: valuesRevision, isTransient: isTransient))
        completion(.success(()))
    }

    func sendActionResult(
        _ result: GarminCommandResult,
        completion: @escaping (Swift.Result<Void, GarminIntegrationError>) -> Void
    ) {
        sentResults.append(result)
        completion(.success(()))
    }

    func disconnect() {
        state = .notConfigured
    }

    func requestDeviceSelection(force: Bool) {
        didRequestDeviceSelection = true
        state = .selectingDevice
    }

    func handleDeviceSelectionResponse(_ url: URL) -> Bool {
        false
    }
}

private final class GarminFakeWebhookManager: WebhookManager {
    var sendRequestHandler: ((WebhookResponseIdentifier, Server, WebhookRequest, Resolver<Void>) -> Void)?

    override func send(
        identifier: WebhookResponseIdentifier = .unhandled,
        server: Server,
        request: WebhookRequest
    ) -> Promise<Void> {
        let (promise, seal) = Promise<Void>.pending()
        sendRequestHandler?(identifier, server, request, seal)
        return promise
    }
}

@Suite(.serialized)
struct GarminIntegrationServiceTests {
    @Test func sdkClientRejectsOversizedSectionBeforeTransportSend() throws {
        let client = GarminConnectIQSDKClient()
        let oversizedLabel = String(repeating: "A", count: GarminPayloadLimits.outboundMessageBytes)
        let section = GarminOverviewSection(id: "large", title: oversizedLabel, etag: "large", items: [])
        var sendResult: Swift.Result<Void, GarminIntegrationError>?

        client.sendSectionSnapshot(section, correlationId: nil) { result in
            sendResult = result
        }

        guard case let .failure(error) = sendResult else {
            Issue.record("Expected oversized payload to fail")
            return
        }
        #expect(error == .payloadTooLarge)
    }

    @Test func syncDoesNotRequestDeviceSelectionWhenNotConfigured() throws {
        let client = FakeGarminConnectIQClient()
        client.state = .notConfigured
        let service = GarminIntegrationService(client: client)
        var syncResult: Swift.Result<Void, GarminIntegrationError>?

        service.sync(config: GarminConfig(), itemInfo: { _ in nil }) { result in
            syncResult = result
        }

        guard case let .failure(error) = syncResult else {
            Issue.record("Expected sync to fail until Garmin device is selected")
            return
        }
        #expect(error == .watchUnavailable)
        #expect(!client.didRequestDeviceSelection)
    }

    @Test func connectionCheckRequestsDeviceSelection() throws {
        let client = FakeGarminConnectIQClient()
        let service = GarminIntegrationService(client: client)

        service.requestDeviceSelection(force: true)

        #expect(client.didRequestDeviceSelection)
    }

    @Test func connectIQURLFilterRejectsHomeAssistantDeepLinks() throws {
        #expect(GarminFeature.canHandleConnectIQURL(URL(string: "homeassistant-garmin-ciq://device-select-resp")!))
        #expect(!GarminFeature.canHandleConnectIQURL(URL(string: "homeassistant://perform_action")!))
        #expect(!GarminFeature.canHandleConnectIQURL(URL(string: "homeassistant-dev://auth-callback")!))
    }

    @Test func unsupportedProtocolFails() throws {
        let client = FakeGarminConnectIQClient()
        let service = GarminIntegrationService(client: client)
        let message = GarminInboundMessage(version: 999, type: .callAction, correlationId: "c1")
        var handledResult: GarminCommandResult?

        service.handle(message, config: GarminConfig()) { result in
            handledResult = result
        }

        #expect(handledResult?.state == .failed)
        #expect(handledResult?.error == .unsupportedProtocol)
    }

    @Test func syncDoesNotPushUncorrelatedSectionSnapshots() throws {
        let client = FakeGarminConnectIQClient()
        let item = MagicItem(id: "sensor.temperature", serverId: "server-1", type: .entity, displayText: "Temperature")
        let service = GarminIntegrationService(client: client)
        let config = customConfig(statusItems: [item])
        var didSync = false

        service.sync(config: config, itemInfo: { _ in nil }) { result in
            guard case .success = result else {
                Issue.record("Expected sync success")
                return
            }
            didSync = true
        }

        #expect(didSync)
        #expect(client.sentSections.isEmpty)
        #expect(client.sentSectionNotModifiedIds.isEmpty)
        #expect(client.sentValuesDeltas.isEmpty)
    }

    @Test func getSectionMatchingEtagReturnsNotModifiedThenFreshValues() throws {
        defer { GarminOverviewVisibleEntityRegistry.shared.clearVisible() }
        let client = FakeGarminConnectIQClient()
        let item = MagicItem(
            id: "sensor.temperature",
            serverId: "server-1",
            type: .entity,
            displayText: "Temperature"
        )
        let config = customConfig(statusItems: [item])
        let source = GarminHomeOverviewSource(entityProvider: { [] }, areaProvider: { _ in [] })
        let section = try #require(try source.section(
            id: GarminOverviewSectionID.custom("custom-1"),
            config: config,
            itemInfo: { _ in nil }
        ))
        let snapshot = GarminStatusSnapshot(statuses: [
            .init(id: GarminConfig.opaqueItemId(for: item), label: "Temperature", value: "20 C"),
        ])
        let service = GarminIntegrationService(
            client: client,
            overviewSourceProvider: { source }
        )
        service.setup(
            configProvider: { config },
            statusSnapshotProvider: { _, _, cacheOnly, completion in
                guard !cacheOnly else {
                    completion(.failure(.homeAssistantUnavailable))
                    return
                }
                #expect(client.sentSectionNotModifiedIds.count == 1)
                completion(.success(snapshot))
            }
        )

        service.handle(GarminInboundMessage(
            type: .getSection,
            id: GarminOverviewSectionID.custom("custom-1"),
            etag: section.etag,
            correlationId: "s1"
        ))

        #expect(client.sentSectionNotModifiedIds.first?.sectionId == GarminOverviewSectionID.custom("custom-1"))
        #expect(client.sentSectionNotModifiedIds.first?.correlationId == "s1")
        #expect(client.sentValuesDeltas.count == 1)
        #expect(client.sentValuesDeltas.first?.values == [
            GarminOverviewValue(
                id: GarminConfig.opaqueEntityId(serverId: item.serverId, entityId: item.id),
                value: "20 C"
            ),
        ])
        #expect(client.sentValuesDeltas.first?.isTransient == true)
    }

    @Test func getRootSectionDoesNotRequestStatusSnapshot() throws {
        defer { GarminOverviewVisibleEntityRegistry.shared.clearVisible() }
        let client = FakeGarminConnectIQClient()
        let service = GarminIntegrationService(client: client)
        service.setup(
            configProvider: { customConfig() },
            statusSnapshotProvider: { _, _, _, completion in
                Issue.record("Root section has no value items and should not request a snapshot")
                completion(.failure(.homeAssistantUnavailable))
            }
        )

        service.handle(GarminInboundMessage(
            type: .getSection,
            id: GarminOverviewSectionID.root,
            correlationId: "root-1"
        ))

        #expect(client.sentSections.first?.section.id == GarminOverviewSectionID.root)
        #expect(client.sentValuesDeltas.isEmpty)
    }

    @Test func getSectionSendsCachedValuesThenChangedFreshValues() throws {
        defer { GarminOverviewVisibleEntityRegistry.shared.clearVisible() }
        let client = FakeGarminConnectIQClient()
        let item = MagicItem(
            id: "sensor.temperature",
            serverId: "server-1",
            type: .entity,
            displayText: "Temperature"
        )
        let cachedSnapshot = GarminStatusSnapshot(statuses: [
            .init(id: GarminConfig.opaqueItemId(for: item), label: "Temperature", value: "20 C"),
        ])
        let freshSnapshot = GarminStatusSnapshot(statuses: [
            .init(id: GarminConfig.opaqueItemId(for: item), label: "Temperature", value: "21 C"),
        ])
        let service = GarminIntegrationService(client: client)
        service.setup(
            configProvider: { customConfig(statusItems: [item]) },
            statusSnapshotProvider: { _, _, cacheOnly, completion in
                #expect(client.sentSections.count == 1)
                completion(.success(cacheOnly ? cachedSnapshot : freshSnapshot))
            }
        )

        service.handle(GarminInboundMessage(
            type: .getSection,
            id: GarminOverviewSectionID.custom("custom-1"),
            correlationId: "s1"
        ))

        #expect(client.sentSections.first?.section.values.isEmpty == true)
        #expect(client.sentValuesDeltas.map(\.values) == [
            [GarminOverviewValue(id: GarminConfig.opaqueItemId(for: item), value: "20 C")],
            [GarminOverviewValue(id: GarminConfig.opaqueItemId(for: item), value: "21 C")],
        ])
    }

    @Test func getSectionSkipsFreshValuesWhenUnchangedFromCache() throws {
        defer { GarminOverviewVisibleEntityRegistry.shared.clearVisible() }
        let client = FakeGarminConnectIQClient()
        let item = MagicItem(
            id: "sensor.temperature",
            serverId: "server-1",
            type: .entity,
            displayText: "Temperature"
        )
        let snapshot = GarminStatusSnapshot(statuses: [
            .init(id: GarminConfig.opaqueItemId(for: item), label: "Temperature", value: "20 C"),
        ])
        let service = GarminIntegrationService(client: client)
        service.setup(
            configProvider: { customConfig(statusItems: [item]) },
            statusSnapshotProvider: { _, _, _, completion in
                completion(.success(snapshot))
            }
        )

        service.handle(GarminInboundMessage(
            type: .getSection,
            id: GarminOverviewSectionID.custom("custom-1"),
            correlationId: "s1"
        ))

        #expect(client.sentSections.first?.section.values.isEmpty == true)
        #expect(client.sentValuesDeltas.map(\.values) == [
            [GarminOverviewValue(id: GarminConfig.opaqueItemId(for: item), value: "20 C")],
        ])
    }

    @Test func missingActionFailsWithoutExecuting() throws {
        let client = FakeGarminConnectIQClient()
        var didExecute = false
        let service = GarminIntegrationService(client: client) { _, _, completion in
            didExecute = true
            completion(.success(()))
        }
        let message = GarminInboundMessage(type: .callAction, id: "e_missing", correlationId: "c1")
        var handledResult: GarminCommandResult?

        service.handle(message, config: GarminConfig()) { result in
            handledResult = result
        }

        #expect(handledResult?.state == .failed)
        #expect(handledResult?.error == .missingAction)
        #expect(handledResult?.correlationId == "c1")
        #expect(!didExecute)
    }

    @Test func customActionResolvesFromRootOverviewAfterRegistryReset() throws {
        try withWebhookCapture { capturedRequests in
            GarminOverviewActionRegistry.shared.clear()
            let client = FakeGarminConnectIQClient()
            let source = GarminHomeOverviewSource(
                entityProvider: { [] },
                areaProvider: { _ in [] }
            )
            let service = GarminIntegrationService(
                client: client,
                overviewSourceProvider: { source }
            )
            let item = MagicItem(id: "scene.movie", serverId: "server-1", type: .scene, displayText: "Movie")
            let message = GarminInboundMessage(
                type: .callAction,
                id: GarminConfig.opaqueItemId(for: item),
                correlationId: "c1"
            )

            service.handle(message, config: customConfig(actionItems: [item])) { _ in }

            let request = try #require(capturedRequests().first)
            let data = try #require(request.data as? [String: Any])
            #expect(data["domain"] as? String == "scene")
            #expect(data["service"] as? String == "turn_on")
        }
    }

    @Test func getSectionPrioritizesVisibleBuiltInStatusOverCustomStatusLimit() throws {
        defer { GarminOverviewVisibleEntityRegistry.shared.clearVisible() }
        let client = FakeGarminConnectIQClient()
        let customItems = (0..<GarminConfig.maxSectionItems).map { index in
            MagicItem(id: "sensor.custom_\(index)", serverId: "server-1", type: .entity)
        }
        let areaEntity = HAAppEntity(
            id: "server-1-sensor.area_temperature",
            entityId: "sensor.area_temperature",
            serverId: "server-1",
            domain: "sensor",
            name: "Area temperature",
            icon: nil,
            rawDeviceClass: nil
        )
        let areaItem = MagicItem(id: areaEntity.entityId, serverId: areaEntity.serverId, type: .entity)
        let config = customConfig(statusItems: customItems)
        let source = GarminHomeOverviewSource(
            entityProvider: { [areaEntity] },
            areaProvider: { _ in [
                AppArea(
                    id: "server-1-kitchen",
                    serverId: "server-1",
                    areaId: "kitchen",
                    name: "Kitchen",
                    aliases: [],
                    picture: nil,
                    icon: nil,
                    sortOrder: nil,
                    entities: [areaEntity.entityId]
                ),
            ] }
        )
        let snapshot = GarminStatusSnapshot(statuses: [
            .init(id: GarminConfig.opaqueItemId(for: areaItem), label: "Area temperature", value: "21 C"),
        ])
        let service = GarminIntegrationService(
            client: client,
            overviewSourceProvider: { source }
        )
        service.setup(
            configProvider: { config },
            statusSnapshotProvider: { _, items, cacheOnly, completion in
                #expect(items.map(\.id) == [areaItem.id])
                guard !cacheOnly else {
                    completion(.failure(.homeAssistantUnavailable))
                    return
                }
                #expect(client.sentSections.count == 1)
                completion(.success(snapshot))
            }
        )

        service.handle(GarminInboundMessage(
            type: .getSection,
            id: GarminOverviewSectionID.area("kitchen"),
            correlationId: "o1"
        ))

        #expect(client.sentSections.last?.section.values.isEmpty == true)
        #expect(client.sentValuesDeltas.last?.values == [
            GarminOverviewValue(
                id: GarminConfig.opaqueEntityId(serverId: areaItem.serverId, entityId: areaItem.id),
                value: "21 C"
            ),
        ])
    }

    @Test func getSectionSetsRequestedSectionVisibleItemsBeforeSnapshot() throws {
        defer { GarminOverviewVisibleEntityRegistry.shared.clearVisible() }
        let client = FakeGarminConnectIQClient()
        let areaEntity = HAAppEntity(
            id: "server-1-sensor.area_temperature",
            entityId: "sensor.area_temperature",
            serverId: "server-1",
            domain: "sensor",
            name: "Area temperature",
            icon: nil,
            rawDeviceClass: nil
        )
        let areaItem = MagicItem(id: areaEntity.entityId, serverId: areaEntity.serverId, type: .entity)
        let source = GarminHomeOverviewSource(
            entityProvider: { [areaEntity] },
            areaProvider: { _ in [
                AppArea(
                    id: "server-1-kitchen",
                    serverId: "server-1",
                    areaId: "kitchen",
                    name: "Kitchen",
                    aliases: [],
                    picture: nil,
                    icon: nil,
                    sortOrder: nil,
                    entities: [areaEntity.entityId]
                ),
            ] }
        )
        let service = GarminIntegrationService(
            client: client,
            overviewSourceProvider: { source }
        )
        service.setup(
            configProvider: { customConfig() },
            statusSnapshotProvider: { _, _, cacheOnly, completion in
                guard !cacheOnly else {
                    completion(.failure(.homeAssistantUnavailable))
                    return
                }
                #expect(client.sentSections.count == 1)
                let visibleIds = GarminOverviewVisibleEntityRegistry.shared.visibleStatusItems(limit: GarminConfig.maxSectionItems)
                    .map { GarminConfig.opaqueItemId(for: $0) }
                #expect(visibleIds == [GarminConfig.opaqueItemId(for: areaItem)])
                completion(.success(GarminStatusSnapshot(statuses: [
                    .init(id: GarminConfig.opaqueItemId(for: areaItem), label: "Area temperature", value: "21 C"),
                ])))
            }
        )

        service.handle(GarminInboundMessage(
            type: .getSection,
            id: GarminOverviewSectionID.area("kitchen"),
            correlationId: "o1"
        ))

        #expect(client.sentSections.last?.section.values.isEmpty == true)
        #expect(client.sentValuesDeltas.last?.values == [
            GarminOverviewValue(
                id: GarminConfig.opaqueEntityId(serverId: areaItem.serverId, entityId: areaItem.id),
                value: "21 C"
            ),
        ])
    }

    @Test func nonActionCapableItemFailsAsMissingActionWithoutExecuting() throws {
        let client = FakeGarminConnectIQClient()
        var didExecute = false
        let item = MagicItem(id: "climate.hallway", serverId: "server-1", type: .entity)
        let config = customConfig(actionItems: [item])
        let service = GarminIntegrationService(client: client) { _, _, completion in
            didExecute = true
            completion(.success(()))
        }
        let message = GarminInboundMessage(
            type: .callAction,
            id: GarminConfig.opaqueItemId(for: item),
            correlationId: "c1"
        )
        var handledResult: GarminCommandResult?

        service.handle(message, config: config) { result in
            handledResult = result
        }

        #expect(handledResult?.state == .failed)
        #expect(handledResult?.error == .missingAction)
        #expect(handledResult?.correlationId == "c1")
        #expect(!didExecute)
    }

    @Test func typedExecutorFailureIsPreserved() throws {
        try withServer(identifier: "server-1") { _ in
            let client = FakeGarminConnectIQClient()
            let item = MagicItem(id: "light.kitchen", serverId: "server-1", type: .entity)
            let config = customConfig(actionItems: [item])
            let service = GarminIntegrationService(client: client) { _, _, completion in
                completion(.failure(.loginRequired))
            }
            let message = GarminInboundMessage(
                type: .callAction,
                id: GarminConfig.opaqueItemId(for: item),
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

    @Test func nonSelectedServerActionFailsAsMissingActionWithoutExecuting() throws {
        try withServer(identifier: "server-1") { _ in
            let client = FakeGarminConnectIQClient()
            var didExecute = false
            let item = MagicItem(id: "light.kitchen", serverId: "missing-server", type: .entity)
            let config = customConfig(actionItems: [item])
            let service = GarminIntegrationService(client: client) { _, _, completion in
                didExecute = true
                completion(.success(()))
            }
            let message = GarminInboundMessage(
                type: .callAction,
                id: GarminConfig.opaqueItemId(for: item),
                correlationId: "c1"
            )
            var handledResult: GarminCommandResult?

            service.handle(message, config: config) { result in
                handledResult = result
            }

            #expect(handledResult?.state == .failed)
            #expect(handledResult?.error == .missingAction)
            #expect(handledResult?.correlationId == "c1")
            #expect(!didExecute)
        }
    }

    @Test func executorSuccessSendsSuccessWithCorrelationId() throws {
        try withServer(identifier: "server-1") { _ in
            let client = FakeGarminConnectIQClient()
            let item = MagicItem(id: "light.kitchen", serverId: "server-1", type: .entity)
            let config = customConfig(actionItems: [item])
            let service = GarminIntegrationService(client: client) { _, _, completion in
                completion(.success(()))
            }
            let message = GarminInboundMessage(
                type: .callAction,
                id: GarminConfig.opaqueItemId(for: item),
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
            let config = customConfig(actionItems: [item])
            let service = GarminIntegrationService(client: client)
            let message = GarminInboundMessage(
                type: .callAction,
                id: GarminConfig.opaqueItemId(for: item),
                correlationId: "c1"
            )

            service.handle(message, config: config) { _ in }

            let request = try #require(capturedRequests().first)
            let data = try #require(request.data as? [String: Any])
            let serviceData = try #require(data["service_data"] as? [String: Any])
            #expect(request.type == "call_service")
            #expect(data["domain"] as? String == "script")
            #expect(data["service"] as? String == "turn_on")
            #expect(serviceData["entity_id"] as? String == "script.good_night")
        }
    }

    @Test func sceneActionUsesSceneTurnOnWithEntityId() throws {
        try withWebhookCapture { capturedRequests in
            let client = FakeGarminConnectIQClient()
            let item = MagicItem(id: "scene.movie", serverId: "server-1", type: .scene)
            let config = customConfig(actionItems: [item])
            let service = GarminIntegrationService(client: client)
            let message = GarminInboundMessage(
                type: .callAction,
                id: GarminConfig.opaqueItemId(for: item),
                correlationId: "c1"
            )

            service.handle(message, config: config) { _ in }

            let request = try #require(capturedRequests().first)
            let data = try #require(request.data as? [String: Any])
            let serviceData = try #require(data["service_data"] as? [String: Any])
            #expect(request.type == "call_service")
            #expect(data["domain"] as? String == "scene")
            #expect(data["service"] as? String == "turn_on")
            #expect(serviceData["entity_id"] as? String == "scene.movie")
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
            let config = customConfig(actionItems: [item])
            let service = GarminIntegrationService(client: client)
            let message = GarminInboundMessage(
                type: .callAction,
                id: GarminConfig.opaqueItemId(for: item),
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
            let config = customConfig(actionItems: [item])
            let service = GarminIntegrationService(client: client)
            let message = GarminInboundMessage(
                type: .callAction,
                id: GarminConfig.opaqueItemId(for: item),
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
            id: "e_1",
            correlationId: "c1"
        ))
        let payload = try #require(String(data: data, encoding: .utf8))

        #expect(!payload.contains("confirmed"))
        #expect(!payload.contains("confirmation_required"))
    }

    @Test func syncDoesNotPushActiveSectionSnapshotAfterGetSection() throws {
        defer { GarminOverviewVisibleEntityRegistry.shared.clearVisible() }
        let client = FakeGarminConnectIQClient()
        let service = GarminIntegrationService(client: client)
        let first = MagicItem(id: "script.first", serverId: "server-1", type: .script, displayText: "First")
        let second = MagicItem(id: "script.second", serverId: "server-1", type: .script, displayText: "Second")
        let initialConfig = customConfig(actionItems: [first])
        var didSync = false

        service.setup(configProvider: { initialConfig })
        service.handle(GarminInboundMessage(
            type: .getSection,
            id: GarminOverviewSectionID.custom("custom-1"),
            correlationId: "s1"
        ))
        client.sentSections.removeAll()

        service.sync(config: customConfig(actionItems: [first, second]), itemInfo: { _ in nil }) { result in
            guard case .success = result else {
                Issue.record("Expected sync success")
                return
            }
            didSync = true
        }

        #expect(didSync)
        #expect(client.sentSections.isEmpty)
        #expect(client.sentSectionNotModifiedIds.isEmpty)
        #expect(client.sentValuesDeltas.isEmpty)
    }

    private func customConfig(actionItems: [MagicItem] = [], statusItems: [MagicItem] = []) -> GarminConfig {
        GarminConfig(
            selectedServerId: "server-1",
            serverConfigs: [.init(serverId: "server-1", customSections: [
                .init(
                    id: "custom-1",
                    title: "Quick",
                    items: statusItems.map { GarminCustomSectionItem(item: $0) }
                        + actionItems.map { GarminCustomSectionItem(item: $0) }
                ),
            ])]
        )
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
            let webhooks = GarminFakeWebhookManager()
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
