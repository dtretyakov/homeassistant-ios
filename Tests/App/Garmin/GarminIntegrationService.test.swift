import Combine
import Foundation
import GRDB
import HAKit
@testable import HomeAssistant
import PromiseKit
@testable import Shared
import Testing
import UserNotifications

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
    var sentSectionNotModifiedIds: [(sectionId: String, pageOffset: Int, correlationId: String?)] = []
    var sentValuesDeltas: [(values: [GarminOverviewValue], revision: Int, isTransient: Bool)] = []
    var sentPrompts: [GarminNotificationPrompt] = []
    var promptSendResult: Swift.Result<Void, GarminIntegrationError> = .success(())
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
        pageOffset: Int,
        correlationId: String?,
        completion: @escaping (Swift.Result<Void, GarminIntegrationError>) -> Void
    ) {
        sentSectionNotModifiedIds.append((sectionId, pageOffset, correlationId))
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

    func sendNotificationPrompt(
        _ prompt: GarminNotificationPrompt,
        completion: @escaping (Swift.Result<Void, GarminIntegrationError>) -> Void
    ) {
        sentPrompts.append(prompt)
        completion(promptSendResult)
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

    override func sendEphemeral(server: Server, request: WebhookRequest) -> Promise<Void> {
        let (promise, seal) = Promise<Void>.pending()
        sendRequestHandler?(.unhandled, server, request, seal)
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

    @Test func notificationPromptSendsOnlyWatchSafeActions() throws {
        try withServer(identifier: "server-1") { server in
            let client = FakeGarminConnectIQClient()
            let service = GarminIntegrationService(client: client)
            let content = notificationContent(actions: [
                ["identifier": "OPEN", "title": "Open"],
                ["identifier": "REPLY", "title": "Reply"],
                [
                    "identifier": "CUSTOM_TEXT",
                    "title": "Custom text",
                    "textInputButtonTitle": "Send",
                    "textInputPlaceholder": "Message",
                ],
                ["identifier": "URI", "title": "Open app", "url": "homeassistant://lovelace"],
                ["identifier": "FOREGROUND", "title": "Foreground", "activationMode": "foreground"],
                ["identifier": "OPEN", "title": "Open duplicate"],
            ])

            service.sendNotificationPrompt(for: content, server: server) { result in
                guard case .success = result else {
                    Issue.record("Expected prompt send to succeed")
                    return
                }
            }

            let prompt = try #require(client.sentPrompts.first)
            #expect(prompt.title == "Open front door?")
            #expect(prompt.body == "Arrived home")
            #expect(prompt.actions.map(\.id) == [
                "OPEN",
                UNNotificationContent.combinedAction(base: "OPEN", appended: "2"),
            ])
            #expect(prompt.actions.map(\.label) == ["Open", "Open duplicate"])
        }
    }

    @Test func notificationPromptAcceptsMobileAppDynamicActionField() throws {
        try withGarminDatabase {
            try withServer(identifier: "server-1") { server in
                let client = FakeGarminConnectIQClient()
                let service = GarminIntegrationService(client: client)
                let content = notificationContent(actions: [
                    [
                        "action": "APARTMENT_DOOR_OPEN",
                        "title": "Open apartment door",
                        "icon": "sfsymbols:key",
                    ],
                ])

                service.sendNotificationPrompt(for: content, server: server) { result in
                    guard case .success = result else {
                        Issue.record("Expected prompt send to succeed")
                        return
                    }
                }

                let prompt = try #require(client.sentPrompts.first)
                #expect(prompt.actions.map(\.id) == ["APARTMENT_DOOR_OPEN"])
                #expect(prompt.actions.map(\.label) == ["Open apartment door"])
            }
        }
    }

    @Test func notificationPromptQueuesWhenWatchIsNotReady() throws {
        try withGarminDatabase {
            try withServer(identifier: "server-1") { server in
                let client = FakeGarminConnectIQClient()
                client.state = .deviceUnavailable
                let service = GarminIntegrationService(client: client)
                let content = notificationContent(actions: [
                    ["identifier": "OPEN", "title": "Open"],
                ])
                var promptResult: Swift.Result<Void, GarminIntegrationError>?

                service.sendNotificationPrompt(for: content, server: server) { result in
                    promptResult = result
                }

                guard case .success = promptResult else {
                    Issue.record("Expected prompt to enqueue while watch is unavailable")
                    return
                }
                #expect(client.sentPrompts.isEmpty)
                let queued = try #require(try Current.database().read { db in
                    try GarminPromptOutboxRecord.fetchAll(db).first?.pendingPrompt
                })
                #expect(queued.prompt.title == "Open front door?")
            }
        }
    }

    @Test func retryableNotificationPromptFailureKeepsPromptPending() throws {
        try withGarminDatabase {
            try withServer(identifier: "server-1") { server in
                let client = FakeGarminConnectIQClient()
                client.promptSendResult = .failure(.watchUnavailable)
                let service = GarminIntegrationService(client: client)
                let content = notificationContent(actions: [
                    ["identifier": "OPEN", "title": "Open"],
                ])
                var promptResult: Swift.Result<Void, GarminIntegrationError>?

                service.sendNotificationPrompt(for: content, server: server) { result in
                    promptResult = result
                }

                guard case .success = promptResult else {
                    Issue.record("Expected retryable prompt send failure to stay queued")
                    return
                }
                let promptId = try #require(client.sentPrompts.first?.id)
                let queued = try #require(try GarminPromptOutbox.pendingPrompt(promptId: promptId))
                #expect(queued.prompt.actions.map(\.id) == ["OPEN"])
            }
        }
    }

    @Test func successfulNotificationPromptSendDoesNotRemainDueForFlush() throws {
        try withGarminDatabase {
            try withServer(identifier: "server-1") { server in
                let client = FakeGarminConnectIQClient()
                let service = GarminIntegrationService(client: client)
                let content = notificationContent(actions: [
                    ["identifier": "OPEN", "title": "Open"],
                ])
                var promptResult: Swift.Result<Void, GarminIntegrationError>?

                service.sendNotificationPrompt(for: content, server: server) { result in
                    promptResult = result
                }

                guard case .success = promptResult else {
                    Issue.record("Expected prompt send to succeed")
                    return
                }
                let promptId = try #require(client.sentPrompts.first?.id)
                #expect(try GarminPromptOutbox.pendingPrompt(promptId: promptId) != nil)
                #expect(try GarminPromptOutbox.pendingPrompts().isEmpty)
            }
        }
    }

    @Test func promptResponseAfterRestartUsesOutboxActionContext() async throws {
        try await withGarminDatabaseAsync {
            try await withWebhookCaptureAsync { capturedRequests in
                let client = FakeGarminConnectIQClient()
                let service = GarminIntegrationService(client: client)
                let server = try #require(Current.servers.server(forServerIdentifier: "server-1"))
                let content = notificationContent(actions: [
                    ["identifier": "OPEN", "title": "Open"],
                ])

                service.sendNotificationPrompt(for: content, server: server) { _ in }
                let prompt = try #require(client.sentPrompts.first)
                let restartedService = GarminIntegrationService(client: client)
                restartedService.handle(
                    GarminInboundMessage(
                        type: .promptResponse,
                        id: prompt.id,
                        correlationId: "c1",
                        actionId: "OPEN"
                    ),
                    config: GarminConfig()
                ) { _ in }

                try await waitUntil {
                    capturedRequests().contains { request in
                        guard let data = request.data as? [String: Any] else { return false }
                        return data["event_type"] as? String == "mobile_app_notification_action"
                    }
                }
                let storedPrompt = try GarminPromptOutbox.pendingPrompt(promptId: prompt.id)
                #expect(storedPrompt == nil)
            }
        }
    }

    @Test func notificationPromptTruncatesWatchVisibleText() throws {
        try withServer(identifier: "server-1") { server in
            let client = FakeGarminConnectIQClient()
            let service = GarminIntegrationService(client: client)
            let content = notificationContent(actions: [
                ["identifier": "OPEN", "title": String(repeating: "A", count: 60)],
            ])
            let mutableContent = try #require(content as? UNMutableNotificationContent)
            mutableContent.title = String(repeating: "T", count: 120)
            mutableContent.body = String(repeating: "B", count: 240)

            service.sendNotificationPrompt(for: mutableContent, server: server) { _ in }

            let prompt = try #require(client.sentPrompts.first)
            #expect(prompt.title.count == 80)
            #expect(prompt.title.hasSuffix("..."))
            #expect(prompt.body?.count == 180)
            #expect(prompt.body?.hasSuffix("...") == true)
            #expect(prompt.actions.first?.label.count == 40)
            #expect(prompt.actions.first?.label.hasSuffix("...") == true)
        }
    }

    @Test func promptResponseFiresNotificationActionEventWithOriginalActionData() async throws {
        try await withWebhookCaptureAsync { capturedRequests in
            let client = FakeGarminConnectIQClient()
            let service = GarminIntegrationService(client: client)
            let server = try #require(Current.servers.server(forServerIdentifier: "server-1"))
            let content = notificationContent(actions: [
                ["identifier": "OPEN", "title": "Open"],
            ])

            service.sendNotificationPrompt(for: content, server: server) { _ in }
            let prompt = try #require(client.sentPrompts.first)
            service.handle(
                GarminInboundMessage(
                    type: .promptResponse,
                    id: prompt.id,
                    correlationId: "c1",
                    actionId: "OPEN"
                ),
                config: GarminConfig()
            ) { _ in }

            try await waitUntil {
                capturedRequests().contains { request in
                    guard let data = request.data as? [String: Any] else { return false }
                    return data["event_type"] as? String == "mobile_app_notification_action"
                }
            }
            let mobileAppRequest = try #require(capturedRequests().first { request in
                guard let data = request.data as? [String: Any] else { return false }
                return data["event_type"] as? String == "mobile_app_notification_action"
            })
            let data = try #require(mobileAppRequest.data as? [String: Any])
            let eventData = try #require(data["event_data"] as? [String: Any])
            let actionData = try #require(eventData["action_data"] as? [String: String])
            #expect(eventData["action"] as? String == "OPEN")
            #expect(actionData["door"] == "front")
        }
    }

    @Test func duplicatePromptResponseUsesOriginalActionIdentifier() async throws {
        try await withWebhookCaptureAsync { capturedRequests in
            let client = FakeGarminConnectIQClient()
            let service = GarminIntegrationService(client: client)
            let server = try #require(Current.servers.server(forServerIdentifier: "server-1"))
            let content = notificationContent(actions: [
                ["identifier": "OPEN", "title": "Open"],
                ["identifier": "OPEN", "title": "Open duplicate"],
            ])

            service.sendNotificationPrompt(for: content, server: server) { _ in }
            let prompt = try #require(client.sentPrompts.first)
            let duplicateId = try #require(prompt.actions.last?.id)
            service.handle(
                GarminInboundMessage(
                    type: .promptResponse,
                    id: prompt.id,
                    correlationId: "c1",
                    actionId: duplicateId
                ),
                config: GarminConfig()
            ) { _ in }

            try await waitUntil {
                capturedRequests().contains { request in
                    guard let data = request.data as? [String: Any] else { return false }
                    return data["event_type"] as? String == "mobile_app_notification_action"
                }
            }
            let mobileAppRequest = try #require(capturedRequests().first { request in
                guard let data = request.data as? [String: Any] else { return false }
                return data["event_type"] as? String == "mobile_app_notification_action"
            })
            let data = try #require(mobileAppRequest.data as? [String: Any])
            let eventData = try #require(data["event_data"] as? [String: Any])
            #expect(eventData["action"] as? String == "OPEN")
        }
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
        #expect(client.sentSectionNotModifiedIds.first?.pageOffset == 0)
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

    @Test func getSectionSendsFreshValuesWithoutPhoneCacheDelta() throws {
        defer { GarminOverviewVisibleEntityRegistry.shared.clearVisible() }
        let client = FakeGarminConnectIQClient()
        let item = MagicItem(
            id: "sensor.temperature",
            serverId: "server-1",
            type: .entity,
            displayText: "Temperature"
        )
        let freshSnapshot = GarminStatusSnapshot(statuses: [
            .init(id: GarminConfig.opaqueItemId(for: item), label: "Temperature", value: "21 C"),
        ])
        var requestedCacheModes: [Bool] = []
        let service = GarminIntegrationService(client: client)
        service.setup(
            configProvider: { customConfig(statusItems: [item]) },
            statusSnapshotProvider: { _, _, cacheOnly, completion in
                #expect(client.sentSections.count == 1)
                requestedCacheModes.append(cacheOnly)
                completion(.success(freshSnapshot))
            }
        )

        service.handle(GarminInboundMessage(
            type: .getSection,
            id: GarminOverviewSectionID.custom("custom-1"),
            correlationId: "s1"
        ))

        #expect(client.sentSections.first?.section.values.isEmpty == true)
        #expect(requestedCacheModes == [false])
        #expect(client.sentValuesDeltas.map(\.values) == [
            [GarminOverviewValue(id: GarminConfig.opaqueItemId(for: item), value: "21 C")],
        ])
    }

    @Test func getSectionSendsSingleFreshValuesDelta() throws {
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
        var requestedCacheModes: [Bool] = []
        let service = GarminIntegrationService(client: client)
        service.setup(
            configProvider: { customConfig(statusItems: [item]) },
            statusSnapshotProvider: { _, _, cacheOnly, completion in
                requestedCacheModes.append(cacheOnly)
                completion(.success(snapshot))
            }
        )

        service.handle(GarminInboundMessage(
            type: .getSection,
            id: GarminOverviewSectionID.custom("custom-1"),
            correlationId: "s1"
        ))

        #expect(client.sentSections.first?.section.values.isEmpty == true)
        #expect(requestedCacheModes == [false])
        #expect(client.sentValuesDeltas.map(\.values) == [
            [GarminOverviewValue(id: GarminConfig.opaqueItemId(for: item), value: "20 C")],
        ])
    }

    @Test func getSectionUsesRequestedPageForSnapshotSameAndVisibleValues() throws {
        defer { GarminOverviewVisibleEntityRegistry.shared.clearVisible() }
        let client = FakeGarminConnectIQClient()
        let items = (0..<20).map { index in
            MagicItem(id: "sensor.item_\(index)", serverId: "server-1", type: .entity, displayText: "Item \(index)")
        }
        let config = customConfig(statusItems: items)
        let source = GarminHomeOverviewSource(entityProvider: { [] }, areaProvider: { _ in [] })
        var requestedItemIds: [[String]] = []
        let service = GarminIntegrationService(
            client: client,
            overviewSourceProvider: { source }
        )
        service.setup(
            configProvider: { config },
            statusSnapshotProvider: { _, requestedItems, cacheOnly, completion in
                #expect(cacheOnly == false)
                requestedItemIds.append(requestedItems.map(\.id))
                completion(.success(GarminStatusSnapshot(statuses: requestedItems.map {
                    .init(id: GarminConfig.opaqueItemId(for: $0), label: $0.displayText ?? $0.id, value: "ok")
                })))
            }
        )

        service.handle(GarminInboundMessage(
            type: .getSection,
            id: GarminOverviewSectionID.custom("custom-1"),
            correlationId: "s2",
            pageOffset: 15,
            pageLimit: 15
        ))

        let section = try #require(client.sentSections.first?.section)
        #expect(section.pageOffset == 15)
        #expect(section.pageLimit == 15)
        #expect(section.previousOffset == 0)
        #expect(section.nextOffset == nil)
        #expect(section.items.map(\.label) == (15..<20).map { "Item \($0)" })
        #expect(requestedItemIds == [(15..<20).map { "sensor.item_\($0)" }])
        #expect(client.sentValuesDeltas.first?.values.map(\.id) == (15..<20).map {
            GarminConfig.opaqueItemId(for: items[$0])
        })
    }

    @Test func getSectionReducesPageSizeWhenSnapshotPayloadWouldBeTooLarge() throws {
        let client = FakeGarminConnectIQClient()
        let longLabel = String(repeating: "A", count: 900)
        let items = (0..<8).map { index in
            MagicItem(id: "sensor.large_\(index)", serverId: "server-1", type: .entity, displayText: "\(index)-\(longLabel)")
        }
        let service = GarminIntegrationService(
            client: client,
            overviewSourceProvider: { GarminHomeOverviewSource(entityProvider: { [] }, areaProvider: { _ in [] }) }
        )

        service.handle(
            GarminInboundMessage(
                type: .getSection,
                id: GarminOverviewSectionID.custom("custom-1"),
                correlationId: "s-large",
                pageOffset: 0,
                pageLimit: 16
            ),
            config: customConfig(statusItems: items)
        ) { _ in }

        let section = try #require(client.sentSections.first?.section)
        let byteCount = try GarminPayloadCodec.encodedByteCount(GarminOutboundMessage(type: .sectionSnapshot, section: section))
        #expect(section.items.count > 0)
        #expect(section.items.count < items.count)
        #expect(byteCount <= GarminPayloadLimits.outboundMessageBytes)
    }

    @Test func getSectionSameIsPageSpecific() throws {
        defer { GarminOverviewVisibleEntityRegistry.shared.clearVisible() }
        let client = FakeGarminConnectIQClient()
        let items = (0..<20).map { index in
            MagicItem(id: "sensor.item_\(index)", serverId: "server-1", type: .entity, displayText: "Item \(index)")
        }
        let config = customConfig(statusItems: items)
        let source = GarminHomeOverviewSource(entityProvider: { [] }, areaProvider: { _ in [] })
        let page = try #require(try source.section(
            id: GarminOverviewSectionID.custom("custom-1"),
            config: config,
            itemInfo: { _ in nil },
            offset: 15,
            limit: 15
        ))
        let service = GarminIntegrationService(
            client: client,
            overviewSourceProvider: { source }
        )
        service.setup(
            configProvider: { config },
            statusSnapshotProvider: { _, _, _, completion in
                completion(.success(GarminStatusSnapshot(statuses: [])))
            }
        )

        service.handle(GarminInboundMessage(
            type: .getSection,
            id: GarminOverviewSectionID.custom("custom-1"),
            etag: page.etag,
            correlationId: "s3",
            pageOffset: 15,
            pageLimit: 15
        ))

        #expect(client.sentSections.isEmpty)
        #expect(client.sentSectionNotModifiedIds.first?.sectionId == GarminOverviewSectionID.custom("custom-1"))
        #expect(client.sentSectionNotModifiedIds.first?.pageOffset == 15)
    }

    @Test func missingActionFailsWithoutExecuting() throws {
        let client = FakeGarminConnectIQClient()
        var didExecute = false
        let service = GarminIntegrationService(client: client) { _, _, _, completion in
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

    @Test func getRootPrefetchesFavoritesBeforeBuildingSection() async throws {
        GarminHomeFavoritesCache.shared.clear()
        defer { GarminHomeFavoritesCache.shared.clear() }
        try await withServerAsync(identifier: "server-1") { server in
            let client = FakeGarminConnectIQClient()
            let api = HomeAssistantAPI(server: server)
            let connection = HAMockConnection()
            connection.automaticallyTransitionToConnecting = false
            connection.callbackQueue = DispatchQueue(label: "GarminSummarySnapshotTest")
            api.connection = connection
            Current.setCachedApi(api, for: server.identifier)

            let favorite = HAAppEntity(
                id: "server-1-light.kitchen",
                entityId: "light.kitchen",
                serverId: "server-1",
                domain: "light",
                name: "Kitchen",
                icon: nil,
                rawDeviceClass: nil
            )
            try saveAppEntities([favorite])
            let source = GarminHomeOverviewSource(
                entityProvider: { [favorite] },
                areaProvider: { _ in [] }
            )
            let service = GarminIntegrationService(
                client: client,
                overviewSourceProvider: { source },
                delayedWorkScheduler: { _, _ in }
            )
            service.setup(configProvider: { GarminConfig(selectedServerId: "server-1") })

            service.handle(GarminInboundMessage(type: .getSection, id: GarminOverviewSectionID.root, correlationId: "fav-root"))
            try await waitUntil { !connection.pendingRequests.isEmpty }

            let request = try #require(connection.pendingRequests.first)
            #expect(request.request.type == .webSocket("frontend/get_system_data"))
            request.completion(.success(homeSystemDataResponse(favorites: ["light.kitchen"], hideSuggested: true)))
            try await waitUntil { !client.sentSections.isEmpty }

            #expect(client.sentSections.first?.section.items.first?.id == GarminOverviewSectionID.favorites)
        }
    }

    @Test func getRootFetchesPredictionAfterFrontendHomeDefaults() async throws {
        GarminHomeFavoritesCache.shared.clear()
        defer { GarminHomeFavoritesCache.shared.clear() }
        try await withServerAsync(identifier: "server-1") { server in
            let client = FakeGarminConnectIQClient()
            let api = HomeAssistantAPI(server: server)
            let connection = HAMockConnection()
            connection.automaticallyTransitionToConnecting = false
            connection.callbackQueue = DispatchQueue(label: "GarminSummaryConcurrentSnapshotTest")
            api.connection = connection
            Current.setCachedApi(api, for: server.identifier)

            let favorite = HAAppEntity(
                id: "server-1-light.kitchen",
                entityId: "light.kitchen",
                serverId: "server-1",
                domain: "light",
                name: "Kitchen",
                icon: nil,
                rawDeviceClass: nil
            )
            try saveAppEntities([favorite])
            let source = GarminHomeOverviewSource(
                entityProvider: { [favorite] },
                areaProvider: { _ in [] }
            )
            let service = GarminIntegrationService(
                client: client,
                overviewSourceProvider: { source },
                delayedWorkScheduler: { _, _ in }
            )
            service.setup(configProvider: { GarminConfig(selectedServerId: "server-1") })

            service.handle(GarminInboundMessage(type: .getSection, id: GarminOverviewSectionID.root, correlationId: "fav-root"))
            try await waitUntil { connection.pendingRequests.count >= 1 }
            #expect(connection.pendingRequests[0].request.type == .webSocket("frontend/get_system_data"))
            connection.pendingRequests[0].completion(.success(homeSystemDataResponse(favorites: [], hideSuggested: false)))
            try await waitUntil { connection.pendingRequests.count >= 2 }

            let predictionRequest = connection.pendingRequests[1]
            #expect(predictionRequest.request.type == .webSocket("usage_prediction/common_control"))
            predictionRequest.completion(.success(.dictionary(["entities": ["light.kitchen"]])))
            try await waitUntil { !client.sentSections.isEmpty }

            #expect(client.sentSections.first?.section.items.first?.id == GarminOverviewSectionID.favorites)
        }
    }

    @Test func getRootUsesFreshFavoritesCacheWithoutRepeatedWSRequests() async throws {
        GarminHomeFavoritesCache.shared.clear()
        defer { GarminHomeFavoritesCache.shared.clear() }
        try await withServerAsync(identifier: "server-1") { server in
            let client = FakeGarminConnectIQClient()
            let api = HomeAssistantAPI(server: server)
            let connection = HAMockConnection()
            api.connection = connection
            Current.setCachedApi(api, for: server.identifier)

            let favorite = HAAppEntity(
                id: "server-1-light.kitchen",
                entityId: "light.kitchen",
                serverId: "server-1",
                domain: "light",
                name: "Kitchen",
                icon: nil,
                rawDeviceClass: nil
            )
            try saveAppEntities([favorite])
            let source = GarminHomeOverviewSource(
                entityProvider: { [favorite] },
                areaProvider: { _ in [] }
            )
            let service = GarminIntegrationService(
                client: client,
                overviewSourceProvider: { source },
                delayedWorkScheduler: { _, _ in }
            )
            service.setup(configProvider: { GarminConfig(selectedServerId: "server-1") })

            service.handle(GarminInboundMessage(type: .getSection, id: GarminOverviewSectionID.root, correlationId: "first"))
            try await waitUntil { !connection.pendingRequests.isEmpty }
            connection.pendingRequests[0].completion(.success(homeSystemDataResponse(favorites: ["light.kitchen"], hideSuggested: true)))
            try await waitUntil { client.sentSections.count == 1 }

            service.handle(GarminInboundMessage(type: .getSection, id: GarminOverviewSectionID.favorites, correlationId: "second"))
            try await waitUntil { client.sentSections.count == 2 }

            #expect(connection.pendingRequests.count == 1)
        }
    }

    @Test func concurrentRootAndFavoritesRequestsShareFavoritesPrefetch() async throws {
        GarminHomeFavoritesCache.shared.clear()
        defer { GarminHomeFavoritesCache.shared.clear() }
        try await withServerAsync(identifier: "server-1") { server in
            let client = FakeGarminConnectIQClient()
            let api = HomeAssistantAPI(server: server)
            let connection = HAMockConnection()
            api.connection = connection
            Current.setCachedApi(api, for: server.identifier)

            let favorite = HAAppEntity(
                id: "server-1-light.kitchen",
                entityId: "light.kitchen",
                serverId: "server-1",
                domain: "light",
                name: "Kitchen",
                icon: nil,
                rawDeviceClass: nil
            )
            try saveAppEntities([favorite])
            let source = GarminHomeOverviewSource(
                entityProvider: { [favorite] },
                areaProvider: { _ in [] }
            )
            let service = GarminIntegrationService(
                client: client,
                overviewSourceProvider: { source },
                delayedWorkScheduler: { _, _ in }
            )
            service.setup(configProvider: { GarminConfig(selectedServerId: "server-1") })

            service.handle(GarminInboundMessage(type: .getSection, id: GarminOverviewSectionID.root, correlationId: "root"))
            try await waitUntil { connection.pendingRequests.count == 1 }
            service.handle(GarminInboundMessage(type: .getSection, id: GarminOverviewSectionID.favorites, correlationId: "fav"))
            try await Task.sleep(nanoseconds: 1_000_000)

            #expect(connection.pendingRequests.count == 1)

            connection.pendingRequests[0].completion(.success(homeSystemDataResponse(favorites: ["light.kitchen"], hideSuggested: true)))
            try await waitUntil { client.sentSections.count == 2 }

            #expect(connection.pendingRequests.count == 1)
            #expect(client.sentSections.map(\.section.id) == [
                GarminOverviewSectionID.root,
                GarminOverviewSectionID.favorites,
            ])
        }
    }

    @Test func getRootCachesEmptyFavoritesResultWithoutRepeatedWSRequests() async throws {
        GarminHomeFavoritesCache.shared.clear()
        defer { GarminHomeFavoritesCache.shared.clear() }
        try await withServerAsync(identifier: "server-1") { server in
            let client = FakeGarminConnectIQClient()
            let api = HomeAssistantAPI(server: server)
            let connection = HAMockConnection()
            api.connection = connection
            Current.setCachedApi(api, for: server.identifier)
            let source = GarminHomeOverviewSource(entityProvider: { [] }, areaProvider: { _ in [] })
            let service = GarminIntegrationService(
                client: client,
                overviewSourceProvider: { source },
                delayedWorkScheduler: { _, _ in }
            )
            service.setup(configProvider: { GarminConfig(selectedServerId: "server-1") })

            service.handle(GarminInboundMessage(type: .getSection, id: GarminOverviewSectionID.root, correlationId: "first"))
            try await waitUntil { connection.pendingRequests.count >= 1 }
            connection.pendingRequests[0].completion(.success(homeSystemDataResponse(favorites: [], hideSuggested: false)))
            try await waitUntil { connection.pendingRequests.count >= 2 }
            connection.pendingRequests[1].completion(.success(.dictionary(["entities": []])))
            try await waitUntil { client.sentSections.count == 1 }

            service.handle(GarminInboundMessage(type: .getSection, id: GarminOverviewSectionID.root, correlationId: "second"))
            try await waitUntil { client.sentSections.count == 2 }

            #expect(connection.pendingRequests.count == 2)
            #expect(!client.sentSections.last!.section.items.map(\.id).contains(GarminOverviewSectionID.favorites))
        }
    }

    @Test func getFavoritesSectionRefreshesVisibleValues() async throws {
        GarminHomeFavoritesCache.shared.clear()
        defer {
            GarminHomeFavoritesCache.shared.clear()
            GarminOverviewVisibleEntityRegistry.shared.clearVisible()
        }
        try await withServerAsync(identifier: "server-1") { server in
            let client = FakeGarminConnectIQClient()
            let api = HomeAssistantAPI(server: server)
            let connection = HAMockConnection()
            api.connection = connection
            Current.setCachedApi(api, for: server.identifier)

            let favorite = HAAppEntity(
                id: "server-1-light.kitchen",
                entityId: "light.kitchen",
                serverId: "server-1",
                domain: "light",
                name: "Kitchen",
                icon: nil,
                rawDeviceClass: nil
            )
            try saveAppEntities([favorite])
            let favoriteItem = MagicItem(id: favorite.entityId, serverId: favorite.serverId, type: .entity)
            let source = GarminHomeOverviewSource(
                entityProvider: { [favorite] },
                areaProvider: { _ in [] }
            )
            let service = GarminIntegrationService(
                client: client,
                overviewSourceProvider: { source },
                delayedWorkScheduler: { _, _ in }
            )
            service.setup(
                configProvider: { GarminConfig(selectedServerId: "server-1") },
                statusSnapshotProvider: { _, items, cacheOnly, completion in
                    #expect(!cacheOnly)
                    #expect(items.map(\.id) == [favorite.entityId])
                    completion(.success(GarminStatusSnapshot(statuses: [
                        .init(id: GarminConfig.opaqueItemId(for: favoriteItem), label: "Kitchen", value: "on"),
                    ])))
                }
            )

            service.handle(GarminInboundMessage(type: .getSection, id: GarminOverviewSectionID.favorites, correlationId: "fav"))
            try await waitUntil { !connection.pendingRequests.isEmpty }
            connection.pendingRequests.first?.completion(.success(homeSystemDataResponse(favorites: ["light.kitchen"], hideSuggested: true)))
            try await waitUntil { !client.sentValuesDeltas.isEmpty }

            #expect(client.sentSections.first?.section.items.map(\.id) == [
                GarminConfig.opaqueEntityId(serverId: favorite.serverId, entityId: favorite.entityId),
            ])
            #expect(client.sentValuesDeltas.first?.values == [
                GarminOverviewValue(id: GarminConfig.opaqueItemId(for: favoriteItem), value: "on"),
            ])
        }
    }

    @Test func getSummarySectionBuildsDetailFromRawStateSnapshotWithoutDisplayValueProvider() throws {
        defer { GarminOverviewVisibleEntityRegistry.shared.clearVisible() }
        GarminHomeSummaryStateCache.shared.clear()
        defer { GarminHomeSummaryStateCache.shared.clear() }

        let client = FakeGarminConnectIQClient()
        let kitchen = HAAppEntity(
            id: "server-1-light.kitchen",
            entityId: "light.kitchen",
            serverId: "server-1",
            domain: "light",
            name: "Kitchen",
            icon: nil,
            rawDeviceClass: nil
        )
        let hall = HAAppEntity(
            id: "server-1-light.hall",
            entityId: "light.hall",
            serverId: "server-1",
            domain: "light",
            name: "Hall",
            icon: nil,
            rawDeviceClass: nil
        )
        GarminHomeSummaryStateCache.shared.setStates([
            .init(entityId: kitchen.entityId, state: "on"),
            .init(entityId: hall.entityId, state: "off"),
        ], serverId: "server-1")
        let provider = GarminHomeSummaryProvider(
            registryProvider: { _ in [] },
            stateProvider: { _ in [
                .init(entityId: kitchen.entityId, state: "on"),
                .init(entityId: hall.entityId, state: "off"),
            ] }
        )
        let source = GarminHomeOverviewSource(
            entityProvider: { [kitchen, hall] },
            areaProvider: { _ in [] },
            summaryProvider: provider
        )
        let service = GarminIntegrationService(
            client: client,
            overviewSourceProvider: { source }
        )
        service.setup(
            configProvider: { GarminConfig(selectedServerId: "server-1") },
            statusSnapshotProvider: { _, items, cacheOnly, completion in
                Issue.record("Summary details should use prefetched raw state values instead of per-entity status refresh for \(items), cacheOnly: \(cacheOnly)")
                completion(.failure(.homeAssistantUnavailable))
            }
        )

        service.handle(GarminInboundMessage(
            type: .getSection,
            id: GarminOverviewSectionID.summary("light"),
            correlationId: "s-light"
        ))

        #expect(client.sentSections.last?.section.items.map(\.label) == ["Kitchen", "Hall"])
        #expect(client.sentSections.last?.section.values == [
            GarminOverviewValue(
                id: GarminConfig.opaqueEntityId(serverId: kitchen.serverId, entityId: kitchen.entityId),
                value: "On"
            ),
            GarminOverviewValue(
                id: GarminConfig.opaqueEntityId(serverId: hall.serverId, entityId: hall.entityId),
                value: "Off"
            ),
        ])
        #expect(client.sentValuesDeltas.isEmpty)
    }

    @Test func getSummariesWaitsForRawStateSnapshotBeforeBuildingSection() async throws {
        GarminHomeSummaryStateCache.shared.clear()
        defer { GarminHomeSummaryStateCache.shared.clear() }

        try await withServerAsync(identifier: "server-1") { server in
            let client = FakeGarminConnectIQClient()
            let api = HomeAssistantAPI(server: server)
            let connection = HAMockConnection()
            connection.automaticallyTransitionToConnecting = false
            connection.callbackQueue = DispatchQueue(label: "GarminSummarySnapshotTest")
            api.connection = connection
            Current.setCachedApi(api, for: server.identifier)

            let source = GarminHomeOverviewSource(
                entityProvider: { [] },
                areaProvider: { _ in [] }
            )
            let service = GarminIntegrationService(
                client: client,
                overviewSourceProvider: { source },
                delayedWorkScheduler: { _, _ in }
            )
            service.setup(configProvider: { GarminConfig(selectedServerId: "server-1") })

            service.handle(GarminInboundMessage(
                type: .getSection,
                id: GarminOverviewSectionID.summaries,
                correlationId: "summaries"
            ))

            try await waitUntil { !connection.pendingSubscriptions.isEmpty }
            #expect(client.sentSections.isEmpty)
            #expect(connection.pendingRequests.isEmpty)

            for subscription in connection.pendingSubscriptions {
                subscription.handler(subscription.cancellable, compressedStatesData([
                    "light.kitchen": ("on", ["friendly_name": "Kitchen"]),
                    "media_player.living_room": ("idle", ["friendly_name": "Living room"]),
                ]))
            }

            try await waitUntil { client.sentSections.count == 1 }
            #expect(client.sentSections.first?.section.items.map(\.id) == [
                GarminOverviewSectionID.summary("light"),
                GarminOverviewSectionID.summary("media_players"),
            ])
            #expect(client.sentSections.first?.section.values == [
                .init(id: GarminOverviewSectionID.summary("light"), value: "1 on"),
                .init(id: GarminOverviewSectionID.summary("media_players"), value: "No media playing"),
            ])
        }
    }

    @Test func concurrentSummaryRequestsShareOneRawStateSnapshotFetch() async throws {
        GarminHomeSummaryStateCache.shared.clear()
        defer { GarminHomeSummaryStateCache.shared.clear() }

        try await withServerAsync(identifier: "server-1") { server in
            let client = FakeGarminConnectIQClient()
            let api = HomeAssistantAPI(server: server)
            let connection = HAMockConnection()
            connection.automaticallyTransitionToConnecting = false
            connection.callbackQueue = DispatchQueue(label: "GarminSummaryConcurrentSnapshotTest")
            api.connection = connection
            Current.setCachedApi(api, for: server.identifier)

            let source = GarminHomeOverviewSource(
                entityProvider: { [] },
                areaProvider: { _ in [] }
            )
            let service = GarminIntegrationService(
                client: client,
                overviewSourceProvider: { source },
                delayedWorkScheduler: { _, _ in }
            )
            service.setup(configProvider: { GarminConfig(selectedServerId: "server-1") })

            service.handle(GarminInboundMessage(type: .getSection, id: GarminOverviewSectionID.summaries, correlationId: "sum"))
            service.handle(GarminInboundMessage(type: .getSection, id: GarminOverviewSectionID.summary("light"), correlationId: "light"))

            try await waitUntil { !connection.pendingSubscriptions.isEmpty }
            #expect(client.sentSections.isEmpty)
            #expect(connection.pendingRequests.isEmpty)

            for subscription in connection.pendingSubscriptions {
                subscription.handler(subscription.cancellable, compressedStatesData([
                    "light.kitchen": ("on", ["friendly_name": "Kitchen"]),
                ]))
            }

            try await waitUntil { client.sentSections.count == 2 }
            #expect(connection.pendingRequests.isEmpty)
            #expect(client.sentSections.map(\.section.id).sorted() == [
                GarminOverviewSectionID.summaries,
                GarminOverviewSectionID.summary("light"),
            ].sorted())
        }
    }

    @Test func summaryStateCacheCoalescesConcurrentFetchCompletions() {
        let cache = GarminHomeSummaryStateCache()
        defer { cache.clear() }

        var completions: [String] = []
        let firstStarted = cache.beginFetch(serverId: "server-1") { success in
            #expect(success == true)
            completions.append("first")
        }
        let secondStarted = cache.beginFetch(serverId: "server-1") { success in
            #expect(success == true)
            completions.append("second")
        }

        #expect(firstStarted == true)
        #expect(secondStarted == false)
        #expect(completions.isEmpty)

        cache.completeFetch(serverId: "server-1")

        #expect(completions == ["first", "second"])
    }

    @Test func summaryStatePrefetchTimeoutFailsInsteadOfSendingEmptySection() async throws {
        GarminHomeSummaryStateCache.shared.clear()
        defer { GarminHomeSummaryStateCache.shared.clear() }

        try await withServerAsync(identifier: "server-1") { server in
            let client = FakeGarminConnectIQClient()
            let api = HomeAssistantAPI(server: server)
            let connection = HAMockConnection()
            connection.automaticallyTransitionToConnecting = false
            connection.callbackQueue = DispatchQueue(label: "GarminSummaryTimeoutTest")
            api.connection = connection
            Current.setCachedApi(api, for: server.identifier)

            var timeoutWork: (() -> Void)?
            let source = GarminHomeOverviewSource(
                entityProvider: { [] },
                areaProvider: { _ in [] }
            )
            let service = GarminIntegrationService(
                client: client,
                overviewSourceProvider: { source },
                delayedWorkScheduler: { _, work in timeoutWork = work }
            )
            service.setup(configProvider: { GarminConfig(selectedServerId: "server-1") })

            service.handle(GarminInboundMessage(
                type: .getSection,
                id: GarminOverviewSectionID.summaries,
                correlationId: "summaries-timeout"
            ))

            try await waitUntil { timeoutWork != nil }
            #expect(client.sentSections.isEmpty)

            timeoutWork?()

            try await waitUntil { client.sentResults.count == 1 }
            #expect(client.sentResults.first?.state == .failed)
            #expect(client.sentResults.first?.error == .homeAssistantUnavailable)
            #expect(client.sentSections.isEmpty)
        }
    }

    @Test func nonActionCapableItemFailsAsMissingActionWithoutExecuting() throws {
        let client = FakeGarminConnectIQClient()
        var didExecute = false
        let item = MagicItem(id: "climate.hallway", serverId: "server-1", type: .entity)
        let config = customConfig(actionItems: [item])
        let service = GarminIntegrationService(client: client) { _, _, _, completion in
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
            let service = GarminIntegrationService(client: client) { _, _, _, completion in
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
            let service = GarminIntegrationService(client: client) { _, _, _, completion in
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
            let service = GarminIntegrationService(client: client) { _, _, _, completion in
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

    @Test func executorSuccessRefreshesAffectedStatusItemAfterResult() throws {
        try withServer(identifier: "server-1") { _ in
            let client = FakeGarminConnectIQClient()
            let item = MagicItem(id: "light.kitchen", serverId: "server-1", type: .entity)
            let itemId = GarminConfig.opaqueItemId(for: item)
            let config = customConfig(actionItems: [item])
            var requestedItemIds: [[String]] = []
            var requestedCacheModes: [Bool] = []
            let service = GarminIntegrationService(
                client: client,
                actionExecutor: { _, _, _, completion in
                    completion(.success(()))
                },
                delayedWorkScheduler: { _, work in
                    work()
                }
            )
            service.setup(
                configProvider: { config },
                statusSnapshotProvider: { _, items, cacheOnly, completion in
                    requestedItemIds.append(items.map(\.id))
                    requestedCacheModes.append(cacheOnly)
                    completion(.success(GarminStatusSnapshot(statuses: [
                        .init(id: itemId, label: "Kitchen", value: "On"),
                    ])))
                }
            )
            let message = GarminInboundMessage(
                type: .callAction,
                id: itemId,
                correlationId: "c1"
            )

            service.handle(message, config: config) { _ in }

            #expect(client.sentResults.first?.state == .success)
            #expect(requestedItemIds == [[item.id], [item.id]])
            #expect(requestedCacheModes == [false, false])
            #expect(client.sentValuesDeltas.map(\.values) == [
                [GarminOverviewValue(id: itemId, value: "On")],
                [GarminOverviewValue(id: itemId, value: "On")],
            ])
        }
    }

    @Test func executorSuccessDoesNotRefreshActionOnlyItem() throws {
        try withServer(identifier: "server-1") { _ in
            let client = FakeGarminConnectIQClient()
            let item = MagicItem(id: "script.good_night", serverId: "server-1", type: .script)
            let config = customConfig(actionItems: [item])
            let service = GarminIntegrationService(
                client: client,
                actionExecutor: { _, _, _, completion in
                    completion(.success(()))
                },
                delayedWorkScheduler: { _, work in
                    work()
                }
            )
            service.setup(
                configProvider: { config },
                statusSnapshotProvider: { _, _, _, completion in
                    Issue.record("Action-only script should not request a status snapshot")
                    completion(.failure(.homeAssistantUnavailable))
                }
            )

            service.handle(GarminInboundMessage(
                type: .callAction,
                id: GarminConfig.opaqueItemId(for: item),
                correlationId: "c1"
            ), config: config) { _ in }

            #expect(client.sentResults.first?.state == .success)
            #expect(client.sentValuesDeltas.isEmpty)
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

    @Test func lightEntityActionUsesDesiredStateService() throws {
        try withWebhookCapture { capturedRequests in
            let client = FakeGarminConnectIQClient()
            let item = MagicItem(id: "light.kitchen", serverId: "server-1", type: .entity)
            let config = customConfig(actionItems: [item])
            let service = GarminIntegrationService(client: client)
            let message = GarminInboundMessage(
                type: .callAction,
                id: GarminConfig.opaqueItemId(for: item),
                correlationId: "c1",
                actionId: "turn_on"
            )

            service.handle(message, config: config) { _ in }

            let request = try #require(capturedRequests().first)
            let data = try #require(request.data as? [String: Any])
            let serviceData = try #require(data["service_data"] as? [String: Any])
            #expect(request.type == "call_service")
            #expect(data["domain"] as? String == "light")
            #expect(data["service"] as? String == "turn_on")
            #expect(serviceData["entity_id"] as? String == "light.kitchen")
        }
    }

    @Test func coverEntityActionUsesDesiredStateService() throws {
        try withWebhookCapture { capturedRequests in
            let client = FakeGarminConnectIQClient()
            let item = MagicItem(id: "cover.garage", serverId: "server-1", type: .entity)
            let config = customConfig(actionItems: [item])
            let service = GarminIntegrationService(client: client)
            let message = GarminInboundMessage(
                type: .callAction,
                id: GarminConfig.opaqueItemId(for: item),
                correlationId: "c1",
                actionId: "close_cover"
            )

            service.handle(message, config: config) { _ in }

            let request = try #require(capturedRequests().first)
            let data = try #require(request.data as? [String: Any])
            let serviceData = try #require(data["service_data"] as? [String: Any])
            #expect(request.type == "call_service")
            #expect(data["domain"] as? String == "cover")
            #expect(data["service"] as? String == "close_cover")
            #expect(serviceData["entity_id"] as? String == "cover.garage")
        }
    }

    @Test func statefulEntityActionWithoutActionIdFailsUnsupported() throws {
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

            #expect(connection.pendingRequests.isEmpty)
            #expect(client.sentResults.first?.state == .failed)
            #expect(client.sentResults.first?.error == .unsupportedAction)
        }
    }

    @Test func mediaPlayerActionsUseIdempotentServices() throws {
        defer { GarminHomeSummaryStateCache.shared.clear(serverId: "server-1") }
        try withWebhookCapture { capturedRequests in
            let client = FakeGarminConnectIQClient()
            let item = MagicItem(id: "media_player.living_room", serverId: "server-1", type: .entity)
            let config = customConfig(actionItems: [item])
            let service = GarminIntegrationService(client: client)

            GarminHomeSummaryStateCache.shared.setStates([
                .init(entityId: item.id, state: "playing", attributes: ["supported_features": 1]),
            ], serverId: "server-1")
            service.handle(GarminInboundMessage(
                type: .callAction,
                id: GarminConfig.opaqueItemId(for: item),
                correlationId: "pause",
                actionId: "media_pause"
            ), config: config) { _ in }
            GarminHomeSummaryStateCache.shared.setStates([
                .init(entityId: item.id, state: "paused", attributes: ["supported_features": 16_384]),
            ], serverId: "server-1")
            service.handle(GarminInboundMessage(
                type: .callAction,
                id: GarminConfig.opaqueItemId(for: item),
                correlationId: "play",
                actionId: "media_play"
            ), config: config) { _ in }

            let requests = capturedRequests()
            #expect(requests.count == 2)
            #expect(requests.compactMap { ($0.data as? [String: Any])?["domain"] as? String } == ["media_player", "media_player"])
            #expect(requests.compactMap { ($0.data as? [String: Any])?["service"] as? String } == ["media_pause", "media_play"])
        }
    }

    @Test func mediaPlayerActionWithoutSupportedFeatureFailsUnsupported() throws {
        defer { GarminHomeSummaryStateCache.shared.clear(serverId: "server-1") }
        try withWebhookCapture { capturedRequests in
            let client = FakeGarminConnectIQClient()
            let item = MagicItem(id: "media_player.living_room", serverId: "server-1", type: .entity)
            let config = customConfig(actionItems: [item])
            let service = GarminIntegrationService(client: client)
            GarminHomeSummaryStateCache.shared.setStates([
                .init(entityId: item.id, state: "paused", attributes: ["supported_features": 0]),
            ], serverId: "server-1")

            service.handle(GarminInboundMessage(
                type: .callAction,
                id: GarminConfig.opaqueItemId(for: item),
                correlationId: "play",
                actionId: "media_play"
            ), config: config) { _ in }

            #expect(capturedRequests().isEmpty)
            #expect(client.sentResults.first?.state == .failed)
            #expect(client.sentResults.first?.error == .unsupportedAction)
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

    private func notificationContent(actions: [[String: Any]]) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Open front door?"
        content.body = "Arrived home"
        content.categoryIdentifier = "DYNAMIC"
        content.userInfo = [
            "actions": actions,
            "homeassistant": ["door": "front"],
            "timeout": 300,
        ]
        return content
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

    private func withGarminDatabase(_ body: () throws -> Void) throws {
        let database = try DatabaseQueue(path: ":memory:")
        try GarminDatabaseSchema.createIfNeeded(database: database)
        let previousDatabase = Current.database
        Current.database = { database }
        defer { Current.database = previousDatabase }

        try body()
    }

    private func withGarminDatabaseAsync(_ body: () async throws -> Void) async throws {
        let database = try DatabaseQueue(path: ":memory:")
        try GarminDatabaseSchema.createIfNeeded(database: database)
        let previousDatabase = Current.database
        Current.database = { database }
        defer { Current.database = previousDatabase }

        try await body()
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

    private func withWebhookCaptureAsync(
        _ body: (() -> [WebhookRequest]) async throws -> Void
    ) async throws {
        try await withServerAsync(identifier: "server-1") { _ in
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

            try await body({ capturedRequests })
        }
    }

    private func withServerAsync(
        identifier: String,
        _ body: (Server) async throws -> Void
    ) async throws {
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

        try await body(server)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async throws {
        let start = Date()
        while !condition() {
            guard Date().timeIntervalSince(start) < timeout else {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func saveAppEntities(_ entities: [HAAppEntity]) throws {
        try Current.database().write { db in
            for entity in entities {
                try entity.insert(db, onConflict: .replace)
            }
        }
    }

    private func homeSystemDataResponse(
        favorites: [String],
        hideSuggested: Bool
    ) -> HAData {
        .dictionary([
            "value": [
                "favorite_entities": favorites,
                "hide_suggested_entities": hideSuggested,
            ],
        ])
    }

    private func compressedStatesData(_ states: [String: (state: String, attributes: [String: Any])]) -> HAData {
        let additions = states.mapValues { value -> [String: Any] in
            [
                "s": value.state,
                "a": value.attributes,
                "lc": "2026-06-06T10:00:00Z",
                "lu": "2026-06-06T10:00:00Z",
                "c": "context-id",
            ]
        }
        return .dictionary([
            "a": additions,
        ])
    }
}
