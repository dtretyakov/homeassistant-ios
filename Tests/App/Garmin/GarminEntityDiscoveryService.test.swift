@testable import HomeAssistant
@testable import Shared
import Testing

private extension HAAppEntity {
    static func garmin(
        _ entityId: String,
        serverId: String = "server-1",
        domain: String? = nil,
        name: String,
        icon: String? = nil,
        rawDeviceClass: String? = nil
    ) -> HAAppEntity {
        HAAppEntity(
            id: "\(serverId)-\(entityId)",
            entityId: entityId,
            serverId: serverId,
            domain: domain ?? rawDomain(entityId),
            name: name,
            icon: icon,
            rawDeviceClass: rawDeviceClass
        )
    }

    private static func rawDomain(_ entityId: String) -> String {
        guard let domain = entityId.split(separator: ".").first else { return "" }
        return String(domain)
    }
}

struct GarminEntityDiscoveryServiceTests {
    @Test func discoversSupportedActionDomains() throws {
        let result = try makeService(entities: [
            .garmin("scene.movie", name: "Movie"),
            .garmin("script.good_night", name: "Good Night"),
            .garmin("input_boolean.guest_mode", name: "Guest Mode"),
            .garmin("light.kitchen", name: "Kitchen"),
            .garmin("switch.pump", name: "Pump"),
            .garmin("cover.garage", name: "Garage"),
            .garmin("climate.hallway", name: "Hallway"),
        ]).discover(serverId: "server-1")

        let actionIds = result.searchableCandidates.filter { $0.supportsAction }.map(\.entityId)
        #expect(actionIds.contains("scene.movie"))
        #expect(actionIds.contains("script.good_night"))
        #expect(actionIds.contains("input_boolean.guest_mode"))
        #expect(actionIds.contains("light.kitchen"))
        #expect(actionIds.contains("switch.pump"))
        #expect(actionIds.contains("cover.garage"))
        #expect(!actionIds.contains("climate.hallway"))
        #expect(result.actionsByDomain[Domain.light.rawValue]?.map(\.entityId) == ["light.kitchen"])
    }

    @Test func coverIsActionAndStatusWithoutForcedConfirmation() throws {
        let result = try makeService(entities: [
            .garmin("lock.front_door", name: "Front Door"),
            .garmin("cover.garage", name: "Garage"),
        ]).discover(serverId: "server-1")

        let lock = try #require(result.searchableCandidates.first { $0.entityId == "lock.front_door" })
        let cover = try #require(result.searchableCandidates.first { $0.entityId == "cover.garage" })
        #expect(!lock.supportsAction)
        #expect(lock.supportsStatus)
        #expect(cover.supportsAction)
        #expect(cover.supportsStatus)
        #expect(!cover.requiresConfirmation)
        #expect(cover.magicItem().customization?.requiresConfirmation == false)
    }

    @Test func discoversStatusDomainsIncludingRawHomeAssistantDomains() throws {
        let result = try makeService(entities: [
            .garmin("binary_sensor.front_door", name: "Front Door", rawDeviceClass: "door"),
            .garmin("sensor.temperature", name: "Temperature"),
            .garmin("alarm_control_panel.home", domain: "alarm_control_panel", name: "Alarm"),
            .garmin("device_tracker.phone", domain: "device_tracker", name: "Phone"),
            .garmin("person.dmitry", name: "Dmitry"),
        ]).discover(serverId: "server-1")

        let statusIds = result.searchableCandidates.filter { $0.supportsStatus }.map(\.entityId)
        #expect(statusIds.contains("binary_sensor.front_door"))
        #expect(statusIds.contains("sensor.temperature"))
        #expect(statusIds.contains("alarm_control_panel.home"))
        #expect(statusIds.contains("device_tracker.phone"))
        #expect(statusIds.contains("person.dmitry"))
    }

    @Test func hidesUnsupportedHiddenDisabledConfigAndDiagnosticEntities() throws {
        let result = try makeService(
            entities: [
                .garmin("light.visible", name: "Visible"),
                .garmin("light.hidden", name: "Hidden"),
                .garmin("switch.disabled", name: "Disabled"),
                .garmin("sensor.config", name: "Config"),
                .garmin("binary_sensor.diagnostic", name: "Diagnostic"),
                .garmin("media_player.tv", name: "TV"),
            ],
            registry: [
                .init(
                    entityId: "light.hidden",
                    isHidden: true,
                    isDisabled: false,
                    isConfiguration: false,
                    isDiagnostic: false
                ),
                .init(
                    entityId: "switch.disabled",
                    isHidden: false,
                    isDisabled: true,
                    isConfiguration: false,
                    isDiagnostic: false
                ),
                .init(
                    entityId: "sensor.config",
                    isHidden: false,
                    isDisabled: false,
                    isConfiguration: true,
                    isDiagnostic: false
                ),
                .init(
                    entityId: "binary_sensor.diagnostic",
                    isHidden: false,
                    isDisabled: false,
                    isConfiguration: false,
                    isDiagnostic: true
                ),
            ]
        ).discover(serverId: "server-1")

        let ids = result.searchableCandidates.map(\.entityId)
        #expect(ids == ["light.visible"])
    }

    @Test func searchesByFriendlyNameEntityIdAndArea() throws {
        let result = try makeService(
            entities: [
                .garmin("light.kitchen", name: "Ceiling"),
                .garmin("switch.pump", name: "Pump"),
            ],
            areas: [
                .init(name: "Kitchen", entities: ["light.kitchen"]),
            ]
        ).discover(serverId: "server-1")

        #expect(result.search("ceiling").map(\.entityId) == ["light.kitchen"])
        #expect(result.search("switch.pump").map(\.entityId) == ["switch.pump"])
        #expect(result.search("kitchen").map(\.entityId) == ["light.kitchen"])
    }

    private func makeService(
        entities: [HAAppEntity],
        registry: [GarminEntityRegistryInfo] = [],
        areas: [GarminEntityAreaInfo] = []
    ) -> GarminEntityDiscoveryService {
        GarminEntityDiscoveryService(
            entityProvider: { entities },
            registryProvider: { _ in registry },
            areaProvider: { _ in areas }
        )
    }
}
