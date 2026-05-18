import GRDB
@testable import HomeAssistant
@testable import Shared
import Testing

@Suite(.serialized)
struct GarminConfigurationViewModelTests {
    @Test func addSupportedActionStoresItemLocally() throws {
        try withViewModel { viewModel in
            let item = MagicItem(id: "light.kitchen", serverId: "server-1", type: .entity)

            viewModel.addAction(item)

            #expect(viewModel.config.actionItems == [item])
            #expect(try GarminConfig.config()?.actionItems == [item])
        }
    }

    @Test func duplicateActionIsIgnored() throws {
        try withViewModel { viewModel in
            let item = MagicItem(id: "script.good_morning", serverId: "server-1", type: .script)

            viewModel.addAction(item)
            viewModel.addAction(item)

            #expect(viewModel.config.actionItems == [item])
        }
    }

    @Test func deleteActionRemovesItem() throws {
        try withViewModel { viewModel in
            let first = MagicItem(id: "script.first", serverId: "server-1", type: .script)
            let second = MagicItem(id: "scene.second", serverId: "server-1", type: .scene)
            viewModel.addAction(first)
            viewModel.addAction(second)

            viewModel.deleteAction(at: IndexSet(integer: 0))

            #expect(viewModel.config.actionItems == [second])
        }
    }

    @Test func moveActionPreservesNewOrder() throws {
        try withViewModel { viewModel in
            let first = MagicItem(id: "script.first", serverId: "server-1", type: .script)
            let second = MagicItem(id: "script.second", serverId: "server-1", type: .script)
            let third = MagicItem(id: "script.third", serverId: "server-1", type: .script)
            viewModel.addAction(first)
            viewModel.addAction(second)
            viewModel.addAction(third)

            viewModel.moveAction(from: IndexSet(integer: 0), to: 3)

            #expect(viewModel.config.actionItems == [second, third, first])
        }
    }

    @Test func updateActionChangesDisplayText() throws {
        try withViewModel { viewModel in
            let item = MagicItem(id: "switch.office", serverId: "server-1", type: .entity)
            viewModel.addAction(item)

            var updated = item
            updated.displayText = "Office"
            viewModel.updateAction(updated)

            #expect(viewModel.config.actionItems.first?.displayText == "Office")
        }
    }

    @Test func updateSafeActionCanToggleConfirmation() throws {
        try withViewModel { viewModel in
            let item = MagicItem(
                id: "light.kitchen",
                serverId: "server-1",
                type: .entity,
                customization: .init(requiresConfirmation: false)
            )
            viewModel.addAction(item)

            var updated = item
            updated.customization?.requiresConfirmation = true
            viewModel.updateAction(updated)

            #expect(viewModel.config.actionItems.first?.customization?.requiresConfirmation == true)
        }
    }

    @Test func updateGuardedActionCannotClearConfirmation() throws {
        try withViewModel { viewModel in
            let item = MagicItem(
                id: "cover.garage",
                serverId: "server-1",
                type: .entity,
                customization: .init(requiresConfirmation: false)
            )
            viewModel.addAction(item)

            var updated = item
            updated.customization?.requiresConfirmation = false
            viewModel.updateAction(updated)

            #expect(viewModel.config.actionItems.first?.customization?.requiresConfirmation == true)
        }
    }

    @Test func addActionRefusesThirteenthItem() throws {
        try withViewModel { viewModel in
            for index in 0..<GarminConfig.maxActionItems {
                viewModel.addAction(MagicItem(
                    id: "script.item_\(index)",
                    serverId: "server-1",
                    type: .script
                ))
            }

            viewModel.addAction(MagicItem(
                id: "script.item_\(GarminConfig.maxActionItems)",
                serverId: "server-1",
                type: .script
            ))

            #expect(viewModel.config.actionItems.count == GarminConfig.maxActionItems)
        }
    }

    @Test func syncRefusesOversizedLegacyConfig() throws {
        try withViewModel { viewModel, client in
            viewModel.config.actionItems = (0...GarminConfig.maxActionItems).map { index in
                MagicItem(
                    id: "script.item_\(index)",
                    serverId: "server-1",
                    type: .script
                )
            }

            viewModel.sync()

            #expect(viewModel.config.actionItems.count == GarminConfig.maxActionItems + 1)
            #expect(client.sentProfiles.isEmpty)
        }
    }

    @Test func addSupportedStatusStoresItemLocally() throws {
        try withViewModel { viewModel in
            let item = MagicItem(id: "sensor.temperature", serverId: "server-1", type: .entity)

            viewModel.addStatus(item)

            #expect(viewModel.config.statusItems == [item])
            #expect(try GarminConfig.config()?.statusItems == [item])
        }
    }

    @Test func duplicateStatusIsIgnored() throws {
        try withViewModel { viewModel in
            let item = MagicItem(id: "binary_sensor.front_door", serverId: "server-1", type: .entity)

            viewModel.addStatus(item)
            viewModel.addStatus(item)

            #expect(viewModel.config.statusItems == [item])
        }
    }

    @Test func deleteStatusRemovesItem() throws {
        try withViewModel { viewModel in
            let first = MagicItem(id: "sensor.first", serverId: "server-1", type: .entity)
            let second = MagicItem(id: "sensor.second", serverId: "server-1", type: .entity)
            viewModel.addStatus(first)
            viewModel.addStatus(second)

            viewModel.deleteStatus(at: IndexSet(integer: 0))

            #expect(viewModel.config.statusItems == [second])
        }
    }

    @Test func moveStatusPreservesNewOrder() throws {
        try withViewModel { viewModel in
            let first = MagicItem(id: "sensor.first", serverId: "server-1", type: .entity)
            let second = MagicItem(id: "sensor.second", serverId: "server-1", type: .entity)
            let third = MagicItem(id: "sensor.third", serverId: "server-1", type: .entity)
            viewModel.addStatus(first)
            viewModel.addStatus(second)
            viewModel.addStatus(third)

            viewModel.moveStatus(from: IndexSet(integer: 0), to: 3)

            #expect(viewModel.config.statusItems == [second, third, first])
        }
    }

    @Test func updateStatusChangesDisplayText() throws {
        try withViewModel { viewModel in
            let item = MagicItem(id: "sensor.temperature", serverId: "server-1", type: .entity)
            viewModel.addStatus(item)

            var updated = item
            updated.displayText = "Temperature"
            viewModel.updateStatus(updated)

            #expect(viewModel.config.statusItems.first?.displayText == "Temperature")
        }
    }

    @Test func addStatusRefusesSixthItem() throws {
        try withViewModel { viewModel in
            for index in 0..<GarminConfig.maxStatusItems {
                viewModel.addStatus(MagicItem(
                    id: "sensor.item_\(index)",
                    serverId: "server-1",
                    type: .entity
                ))
            }

            viewModel.addStatus(MagicItem(
                id: "sensor.item_\(GarminConfig.maxStatusItems)",
                serverId: "server-1",
                type: .entity
            ))

            #expect(viewModel.config.statusItems.count == GarminConfig.maxStatusItems)
        }
    }

    @Test func syncRefusesOversizedLegacyStatusConfig() throws {
        try withViewModel { viewModel, client in
            viewModel.config.statusItems = (0...GarminConfig.maxStatusItems).map { index in
                MagicItem(
                    id: "sensor.item_\(index)",
                    serverId: "server-1",
                    type: .entity
                )
            }

            viewModel.sync()

            #expect(viewModel.config.statusItems.count == GarminConfig.maxStatusItems + 1)
            #expect(client.sentProfiles.isEmpty)
        }
    }

    private func withViewModel(_ body: (GarminConfigurationViewModel) throws -> Void) throws {
        try withViewModel { viewModel, _ in
            try body(viewModel)
        }
    }

    private func withViewModel(
        _ body: (GarminConfigurationViewModel, FakeGarminConnectIQClient) throws -> Void
    ) throws {
        let database = try DatabaseQueue(path: ":memory:")
        try GarminConfigTable().createIfNeeded(database: database)
        let previousDatabase = Current.database
        Current.database = { database }
        defer { Current.database = previousDatabase }

        let client = FakeGarminConnectIQClient()
        let bridgeService = GarminBridgeService(client: client)
        let viewModel = GarminConfigurationViewModel(bridgeService: bridgeService)
        try body(viewModel, client)
    }
}
