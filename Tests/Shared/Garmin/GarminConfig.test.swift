import GRDB
@testable import Shared
import Testing

struct GarminConfigTests {
    @Test func persistsAndLoadsFromGRDB() throws {
        let database = try DatabaseQueue(path: ":memory:")
        try GarminConfigTable().createIfNeeded(database: database)
        let previousDatabase = Current.database
        Current.database = { database }
        defer { Current.database = previousDatabase }

        let item = MagicItem(id: "script.good_morning", serverId: "server-1", type: .script)
        let config = GarminConfig(
            selectedServerId: "server-1",
            actionItems: [item],
            deviceIdentifier: "garmin-device",
            appIdentifier: "garmin-app",
            lastSyncTimestamp: 123,
            lastError: nil
        )

        try database.write { db in
            try config.insert(db, onConflict: .replace)
        }

        #expect(try GarminConfig.config() == config)
    }

    @Test func opaqueIdentifiersDoNotExposeRawEntityIds() throws {
        let item = MagicItem(id: "light.kitchen", serverId: "server-1", type: .entity)

        let actionId = GarminConfig.opaqueActionId(for: item)
        let statusId = GarminConfig.opaqueStatusId(for: item)

        #expect(actionId.hasPrefix("garmin_action_"))
        #expect(statusId.hasPrefix("garmin_status_"))
        #expect(!actionId.contains("light.kitchen"))
        #expect(!statusId.contains("light.kitchen"))
        #expect(!actionId.contains("server-1"))
        #expect(!statusId.contains("server-1"))
    }

    @Test func resolvesActionsByOpaqueIdentifier() throws {
        let item = MagicItem(id: "switch.office", serverId: "server-1", type: .entity)
        let config = GarminConfig(actionItems: [item])

        let resolved = config.action(for: GarminConfig.opaqueActionId(for: item))

        #expect(resolved == item)
    }

    @Test func supportsExpectedActionDomains() throws {
        #expect(GarminSupportedDomains.supportsAction(.scene))
        #expect(GarminSupportedDomains.supportsAction(.script))
        #expect(GarminSupportedDomains.supportsAction(.light))
        #expect(GarminSupportedDomains.supportsAction(.switch))
        #expect(GarminSupportedDomains.supportsAction(.inputBoolean))
        #expect(!GarminSupportedDomains.supportsAction(.lock))
        #expect(!GarminSupportedDomains.supportsAction(.cover))
    }
}
