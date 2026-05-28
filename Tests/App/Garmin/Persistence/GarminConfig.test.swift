import GRDB
@testable import HomeAssistant
@testable import Shared
import Testing

struct GarminConfigTests {
    @Test func garminTablesExposeExpectedSchema() throws {
        #expect(GarminConfigTable().tableName == "garminConfig")
        #expect(GarminConfigTable().definedColumns == GarminConfigTable.Column.allCases.map(\.rawValue))
        #expect(GarminStatusSnapshotCacheTable().tableName == "garminStatusSnapshotCache")
        #expect(
            GarminStatusSnapshotCacheTable().definedColumns ==
                GarminStatusSnapshotCacheTable.Column.allCases.map(\.rawValue)
        )
    }

    @Test func persistsAndLoadsFromGRDB() throws {
        let database = try DatabaseQueue(path: ":memory:")
        try GarminDatabaseSchema.createIfNeeded(database: database)
        let previousDatabase = Current.database
        Current.database = { database }
        defer { Current.database = previousDatabase }

        let item = MagicItem(id: "script.good_morning", serverId: "server-1", type: .script)
        let config = GarminConfig(
            selectedServerId: "server-1",
            serverConfigs: [.init(serverId: "server-1", customSections: [
                .init(
                    id: "custom-1",
                    title: "Quick",
                    items: [GarminCustomSectionItem(item: item)]
                ),
            ])],
            deviceIdentifier: "garmin-device",
            appIdentifier: "garmin-app",
            deviceName: "Venu 2",
            lastCommunicationTimestamp: 456,
            lastSyncTimestamp: 123,
            lastError: nil
        )

        try database.write { db in
            try config.insert(db, onConflict: .replace)
        }

        let persistedConfig = try GarminConfig.config()
        #expect(persistedConfig == config)
    }

    @Test func opaqueIdentifiersDoNotExposeRawEntityIds() throws {
        let item = MagicItem(id: "light.kitchen", serverId: "server-1", type: .entity)

        let itemId = GarminConfig.opaqueItemId(for: item)

        #expect(itemId.hasPrefix("e_"))
        #expect(!itemId.contains("light.kitchen"))
        #expect(!itemId.contains("server-1"))
    }

    @Test func resolvesItemAndActionByOpaqueIdentifier() throws {
        let item = MagicItem(id: "switch.office", serverId: "server-1", type: .entity)
        let config = GarminConfig(selectedServerId: "server-1", serverConfigs: [.init(serverId: "server-1", customSections: [
            .init(
                id: "custom-1",
                title: "Quick",
                items: [GarminCustomSectionItem(item: item)]
            ),
        ])])
        let itemId = GarminConfig.opaqueItemId(for: item)

        #expect(config.item(for: itemId) == item)
        #expect(config.action(for: itemId) == item)
    }

    @Test func displayOnlyItemDoesNotResolveAsAction() throws {
        let item = MagicItem(id: "sensor.temperature", serverId: "server-1", type: .entity)
        let config = GarminConfig(selectedServerId: "server-1", serverConfigs: [.init(serverId: "server-1", customSections: [
            .init(
                id: "custom-1",
                title: "Quick",
                items: [GarminCustomSectionItem(item: item)]
            ),
        ])])
        let itemId = GarminConfig.opaqueItemId(for: item)

        #expect(config.item(for: itemId) == item)
        #expect(config.action(for: itemId) == nil)
    }

    @Test func capabilityBitmaskMatchesDomainSupport() throws {
        #expect(GarminConfig.capability(for: MagicItem(id: "sensor.temperature", serverId: "server-1", type: .entity)) == 1)
        #expect(GarminConfig.capability(for: MagicItem(id: "script.good_morning", serverId: "server-1", type: .script)) == 2)
        #expect(GarminConfig.capability(for: MagicItem(id: "scene.movie", serverId: "server-1", type: .scene)) == 2)
        #expect(GarminConfig.capability(for: MagicItem(id: "light.kitchen", serverId: "server-1", type: .entity)) == 3)
        #expect(GarminConfig.capability(for: MagicItem(id: "lock.front_door", serverId: "server-1", type: .entity)) == 3)
    }

    @Test func decodesLegacyCustomSectionItemsAndMergesDuplicates() throws {
        let item = MagicItem(id: "light.kitchen", serverId: "server-1", type: .entity)
        let section = GarminCustomSection(
            id: "custom-1",
            title: "Quick",
            items: [
                GarminCustomSectionItem(item: item),
                GarminCustomSectionItem(item: item),
            ]
        )
        let encoded = try JSONEncoder().encode(GarminServerOverviewConfig(
            serverId: "server-1",
            customSections: [section]
        ))

        let decoded = try JSONDecoder().decode(GarminServerOverviewConfig.self, from: encoded)

        #expect(decoded.customSections.first?.items.map(\.item.id) == ["light.kitchen"])
    }

    @Test func supportsExpectedActionDomains() throws {
        #expect(GarminSupportedDomains.supportsAction(.scene))
        #expect(GarminSupportedDomains.supportsAction(.script))
        #expect(GarminSupportedDomains.supportsAction(.light))
        #expect(GarminSupportedDomains.supportsAction(.switch))
        #expect(GarminSupportedDomains.supportsAction(.inputBoolean))
        #expect(GarminSupportedDomains.supportsAction(.lock))
        #expect(GarminSupportedDomains.supportsAction(.cover))
        #expect(GarminSupportedDomains.supportsStatus(rawDomain: Domain.sensor.rawValue))
        #expect(GarminSupportedDomains.supportsStatus(rawDomain: Domain.lock.rawValue))
        #expect(GarminSupportedDomains.supportsStatus(rawDomain: "alarm_control_panel"))
        #expect(GarminSupportedDomains.supportsStatus(rawDomain: "device_tracker"))
    }
}
