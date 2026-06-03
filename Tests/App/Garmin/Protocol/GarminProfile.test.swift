import Foundation
@testable import HomeAssistant
@testable import Shared
import Testing

struct GarminProfileTests {
    @Test func inboundMessagesDecodeSectionOnlyProtocolFields() throws {
        let getSection = try GarminPayloadCodec.decodeInboundDictionary([
            "t": "get",
            "id": "root",
            "v": GarminProtocolVersion.current,
            "e": "r1",
            "cid": "h125",
        ])

        #expect(GarminProtocolVersion.current == 3)
        #expect(getSection.type == .getSection)
        #expect(getSection.id == "root")
        #expect(getSection.etag == "r1")
        #expect(getSection.correlationId == "h125")
        #expect(getSection.pageOffset == 0)
        #expect(getSection.pageLimit == nil)
    }

    @Test func inboundGetMessageDecodesPaginationFields() throws {
        let getSection = try GarminPayloadCodec.decodeInboundDictionary([
            "t": "get",
            "id": "area:kitchen",
            "v": GarminProtocolVersion.current,
            "o": 15,
            "l": 14,
            "cid": "h126",
        ])

        #expect(getSection.type == .getSection)
        #expect(getSection.pageOffset == 15)
        #expect(getSection.pageLimit == 14)
    }

    @Test func sectionSnapshotEncodingUsesTypeAndOmitsSectionKind() throws {
        let section = GarminOverviewSection(
            id: GarminOverviewSectionID.root,
            title: "Home",
            etag: "root-etag",
            items: [
                GarminOverviewItem(
                    id: GarminOverviewSectionID.areas,
                    label: "Areas",
                    type: .section
                ),
                GarminOverviewItem(
                    id: "e_status1",
                    label: "Temperature",
                    type: .item,
                    cap: GarminConfig.valueCapability,
                    domain: "sn"
                ),
                GarminOverviewItem(
                    id: "e_action1",
                    label: "Movie",
                    type: .item,
                    cap: GarminConfig.actionCapability,
                    confirmation: .required,
                    domain: "sc"
                ),
            ],
            values: [.init(id: "e_status1", value: "20 C")],
            pageOffset: 15,
            pageLimit: 14,
            previousOffset: 0,
            nextOffset: 29
        )
        let dictionary = try GarminPayloadCodec.encodeOutboundDictionary(.init(type: .sectionSnapshot, section: section))
        let encoded = try String(decoding: JSONSerialization.data(withJSONObject: dictionary), as: UTF8.self)

        #expect(encoded.contains("\"t\":\"section\""))
        #expect(encoded.contains("\"type\":\"section\""))
        #expect(encoded.contains("\"type\":\"item\""))
        #expect(encoded.contains("\"cap\":1"))
        #expect(encoded.contains("\"cap\":2"))
        #expect(encoded.contains("\"d\":\"sn\""))
        #expect(encoded.contains("\"d\":\"sc\""))
        #expect(encoded.contains("\"etag\":\"root-etag\""))
        #expect(encoded.contains("\"o\":15"))
        #expect(encoded.contains("\"l\":14"))
        #expect(encoded.contains("\"po\":0"))
        #expect(encoded.contains("\"no\":29"))
        #expect(encoded.contains("\"vals\""))
        #expect(encoded.contains("\"v\":\"20 C\""))
        #expect(!encoded.contains("\"kind\""))
        #expect(!encoded.contains("\"section_etag\""))
        #expect(!encoded.contains("\"section_id\""))
        #expect(!encoded.contains("\"action_id\""))
        #expect(!encoded.contains("\"value_id\""))
        #expect(!encoded.contains("\"icon_name\""))
        #expect(!encoded.contains("\"domain\""))
    }

    @Test func overviewItemDomainUsesCompactWireKeyAndDecodesMissingDomain() throws {
        let item = GarminOverviewItem(
            id: "e_light",
            label: "Kitchen",
            type: .item,
            cap: GarminConfig.valueCapability | GarminConfig.actionCapability,
            domain: "l"
        )
        let message = GarminOutboundMessage(
            type: .sectionSnapshot,
            section: .init(id: "custom", title: "Custom", etag: "e1", items: [
                .init(id: "area:kitchen", label: "Kitchen", type: .section, domain: "l"),
                item,
            ])
        )

        let dictionary = try GarminPayloadCodec.encodeOutboundDictionary(message)
        let encoded = try String(decoding: JSONSerialization.data(withJSONObject: dictionary), as: UTF8.self)

        #expect(encoded.contains("\"d\":\"l\""))
        #expect(!encoded.contains("\"domain\""))
        let section = try #require(dictionary["section"] as? [String: Any])
        let items = try #require(section["items"] as? [[String: Any]])
        #expect(items.first?["d"] == nil)
        #expect(items.last?["d"] as? String == "l")

        let decoded = try JSONDecoder().decode(GarminOverviewItem.self, from: Data("""
        {"id":"e_old","label":"Old","type":"item","cap":1}
        """.utf8))
        #expect(decoded.domain == nil)
    }

    @Test func compactDomainCodesUseDocumentedWireValues() {
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "scene") == "sc")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "script") == "sr")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "light") == "l")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "climate") == "cl")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "fan") == "f")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "humidifier") == "hm")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "switch") == "sw")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "input_boolean") == "ib")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "cover") == "cv")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "lock") == "lk")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "alarm_control_panel") == "al")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "binary_sensor") == "bs")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "sensor") == "sn")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "media_player") == "mp")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "person") == "p")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "device_tracker") == "dt")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "water_heater") == "wh")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "weather") == "w")
    }

    @Test func notModifiedMessagesUseFlatCompactKeys() throws {
        let message = GarminOutboundMessage(
            type: .sectionNotModified,
            id: GarminOverviewSectionID.root,
            correlationId: "h123",
            pageOffset: 15
        )

        let dictionary = try GarminPayloadCodec.encodeOutboundDictionary(message)
        let encoded = try String(decoding: JSONSerialization.data(withJSONObject: dictionary), as: UTF8.self)

        #expect(dictionary["t"] as? String == "same")
        #expect(dictionary["id"] as? String == GarminOverviewSectionID.root)
        #expect(dictionary["o"] as? Int == 15)
        #expect(dictionary["cid"] as? String == "h123")
        #expect(dictionary["v"] as? Int == GarminProtocolVersion.current)
        #expect(!dictionary.keys.contains("action_result"))
        #expect(!dictionary.keys.contains("correlation_id"))
        #expect(!encoded.contains("\"action_result\""))
    }

    @Test func actionResultMessagesUseFlatCompactKeys() throws {
        let message = GarminOutboundMessage(
            type: .actionResult,
            actionResult: .init(id: "e_1", correlationId: "h123", state: .success)
        )

        let dictionary = try GarminPayloadCodec.encodeOutboundDictionary(message)

        #expect(dictionary["t"] as? String == "result")
        #expect(dictionary["id"] as? String == "e_1")
        #expect(dictionary["cid"] as? String == "h123")
        #expect(dictionary["state"] as? String == "success")
        #expect(!dictionary.keys.contains("action_result"))
    }

    @Test func promptMessagesUseFlatCompactKeysWithoutVersionBump() throws {
        let prompt = GarminNotificationPrompt(
            id: "p_1",
            correlationId: "h123",
            title: "Open front door?",
            body: "Arrived home",
            actions: [
                .init(id: "OPEN", label: "Open"),
                .init(id: "DISMISS", label: "Dismiss"),
            ],
            expiresAt: 1_710_000_300
        )
        let message = GarminOutboundMessage(type: .prompt, prompt: prompt)

        let dictionary = try GarminPayloadCodec.encodeOutboundDictionary(message)

        #expect(GarminProtocolVersion.current == 3)
        #expect(dictionary["v"] as? Int == GarminProtocolVersion.current)
        #expect(dictionary["t"] as? String == "prompt")
        #expect(dictionary["id"] as? String == "p_1")
        #expect(dictionary["cid"] as? String == "h123")
        #expect(dictionary["title"] as? String == "Open front door?")
        #expect(dictionary["body"] as? String == "Arrived home")
        #expect(dictionary["expires_at"] as? Int == 1_710_000_300)
        let actions = try #require(dictionary["actions"] as? [[String: Any]])
        #expect(actions.first?["id"] as? String == "OPEN")
        #expect(actions.first?["label"] as? String == "Open")
        #expect(!dictionary.keys.contains("prompt"))
    }

    @Test func promptResponseDecodesActionIdWithoutVersionBump() throws {
        let response = try GarminPayloadCodec.decodeInboundDictionary([
            "t": "prompt_response",
            "id": "p_1",
            "v": GarminProtocolVersion.current,
            "cid": "h123",
            "action_id": "OPEN",
        ])

        #expect(response.type == .promptResponse)
        #expect(response.id == "p_1")
        #expect(response.correlationId == "h123")
        #expect(response.actionId == "OPEN")
    }

    @Test func payloadByteLimitCanRejectLargeSectionSnapshot() throws {
        let oversizedLabel = String(repeating: "A", count: GarminPayloadLimits.outboundMessageBytes)
        let section = GarminOverviewSection(
            id: "large",
            title: oversizedLabel,
            etag: "large",
            items: []
        )
        let message = GarminOutboundMessage(type: .sectionSnapshot, section: section)
        let byteCount = try GarminPayloadCodec.encodedByteCount(message)

        #expect(byteCount > GarminPayloadLimits.outboundMessageBytes)
    }

    @Test func rootSectionBuildsBuiltInsAndCustomSectionsAsSameSectionItems() throws {
        let custom = GarminCustomSection(
            id: "downstairs",
            title: "Downstairs",
            items: [
                .init(item: MagicItem(id: "sensor.temperature", serverId: "server-1", type: .entity)),
            ]
        )
        let config = GarminConfig(
            selectedServerId: "server-1",
            serverConfigs: [.init(serverId: "server-1", customSections: [custom])]
        )
        let source = GarminHomeOverviewSource(
            entityProvider: {
                [
                    entity("light.kitchen", name: "Kitchen light", domain: "light"),
                    entity("binary_sensor.front_door", name: "Front door", domain: "binary_sensor", deviceClass: "door"),
                ]
            },
            areaProvider: { _ in
                [area("kitchen", name: "Kitchen", entities: ["light.kitchen"])]
            }
        )

        let root = try #require(try source.section(id: GarminOverviewSectionID.root, config: config, itemInfo: { _ in nil }))

        #expect(root.id == GarminOverviewSectionID.root)
        #expect(root.items.map(\.type) == [.section, .section, .section])
        #expect(root.items.map(\.id) == [
            GarminOverviewSectionID.areas,
            GarminOverviewSectionID.summaries,
            GarminOverviewSectionID.custom(custom.id),
        ])
    }

    @Test func rootSectionKeepsEnabledSectionsEvenWhenEmpty() throws {
        let custom = GarminCustomSection(id: "empty", title: "Empty", items: [])
        let source = GarminHomeOverviewSource(
            entityProvider: { [] },
            areaProvider: { _ in [] }
        )
        let config = GarminConfig(
            selectedServerId: "server-1",
            serverConfigs: [.init(serverId: "server-1", customSections: [custom])]
        )

        let root = try #require(try source.section(id: GarminOverviewSectionID.root, config: config, itemInfo: { _ in nil }))

        #expect(root.items.map(\.id) == [
            GarminOverviewSectionID.areas,
            GarminOverviewSectionID.summaries,
            GarminOverviewSectionID.custom(custom.id),
        ])
    }

    @Test func customSectionFiltersItemsToSelectedServer() throws {
        let current = MagicItem(id: "sensor.current", serverId: "server-1", type: .entity, displayText: "Current")
        let other = MagicItem(id: "sensor.other", serverId: "server-2", type: .entity, displayText: "Other")
        let config = GarminConfig(
            selectedServerId: "server-1",
            serverConfigs: [.init(serverId: "server-1", customSections: [
                .init(
                    id: "custom-1",
                    title: "Quick",
                    items: [
                        .init(item: current),
                        .init(item: other),
                    ]
                ),
            ])]
        )
        let source = GarminHomeOverviewSource(entityProvider: { [] }, areaProvider: { _ in [] })

        let section = try #require(try source.section(
            id: GarminOverviewSectionID.custom("custom-1"),
            config: config,
            itemInfo: { _ in nil }
        ))

        #expect(section.items.map(\.label) == ["Current"])
    }

    @Test func customSectionCanMixStatusAndActionLeafItems() throws {
        let status = MagicItem(id: "sensor.temperature", serverId: "server-1", type: .entity, displayText: "Temperature")
        let action = MagicItem(
            id: "scene.movie",
            serverId: "server-1",
            type: .scene,
            customization: .init(requiresConfirmation: true),
            displayText: "Movie"
        )
        let config = GarminConfig(
            selectedServerId: "server-1",
            serverConfigs: [.init(serverId: "server-1", customSections: [
                .init(
                    id: "custom-1",
                    title: "Quick",
                    items: [
                        .init(item: status),
                        .init(item: action),
                    ]
                ),
            ])]
        )
        let values = [GarminConfig.opaqueItemId(for: status): "21 C"]
        let source = GarminHomeOverviewSource(entityProvider: { [] }, areaProvider: { _ in [] })

        let section = try #require(try source.section(
            id: GarminOverviewSectionID.custom("custom-1"),
            config: config,
            itemInfo: { _ in nil },
            valueProvider: { values[$0.id] }
        ))

        #expect(section.items.map(\.type) == [.item, .item])
        #expect(section.items.map(\.cap) == [GarminConfig.valueCapability, GarminConfig.actionCapability])
        #expect(section.items.map(\.domain) == ["sn", "sc"])
        #expect(section.items.first?.id == GarminConfig.opaqueItemId(for: status))
        #expect(section.items.last?.id == GarminConfig.opaqueItemId(for: action))
        #expect(section.items.last?.confirmation == .required)
        #expect(section.values == [.init(id: GarminConfig.opaqueItemId(for: status), value: "21 C")])
    }

    @Test func areaAndSummaryDetailsResolveThroughOneSectionPath() throws {
        let kitchen = entity("light.kitchen", name: "Kitchen", domain: "light")
        let hall = entity("light.hall", name: "Hall", domain: "light")
        let values: [String: String] = [
            GarminConfig.opaqueEntityId(serverId: "server-1", entityId: "light.kitchen"): "on",
            GarminConfig.opaqueEntityId(serverId: "server-1", entityId: "light.hall"): "off",
        ]
        let source = GarminHomeOverviewSource(
            entityProvider: { [kitchen, hall] },
            areaProvider: { _ in [area("kitchen", name: "Kitchen", entities: ["light.kitchen"])] },
            summaryProvider: summaryProvider(
                panels: [panel("light")],
                states: [
                    .init(entityId: "light.kitchen", state: "on"),
                    .init(entityId: "light.hall", state: "off"),
                ]
            )
        )
        let config = GarminConfig(selectedServerId: "server-1")

        let areas = try #require(try source.section(id: GarminOverviewSectionID.areas, config: config, itemInfo: { _ in nil }))
        let areaDetail = try #require(try source.section(
            id: GarminOverviewSectionID.area("kitchen"),
            config: config,
            itemInfo: { _ in nil },
            valueProvider: { values[$0.id] }
        ))
        let summaries = try #require(try source.section(id: GarminOverviewSectionID.summaries, config: config, itemInfo: { _ in nil }))
        let lights = try #require(try source.section(
            id: GarminOverviewSectionID.summary("light"),
            config: config,
            itemInfo: { _ in nil }
        ))

        #expect(areas.items.map(\.type) == [.section])
        #expect(areaDetail.items.map(\.type) == [.item])
        #expect(areaDetail.items.map(\.cap) == [GarminConfig.valueCapability | GarminConfig.actionCapability])
        #expect(areaDetail.items.map(\.domain) == ["l"])
        #expect(areaDetail.values == [.init(id: GarminConfig.opaqueEntityId(serverId: "server-1", entityId: "light.kitchen"), value: "on")])
        #expect(summaries.items.first?.type == .section)
        #expect(summaries.items.first?.id == GarminOverviewSectionID.summary("light"))
        #expect(lights.items.map(\.label) == ["Kitchen"])
        #expect(lights.items.map(\.domain) == ["l"])
        #expect(lights.values.isEmpty)
    }

    @Test func summaryProviderBuildsCanonicalListWithPanelAndRegistryFilters() throws {
        let visibleLight = entity("light.visible", name: "Visible light", domain: "light")
        let hiddenLight = entity("light.hidden", name: "Hidden light", domain: "light")
        let diagnosticClimate = entity("climate.diagnostic", name: "Diagnostic climate", domain: "climate")
        let media = entity("media_player.living_room", name: "Living room", domain: "media_player")
        let provider = summaryProvider(
            registries: [
                registry(entityId: hiddenLight.entityId, hiddenBy: "user"),
                registry(entityId: diagnosticClimate.entityId, entityCategory: "diagnostic"),
            ],
            panels: [panel("light"), panel("climate")],
            states: [
                .init(entityId: visibleLight.entityId, state: "on"),
                .init(entityId: hiddenLight.entityId, state: "on"),
                .init(entityId: diagnosticClimate.entityId, state: "heat"),
                .init(entityId: media.entityId, state: "playing"),
            ]
        )

        let summaries = try provider.summaries(
            serverId: "server-1",
            entities: [visibleLight, hiddenLight, diagnosticClimate, media]
        )

        #expect(summaries.map(\.id) == ["light", "media_players"])
    }

    @Test func summaryProviderRequiresLiveStatesAndDoesNotFallbackToAllEntities() throws {
        let kitchen = entity("light.kitchen", name: "Kitchen", domain: "light")
        let hall = entity("light.hall", name: "Hall", domain: "light")
        let provider = summaryProvider(panels: [panel("light")])

        let summaries = try provider.summaries(serverId: "server-1", entities: [kitchen, hall])
        let contributors = try provider.contributors(serverId: "server-1", summaryId: "light", entities: [kitchen, hall])

        #expect(summaries.isEmpty)
        #expect(contributors.isEmpty)
    }

    @Test func summaryProviderUsesRawStateSnapshotForActiveContributors() throws {
        let onLight = entity("light.kitchen", name: "Kitchen", domain: "light")
        let offLight = entity("light.hall", name: "Hall", domain: "light")
        let unlocked = entity("lock.front_door", name: "Front door", domain: "lock")
        let locked = entity("lock.back_door", name: "Back door", domain: "lock")
        let provider = summaryProvider(
            panels: [panel("light"), panel("security")],
            states: [
                .init(entityId: onLight.entityId, state: "on"),
                .init(entityId: offLight.entityId, state: "off"),
                .init(entityId: unlocked.entityId, state: "unlocked"),
                .init(entityId: locked.entityId, state: "locked"),
            ]
        )

        let lights = try provider.contributors(serverId: "server-1", summaryId: "light", entities: [onLight, offLight])
        let security = try provider.contributors(serverId: "server-1", summaryId: "security", entities: [unlocked, locked])

        #expect(lights.map(\.entityId) == [onLight.entityId])
        #expect(security.map(\.entityId) == [unlocked.entityId])
    }

    @Test func summaryProviderMatchesHomeAssistantSecurityFiltersAndImportantStates() throws {
        let camera = entity("camera.porch", name: "Porch camera", domain: "camera")
        let gate = entity("cover.gate", name: "Gate", domain: "cover", deviceClass: "gate")
        let smoke = entity("binary_sensor.smoke", name: "Smoke", domain: "binary_sensor", deviceClass: "smoke")
        let tamper = entity("binary_sensor.tamper", name: "Tamper", domain: "binary_sensor", deviceClass: "tamper")
        let locked = entity("lock.back", name: "Back", domain: "lock")
        let provider = summaryProvider(
            registries: [
                registry(entityId: tamper.entityId, entityCategory: "diagnostic"),
            ],
            panels: [panel("security")],
            states: [
                .init(entityId: camera.entityId, state: "idle"),
                .init(entityId: gate.entityId, state: "open"),
                .init(entityId: smoke.entityId, state: "on"),
                .init(entityId: tamper.entityId, state: "on"),
                .init(entityId: locked.entityId, state: "locked"),
            ]
        )

        let summaries = try provider.summaries(serverId: "server-1", entities: [camera, gate, smoke, tamper, locked])
        let contributors = try provider.contributors(serverId: "server-1", summaryId: "security", entities: [camera, gate, smoke, tamper, locked])

        #expect(summaries.map(\.id) == ["security"])
        #expect(contributors.map(\.entityId) == [gate.entityId, smoke.entityId, tamper.entityId])
    }

    @Test func summaryProviderUsesHomeAssistantMaintenanceThresholds() throws {
        let low = entity("sensor.low_battery", name: "Low battery", domain: "sensor", deviceClass: "battery")
        let ok = entity("sensor.ok_battery", name: "Ok battery", domain: "sensor", deviceClass: "battery")
        let unavailable = entity("sensor.unavailable_battery", name: "Unavailable battery", domain: "sensor", deviceClass: "battery")
        let unknown = entity("sensor.unknown_battery", name: "Unknown battery", domain: "sensor", deviceClass: "battery")
        let binaryLow = entity("binary_sensor.remote_battery", name: "Remote battery", domain: "binary_sensor", deviceClass: "battery")
        let provider = summaryProvider(
            panels: [panel("maintenance")],
            states: [
                .init(entityId: low.entityId, state: "20"),
                .init(entityId: ok.entityId, state: "21"),
                .init(entityId: unavailable.entityId, state: "unavailable"),
                .init(entityId: unknown.entityId, state: "unknown"),
                .init(entityId: binaryLow.entityId, state: "on"),
            ]
        )

        let contributors = try provider.contributors(
            serverId: "server-1",
            summaryId: "maintenance",
            entities: [low, ok, unavailable, unknown, binaryLow]
        )

        #expect(contributors.map(\.entityId) == [low.entityId, unavailable.entityId, binaryLow.entityId])
    }

    @Test func summaryProviderMatchesHomeAssistantClimateFiltersWithoutShowingIdleDevices() throws {
        let climateIdle = entity("climate.hall", name: "Hall climate", domain: "climate")
        let fan = entity("fan.ceiling", name: "Ceiling fan", domain: "fan")
        let humidifier = entity("humidifier.bedroom", name: "Bedroom humidifier", domain: "humidifier")
        let windowCover = entity("cover.window", name: "Window cover", domain: "cover", deviceClass: "window")
        let windowSensor = entity("binary_sensor.window", name: "Window", domain: "binary_sensor", deviceClass: "window")
        let provider = summaryProvider(
            panels: [panel("climate")],
            states: [
                .init(entityId: climateIdle.entityId, state: "idle"),
                .init(entityId: fan.entityId, state: "on"),
                .init(entityId: humidifier.entityId, state: "off"),
                .init(entityId: windowCover.entityId, state: "open"),
                .init(entityId: windowSensor.entityId, state: "on"),
            ]
        )

        let summaries = try provider.summaries(serverId: "server-1", entities: [climateIdle, fan, humidifier, windowCover, windowSensor])
        let contributors = try provider.contributors(serverId: "server-1", summaryId: "climate", entities: [climateIdle, fan, humidifier, windowCover, windowSensor])

        #expect(summaries.map(\.id) == ["climate"])
        #expect(contributors.map(\.entityId) == [fan.entityId, windowCover.entityId, windowSensor.entityId])
    }

    @Test func summaryProviderTreatsWeatherAsSingleSummaryTile() throws {
        let zWeather = entity("weather.z_outside", name: "Z outside", domain: "weather")
        let aWeather = entity("weather.a_outside", name: "A outside", domain: "weather")
        let provider = summaryProvider(states: [
            .init(entityId: zWeather.entityId, state: "sunny"),
            .init(entityId: aWeather.entityId, state: "cloudy"),
        ])

        let summaries = try provider.summaries(serverId: "server-1", entities: [zWeather, aWeather])
        let contributors = try provider.contributors(serverId: "server-1", summaryId: "weather", entities: [zWeather, aWeather])

        #expect(summaries.map(\.id) == ["weather"])
        #expect(contributors.map(\.entityId) == [aWeather.entityId])
    }

    @Test func summaryProviderSupportsLegacySummaryAliases() throws {
        let provider = summaryProvider()

        #expect(provider.canonicalSummaryId("lights") == "light")
        #expect(provider.canonicalSummaryId("locks") == "security")
        #expect(provider.canonicalSummaryId("openings") == "security")
        #expect(provider.canonicalSummaryId("people") == nil)
    }

    @Test func summaryDetailSectionCanBuildWithoutDisplayValueProvider() throws {
        let kitchen = entity("light.kitchen", name: "Kitchen", domain: "light")
        let hall = entity("light.hall", name: "Hall", domain: "light")
        let source = GarminHomeOverviewSource(
            entityProvider: { [kitchen, hall] },
            areaProvider: { _ in [] },
            summaryProvider: summaryProvider(
                panels: [panel("light")],
                states: [
                    .init(entityId: kitchen.entityId, state: "on"),
                    .init(entityId: hall.entityId, state: "off"),
                ]
            )
        )
        let config = GarminConfig(selectedServerId: "server-1")

        let section = try #require(try source.section(
            id: GarminOverviewSectionID.summary("light"),
            config: config,
            itemInfo: { _ in nil }
        ))

        #expect(section.items.map(\.label) == ["Kitchen"])
        #expect(section.items.map(\.id) == [
            GarminConfig.opaqueEntityId(serverId: "server-1", entityId: "light.kitchen"),
        ])
    }

    @Test func maxTypicalSectionSnapshotStaysWithinGarminOutboundLimit() throws {
        let items = (0..<GarminConfig.maxSectionItems).map { index in
            GarminOverviewItem(
                id: "e_\(index)",
                label: "Status \(index)",
                type: .item,
                cap: GarminConfig.valueCapability,
                domain: "sn"
            )
        }
        let message = GarminOutboundMessage(
            type: .sectionSnapshot,
            section: GarminOverviewSection(
                id: "custom",
                title: "Custom",
                etag: "etag",
                items: items,
                values: items.map { GarminOverviewValue(id: $0.id, value: "On") }
            )
        )
        let byteCount = try GarminPayloadCodec.encodedByteCount(message)

        #expect(byteCount < GarminPayloadLimits.outboundMessageBytes)
    }

    @Test func overviewSectionEtagIgnoresValuesWhileValuesDeltaCarriesRevision() throws {
        let item = GarminOverviewItem(
            id: GarminConfig.opaqueEntityId(serverId: "server-1", entityId: "light.kitchen"),
            label: "Kitchen",
            type: .item,
            cap: GarminConfig.valueCapability | GarminConfig.actionCapability
        )
        let first = GarminOverviewSection(
            id: GarminOverviewSectionID.areas,
            title: "Areas",
            etag: "same",
            items: [item],
            values: [.init(id: item.id, value: "Off")]
        )
        let second = GarminOverviewSection(
            id: GarminOverviewSectionID.areas,
            title: "Areas",
            etag: "same",
            items: [item],
            values: [.init(id: item.id, value: "On")]
        )
        let delta = GarminOutboundMessage(
            type: .valuesDelta,
            values: [.init(id: item.id, value: "On")],
            valuesRevision: 42
        )
        let deltaDictionary = try GarminPayloadCodec.encodeOutboundDictionary(delta)
        let encodedDelta = try String(decoding: JSONSerialization.data(withJSONObject: deltaDictionary), as: UTF8.self)

        #expect(first.etag == second.etag)
        #expect(encodedDelta.contains("\"t\":\"values\""))
        #expect(encodedDelta.contains("\"rev\":42"))
        #expect(encodedDelta.contains("\"vals\""))
        #expect(encodedDelta.contains("\"v\":\"On\""))
        #expect(!encodedDelta.contains("\"values_revision\""))
        #expect(!encodedDelta.contains("\"value\""))
        #expect(!encodedDelta.contains("light.kitchen"))
        #expect(!encodedDelta.contains("server-1"))
    }

    @Test func overviewSectionEtagIncludesDomainMarker() throws {
        let entity = MagicItem(id: "sensor.temperature", serverId: "server-1", type: .entity, displayText: "Temperature")
        let config = GarminConfig(
            selectedServerId: "server-1",
            serverConfigs: [.init(serverId: "server-1", customSections: [
                .init(id: "custom-1", title: "Quick", items: [.init(item: entity)]),
            ])]
        )
        let source = GarminHomeOverviewSource(entityProvider: { [] }, areaProvider: { _ in [] })
        let section = try #require(try source.section(
            id: GarminOverviewSectionID.custom("custom-1"),
            config: config,
            itemInfo: { _ in nil }
        ))
        let sameWithoutDomain = GarminOverviewSection(
            id: section.id,
            title: section.title,
            etag: GarminConfig.fnv1a64Hex(section.items.map { "\($0.id)|\($0.label)|\($0.type.rawValue)|\($0.cap ?? 0)|\($0.confirmation?.rawValue ?? "")|" }.joined(separator: "\n")),
            items: section.items.map {
                GarminOverviewItem(id: $0.id, label: $0.label, type: $0.type, cap: $0.cap, confirmation: $0.confirmation)
            }
        )

        #expect(section.items.first?.domain == "sn")
        #expect(section.etag != sameWithoutDomain.etag)
    }

    @Test func areaDetailPaginatesWithOffsetsAndPageSpecificEtags() throws {
        let entities = (0..<40).map { index in
            entity("sensor.item_\(index)", name: String(format: "Item %02d", index), domain: "sensor")
        }
        let source = GarminHomeOverviewSource(
            entityProvider: { entities },
            areaProvider: { _ in [area("kitchen", name: "Kitchen", entities: Set(entities.map(\.entityId)))] }
        )
        let config = GarminConfig(selectedServerId: "server-1")

        let first = try #require(try source.section(
            id: GarminOverviewSectionID.area("kitchen"),
            config: config,
            itemInfo: { _ in nil },
            offset: 0,
            limit: 15
        ))
        let second = try #require(try source.section(
            id: GarminOverviewSectionID.area("kitchen"),
            config: config,
            itemInfo: { _ in nil },
            offset: 15,
            limit: 15
        ))
        let third = try #require(try source.section(
            id: GarminOverviewSectionID.area("kitchen"),
            config: config,
            itemInfo: { _ in nil },
            offset: 29,
            limit: 15
        ))

        #expect(first.items.count == 15)
        #expect(first.previousOffset == nil)
        #expect(first.nextOffset == 15)
        #expect(second.items.count == 14)
        #expect(second.pageLimit == 14)
        #expect(second.previousOffset == 0)
        #expect(second.nextOffset == 29)
        #expect(third.items.count == 11)
        #expect(third.pageLimit == 15)
        #expect(third.previousOffset == 15)
        #expect(third.nextOffset == nil)
        #expect(first.etag != second.etag)
        #expect(second.etag != third.etag)
    }

    @Test func api50LastPageUsesSpareNavigationSlot() throws {
        let entities = (0..<30).map { index in
            entity("sensor.item_\(index)", name: String(format: "Item %02d", index), domain: "sensor")
        }
        let source = GarminHomeOverviewSource(
            entityProvider: { entities },
            areaProvider: { _ in [area("kitchen", name: "Kitchen", entities: Set(entities.map(\.entityId)))] }
        )
        let config = GarminConfig(selectedServerId: "server-1")

        let last = try #require(try source.section(
            id: GarminOverviewSectionID.area("kitchen"),
            config: config,
            itemInfo: { _ in nil },
            offset: 15,
            limit: 15
        ))

        #expect(last.items.count == 15)
        #expect(last.pageLimit == 15)
        #expect(last.previousOffset == 0)
        #expect(last.nextOffset == nil)
    }

    @Test func pageEtagChangesOnlyForCurrentPageRows() throws {
        let entities = (0..<20).map { index in
            entity("sensor.item_\(index)", name: String(format: "Item %02d", index), domain: "sensor")
        }
        let changedOffPage = entities.enumerated().map { index, item in
            index == 17 ? entity(item.entityId, name: item.name, domain: item.domain, deviceClass: "temperature") : item
        }
        let changedOnPage = entities.enumerated().map { index, item in
            index == 1 ? entity(item.entityId, name: "Changed on page", domain: item.domain) : item
        }
        let config = GarminConfig(selectedServerId: "server-1")
        func source(_ values: [HAAppEntity]) -> GarminHomeOverviewSource {
            GarminHomeOverviewSource(
                entityProvider: { values },
                areaProvider: { _ in [area("kitchen", name: "Kitchen", entities: Set(values.map(\.entityId)))] }
            )
        }

        let original = try #require(try source(entities).section(id: GarminOverviewSectionID.area("kitchen"), config: config, itemInfo: { _ in nil }, offset: 0, limit: 15))
        let offPage = try #require(try source(changedOffPage).section(id: GarminOverviewSectionID.area("kitchen"), config: config, itemInfo: { _ in nil }, offset: 0, limit: 15))
        let onPage = try #require(try source(changedOnPage).section(id: GarminOverviewSectionID.area("kitchen"), config: config, itemInfo: { _ in nil }, offset: 0, limit: 15))

        #expect(original.etag == offPage.etag)
        #expect(original.etag != onPage.etag)
    }

    private func entity(
        _ entityId: String,
        name: String,
        domain: String,
        deviceClass: String? = nil,
        serverId: String = "server-1"
    ) -> HAAppEntity {
        HAAppEntity(
            id: "\(serverId)-\(entityId)",
            entityId: entityId,
            serverId: serverId,
            domain: domain,
            name: name,
            icon: nil,
            rawDeviceClass: deviceClass
        )
    }

    private func area(_ areaId: String, name: String, entities: Set<String>) -> AppArea {
        AppArea(
            id: "server-1-\(areaId)",
            serverId: "server-1",
            areaId: areaId,
            name: name,
            aliases: [],
            picture: nil,
            icon: nil,
            sortOrder: nil,
            entities: entities
        )
    }

    private func summaryProvider(
        registries: [AppEntityRegistry] = [],
        panels: [AppPanel] = [],
        states: [GarminHomeSummaryEntityState] = []
    ) -> GarminHomeSummaryProvider {
        GarminHomeSummaryProvider(
            registryProvider: { _ in registries },
            panelProvider: { _ in panels },
            stateProvider: { _ in states }
        )
    }

    private func panel(_ path: String) -> AppPanel {
        AppPanel(
            serverId: "server-1",
            title: path,
            path: path,
            component: path,
            showInSidebar: true
        )
    }

    private func registry(
        entityId: String,
        hiddenBy: String? = nil,
        disabledBy: String? = nil,
        entityCategory: String? = nil
    ) -> AppEntityRegistry {
        AppEntityRegistry(serverId: "server-1", registry: EntityRegistryEntry(
            uniqueId: "uid-\(entityId)",
            entityId: entityId,
            platform: nil,
            configEntryId: nil,
            deviceId: nil,
            areaId: nil,
            disabledBy: disabledBy,
            hiddenBy: hiddenBy,
            entityCategory: entityCategory,
            name: nil,
            originalName: nil,
            icon: nil,
            originalIcon: nil,
            aliases: nil,
            labels: nil,
            deviceClass: nil,
            originalDeviceClass: nil,
            capabilities: nil,
            supportedFeatures: nil,
            unitOfMeasurement: nil,
            options: nil,
            translationKey: nil,
            hasEntityName: nil
        ))
    }
}
