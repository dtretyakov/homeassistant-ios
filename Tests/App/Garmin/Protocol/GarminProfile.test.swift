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

        #expect(GarminProtocolVersion.current == 2)
        #expect(getSection.type == .getSection)
        #expect(getSection.id == "root")
        #expect(getSection.etag == "r1")
        #expect(getSection.correlationId == "h125")
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
            values: [.init(id: "e_status1", value: "20 C")]
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
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "switch") == "sw")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "input_boolean") == "ib")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "cover") == "cv")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "lock") == "lk")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "alarm_control_panel") == "al")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "binary_sensor") == "bs")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "sensor") == "sn")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "person") == "p")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "device_tracker") == "dt")
        #expect(GarminSupportedDomains.compactDomainCode(rawDomain: "media_player") == nil)
    }

    @Test func notModifiedMessagesUseFlatCompactKeys() throws {
        let message = GarminOutboundMessage(
            type: .sectionNotModified,
            id: GarminOverviewSectionID.root,
            correlationId: "h123"
        )

        let dictionary = try GarminPayloadCodec.encodeOutboundDictionary(message)
        let encoded = try String(decoding: JSONSerialization.data(withJSONObject: dictionary), as: UTF8.self)

        #expect(dictionary["t"] as? String == "same")
        #expect(dictionary["id"] as? String == GarminOverviewSectionID.root)
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

        #expect(GarminProtocolVersion.current == 2)
        #expect(dictionary["v"] as? Int == 2)
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
            areaProvider: { _ in [area("kitchen", name: "Kitchen", entities: ["light.kitchen"])] }
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
            id: GarminOverviewSectionID.summary("lights"),
            config: config,
            itemInfo: { _ in nil },
            valueProvider: { values[$0.id] }
        ))

        #expect(areas.items.map(\.type) == [.section])
        #expect(areaDetail.items.map(\.type) == [.item])
        #expect(areaDetail.items.map(\.cap) == [GarminConfig.valueCapability | GarminConfig.actionCapability])
        #expect(areaDetail.items.map(\.domain) == ["l"])
        #expect(areaDetail.values == [.init(id: GarminConfig.opaqueEntityId(serverId: "server-1", entityId: "light.kitchen"), value: "on")])
        #expect(summaries.items.first?.type == .section)
        #expect(lights.items.map(\.label) == ["Kitchen"])
        #expect(lights.items.map(\.domain) == ["l"])
        #expect(lights.values == [.init(id: GarminConfig.opaqueEntityId(serverId: "server-1", entityId: "light.kitchen"), value: "on")])
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
}
