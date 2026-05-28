import Combine
import GRDB
@testable import HomeAssistant
@testable import Shared
import Testing

@Suite(.serialized)
struct GarminConfigurationViewModelTests {
    @Test func addCustomSectionStoresAndSyncs() throws {
        try withViewModel { viewModel, controller in
            viewModel.addCustomSection()

            #expect(viewModel.config.customSections.count == 1)
            #expect(viewModel.config.customSections.first?.title == "New section")
            let persistedConfig = try GarminConfig.config()
            #expect(persistedConfig?.customSections.count == 1)
            #expect(controller.syncedConfigs.last?.customSections.count == 1)
        }
    }

    @Test func renameMoveAndDeleteCustomSections() throws {
        try withViewModel { viewModel in
            viewModel.addCustomSection()
            viewModel.addCustomSection()
            let firstId = try #require(viewModel.config.customSections.first?.id)
            let secondId = try #require(viewModel.config.customSections.last?.id)

            viewModel.updateCustomSectionTitle(sectionId: firstId, title: "Downstairs")
            viewModel.moveCustomSection(from: IndexSet(integer: 0), to: 2)

            #expect(viewModel.config.customSections.map(\.id) == [secondId, firstId])
            #expect(viewModel.config.customSections.last?.title == "Downstairs")

            viewModel.deleteCustomSection(at: IndexSet(integer: 1))

            #expect(viewModel.config.customSections.map(\.id) == [secondId])
        }
    }

    @Test func addItemsStoresUnifiedCapabilityItemsInTargetSection() throws {
        try withViewModel { viewModel in
            viewModel.addCustomSection()
            let sectionId = try #require(viewModel.config.customSections.first?.id)
            let status = MagicItem(id: "sensor.temperature", serverId: "server-1", type: .entity, displayText: "Temperature")
            let action = MagicItem(
                id: "scene.movie",
                serverId: "server-1",
                type: .scene,
                customization: nil,
                displayText: "Movie"
            )

            viewModel.addItem(status, to: sectionId)
            viewModel.addItem(action, to: sectionId)

            let section = try #require(viewModel.config.customSections.first)
            #expect(section.items.first?.item == status)
            #expect(section.items.last?.item.id == action.id)
            #expect(section.items.last?.item.customization?.requiresConfirmation == true)
            #expect(viewModel.config.selectedServerId == "server-1")
            let persistedConfig = try GarminConfig.config()
            #expect(persistedConfig?.customSections.first?.items.map(\.item.id) == ["sensor.temperature", "scene.movie"])
        }
    }

    @Test func duplicateCustomItemIsIgnoredInsideSameSection() throws {
        try withViewModel { viewModel in
            viewModel.addCustomSection()
            let sectionId = try #require(viewModel.config.customSections.first?.id)
            let item = MagicItem(id: "light.kitchen", serverId: "server-1", type: .entity)

            viewModel.addItem(item, to: sectionId)
            viewModel.addItem(item, to: sectionId)

            #expect(viewModel.config.customSections.first?.items.map(\.item.id) == ["light.kitchen"])
            #expect(viewModel.showError)
        }
    }

    @Test func addCustomItemRejectsDifferentServer() throws {
        try withViewModel { viewModel in
            viewModel.config.selectedServerId = "server-1"
            viewModel.addCustomSection()
            let sectionId = try #require(viewModel.config.customSections.first?.id)

            viewModel.addItem(MagicItem(id: "sensor.temperature", serverId: "server-2", type: .entity), to: sectionId)

            #expect(viewModel.config.customSections.first?.items.isEmpty == true)
            #expect(viewModel.showError)
        }
    }

    @Test func switchingServerPreservesCustomItemsPerServer() throws {
        try withViewModel { viewModel in
            viewModel.config.selectedServerId = "server-1"
            viewModel.config.serverConfigs = [
                .init(serverId: "server-1", customSections: [
                    .init(
                        id: "server-1-section",
                        title: "Server 1",
                        items: [
                            .init(item: MagicItem(id: "sensor.one", serverId: "server-1", type: .entity)),
                        ]
                    ),
                ]),
                .init(serverId: "server-2", customSections: [
                    .init(
                        id: "server-2-section",
                        title: "Server 2",
                        items: [
                            .init(item: MagicItem(id: "sensor.two", serverId: "server-2", type: .entity)),
                        ]
                    ),
                ]),
            ]

            viewModel.setSelectedServerId("server-2")

            #expect(viewModel.config.customSections.first?.items.map(\.item.id) == ["sensor.two"])

            viewModel.setSelectedServerId("server-1")

            #expect(viewModel.config.customSections.first?.items.map(\.item.id) == ["sensor.one"])
        }
    }

    @Test func switchingToNewServerCreatesDefaultServerConfig() throws {
        try withViewModel { viewModel in
            viewModel.config.selectedServerId = "server-1"
            viewModel.config.serverConfigs = [
                .init(
                    serverId: "server-1",
                    customSections: [
                        .init(
                            id: "custom-1",
                            title: "Quick",
                            items: [
                                .init(item: MagicItem(id: "sensor.one", serverId: "server-1", type: .entity)),
                            ]
                        ),
                    ]
                ),
            ]

            viewModel.setSelectedServerId("server-2")

            #expect(viewModel.config.customSections.isEmpty)
            #expect(viewModel.config.serverConfigs.map(\.serverId).contains("server-1"))
            #expect(viewModel.config.serverConfigs.map(\.serverId).contains("server-2"))
        }
    }

    @Test func customSectionsAreScopedToActiveServerConfig() throws {
        try withViewModel { viewModel in
            viewModel.config.selectedServerId = "server-1"
            viewModel.config.serverConfigs = [
                .init(
                    serverId: "server-1",
                    customSections: [
                        GarminCustomSection(
                    id: "custom-1",
                    title: "Quick",
                    items: [
                        .init(item: MagicItem(id: "sensor.one", serverId: "server-1", type: .entity)),
                    ]
                ),
                    ]
                ),
            ]

            viewModel.setSelectedServerId("server-2")

            #expect(viewModel.config.customSections.isEmpty)
        }
    }

    @Test func deleteMoveAndUpdateCustomItems() throws {
        try withViewModel { viewModel in
            viewModel.addCustomSection()
            let sectionId = try #require(viewModel.config.customSections.first?.id)
            let first = MagicItem(id: "sensor.first", serverId: "server-1", type: .entity)
            let second = MagicItem(id: "sensor.second", serverId: "server-1", type: .entity)
            let third = MagicItem(id: "sensor.third", serverId: "server-1", type: .entity)
            viewModel.addItem(first, to: sectionId)
            viewModel.addItem(second, to: sectionId)
            viewModel.addItem(third, to: sectionId)
            let secondItemId = try #require(viewModel.config.customSections.first?.items[1].id)

            var renamedSecond = second
            renamedSecond.displayText = "Second"
            viewModel.updateCustomItem(sectionId: sectionId, itemId: secondItemId, updatedItem: renamedSecond)
            viewModel.moveCustomItem(sectionId: sectionId, from: IndexSet(integer: 0), to: 3)
            viewModel.deleteCustomItem(sectionId: sectionId, at: IndexSet(integer: 1))

            let items = try #require(viewModel.config.customSections.first?.items)
            #expect(items.map(\.item.id) == ["sensor.second", "sensor.first"])
            #expect(items.first?.item.displayText == "Second")
        }
    }

    @Test func addCustomSectionRefusesNinthSection() throws {
        try withViewModel { viewModel in
            for _ in 0..<GarminConfig.maxCustomSections {
                viewModel.addCustomSection()
            }

            viewModel.addCustomSection()

            #expect(viewModel.config.customSections.count == GarminConfig.maxCustomSections)
            #expect(viewModel.showError)
        }
    }

    @Test func addCustomItemRefusesSeventeenthItem() throws {
        try withViewModel { viewModel in
            viewModel.addCustomSection()
            let sectionId = try #require(viewModel.config.customSections.first?.id)
            for index in 0..<GarminConfig.maxSectionItems {
                viewModel.addItem(MagicItem(
                    id: "sensor.item_\(index)",
                    serverId: "server-1",
                    type: .entity
                ), to: sectionId)
            }

            viewModel.addItem(MagicItem(
                id: "sensor.item_\(GarminConfig.maxSectionItems)",
                serverId: "server-1",
                type: .entity
            ), to: sectionId)

            #expect(viewModel.config.customSections.first?.items.count == GarminConfig.maxSectionItems)
            #expect(viewModel.showError)
        }
    }

    @Test func syncRefusesOversizedCustomSectionsConfig() throws {
        try withViewModel { viewModel, controller in
            viewModel.config.customSections = (0...GarminConfig.maxCustomSections).map { index in
                GarminCustomSection(id: "section-\(index)", title: "Section \(index)")
            }

            viewModel.sync()

            #expect(viewModel.config.customSections.count == GarminConfig.maxCustomSections + 1)
            #expect(controller.syncedConfigs.isEmpty)
            #expect(viewModel.showError)
        }
    }

    @Test func syncRefusesOversizedCustomSectionItemsConfig() throws {
        try withViewModel { viewModel, controller in
            viewModel.config.customSections = [
                GarminCustomSection(
                    id: "custom-1",
                    title: "Quick",
                    items: (0...GarminConfig.maxSectionItems).map { index in
                        GarminCustomSectionItem(
                            item: MagicItem(id: "sensor.item_\(index)", serverId: "server-1", type: .entity)
                        )
                    }
                ),
            ]

            viewModel.sync()

            #expect(viewModel.config.customSections.first?.items.count == GarminConfig.maxSectionItems + 1)
            #expect(controller.syncedConfigs.isEmpty)
            #expect(viewModel.showError)
        }
    }

    @Test func checkConnectionRequestsDeviceSelectionWithoutOverviewSync() throws {
        try withViewModel { viewModel, controller in
            viewModel.checkConnection()

            #expect(controller.didRequestConnectionCheck)
            #expect(viewModel.connectionState == .selectingDevice)
            #expect(controller.syncedConfigs.isEmpty)
        }
    }

    @Test func disconnectUnpairsWatchWithoutRemovingCustomSections() throws {
        try withViewModel { viewModel in
            let section = GarminCustomSection(
                id: "custom-1",
                title: "Quick",
                items: [
                    .init(item: MagicItem(id: "script.good_morning", serverId: "server-1", type: .script)),
                    .init(item: MagicItem(id: "sensor.temperature", serverId: "server-1", type: .entity)),
                ]
            )
            viewModel.config.selectedServerId = "server-1"
            viewModel.config.deviceIdentifier = "garmin-device"
            viewModel.config.appIdentifier = "garmin-app"
            viewModel.config.deviceName = "Venu 2"
            viewModel.config.lastCommunicationTimestamp = 456
            viewModel.config.customSections = [section]

            viewModel.disconnect()

            #expect(viewModel.config.deviceIdentifier == nil)
            #expect(viewModel.config.appIdentifier == nil)
            #expect(viewModel.config.deviceName == nil)
            #expect(viewModel.config.lastCommunicationTimestamp == nil)
            #expect(viewModel.config.selectedServerId == "server-1")
            #expect(viewModel.config.customSections == [section])
        }
    }

    @Test func connectionStateRefreshesPersistedPairingFields() async throws {
        try await withViewModel { (viewModel: GarminConfigurationViewModel, controller: FakeGarminIntegrationController) async throws in
            try await Current.database().write { db in
                var config = viewModel.config
                config.deviceIdentifier = "garmin-device"
                config.appIdentifier = "garmin-app"
                config.deviceName = "Venu 2"
                config.lastCommunicationTimestamp = 456
                try config.insert(db, onConflict: .replace)
            }

            controller.publishConnectionState(.ready(deviceName: "Venu 2"))
            try await Task.sleep(nanoseconds: 20_000_000)

            #expect(viewModel.config.deviceIdentifier == "garmin-device")
            #expect(viewModel.config.appIdentifier == "garmin-app")
            #expect(viewModel.config.deviceName == "Venu 2")
            #expect(viewModel.config.lastCommunicationTimestamp == 456)
        }
    }

    private func withViewModel(_ body: (GarminConfigurationViewModel) throws -> Void) throws {
        try withViewModel { viewModel, _ in
            try body(viewModel)
        }
    }

    private func withViewModel(
        _ body: (GarminConfigurationViewModel, FakeGarminIntegrationController) throws -> Void
    ) throws {
        let database = try DatabaseQueue(path: ":memory:")
        try GarminDatabaseSchema.createIfNeeded(database: database)
        let previousDatabase = Current.database
        Current.database = { database }
        defer { Current.database = previousDatabase }

        let controller = FakeGarminIntegrationController()
        let viewModel = GarminConfigurationViewModel(integrationController: controller)
        viewModel.config.selectedServerId = "server-1"
        viewModel.config.ensureServerConfig(serverId: "server-1")
        try body(viewModel, controller)
    }

    private func withViewModel(
        _ body: (GarminConfigurationViewModel, FakeGarminIntegrationController) async throws -> Void
    ) async throws {
        let database = try DatabaseQueue(path: ":memory:")
        try GarminDatabaseSchema.createIfNeeded(database: database)
        let previousDatabase = Current.database
        Current.database = { database }
        defer { Current.database = previousDatabase }

        let controller = FakeGarminIntegrationController()
        let viewModel = GarminConfigurationViewModel(integrationController: controller)
        viewModel.config.selectedServerId = "server-1"
        viewModel.config.ensureServerConfig(serverId: "server-1")
        try await body(viewModel, controller)
    }
}

private final class FakeGarminIntegrationController: GarminIntegrationControlling {
    private let connectionStateSubject = CurrentValueSubject<GarminConnectionState, Never>(.ready(deviceName: "Test Garmin"))
    private let connectionDiagnosticsSubject = CurrentValueSubject<GarminConnectionDiagnostics, Never>(.idle)
    var connectionState: GarminConnectionState { connectionStateSubject.value }
    var connectionStatePublisher: AnyPublisher<GarminConnectionState, Never> {
        connectionStateSubject.eraseToAnyPublisher()
    }
    var connectionDiagnostics: GarminConnectionDiagnostics { connectionDiagnosticsSubject.value }
    var connectionDiagnosticsPublisher: AnyPublisher<GarminConnectionDiagnostics, Never> {
        connectionDiagnosticsSubject.eraseToAnyPublisher()
    }

    var didRequestConnectionCheck = false
    var syncedConfigs: [GarminConfig] = []

    func setup() {}

    func handleConnectIQURL(_ url: URL) -> Bool {
        false
    }

    func requestConnectionCheck(force: Bool) {
        didRequestConnectionCheck = true
        connectionStateSubject.send(.selectingDevice)
    }

    func publishConnectionState(_ state: GarminConnectionState) {
        connectionStateSubject.send(state)
    }

    func sync(
        config: GarminConfig,
        itemInfo: @escaping (MagicItem) -> MagicItem.Info?,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
        syncedConfigs.append(config)
        completion(.success(()))
    }

    func disconnect(config: GarminConfig, completion: @escaping (Result<Void, GarminIntegrationError>) -> Void) {
        connectionStateSubject.send(.notConfigured)
        completion(.success(()))
    }
}
