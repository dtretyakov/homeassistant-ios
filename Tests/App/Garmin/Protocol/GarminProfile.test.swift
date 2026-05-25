import Foundation
@testable import HomeAssistant
@testable import Shared
import Testing

struct GarminProfileTests {
    @Test func inboundPingDictionaryDecodes() throws {
        let message = try GarminPayloadCodec.decodeInboundDictionary([
            "type": "ping",
            "id": "h123",
        ])

        #expect(message == GarminInboundMessage(type: .ping, correlationId: "h123"))
    }

    @Test func connectionStatusEncodingUsesFlatCompactKeys() throws {
        let message = GarminOutboundMessage(
            type: .connectionStatus,
            connectionStatus: .init(correlationId: "h123", state: .success)
        )
        let dictionary = try GarminPayloadCodec.encodeOutboundDictionary(message)
        let encoded = try String(decoding: JSONSerialization.data(withJSONObject: dictionary), as: UTF8.self)

        #expect(encoded.contains("\"type\":\"connection_status\""))
        #expect(encoded.contains("\"id\":\"h123\""))
        #expect(encoded.contains("\"state\":\"ok\""))
        #expect(!encoded.contains("\"connection_status\""))
        #expect(!encoded.contains("\"correlation_id\""))
        #expect(!encoded.contains("\"max_payload_bytes\""))
        #expect(dictionary["id"] as? String == "h123")
    }

    @Test func payloadByteLimitCanRejectLargeOutboundMessage() throws {
        let oversizedLabel = String(repeating: "A", count: GarminPayloadLimits.outboundMessageBytes)
        let profile = GarminProfile(actions: [
            .init(id: "garmin_action_1", label: oversizedLabel),
        ])
        let message = GarminOutboundMessage(type: .profileSync, profile: profile)

        #expect(try GarminPayloadCodec.encodedByteCount(message) > GarminPayloadLimits.outboundMessageBytes)
    }

    @Test func profileDoesNotExposeHomeAssistantInternals() throws {
        let item = MagicItem(
            id: "light.secret_room",
            serverId: "server-secret",
            type: .entity,
            displayText: "Secret room"
        )
        let config = GarminConfig(actionItems: [item], statusItems: [item])

        let profile = GarminProfile(config: config) { _ in
            MagicItem.Info(id: "server-secret-light.secret_room", name: "Secret room", iconName: "mdi:lightbulb")
        }
        let encoded = try String(decoding: JSONEncoder().encode(profile), as: UTF8.self)

        #expect(!encoded.contains("light.secret_room"))
        #expect(!encoded.contains("server-secret"))
        #expect(!encoded.contains("http://"))
        #expect(!encoded.contains("https://"))
        #expect(!encoded.contains("access_token"))
        #expect(!encoded.contains("refresh_token"))
        #expect(!encoded.contains("webhook"))
    }

    @Test func profilePreservesActionOrderLabelsAndConfirmation() throws {
        let first = MagicItem(
            id: "scene.movie",
            serverId: "server-1",
            type: .scene,
            customization: .init(requiresConfirmation: true),
            displayText: "Movie"
        )
        let second = MagicItem(
            id: "light.kitchen",
            serverId: "server-1",
            type: .entity,
            customization: .init(requiresConfirmation: false),
            displayText: "Kitchen"
        )
        let config = GarminConfig(actionItems: [first, second])

        let profile = GarminProfile(config: config) { _ in nil }

        #expect(profile.actions.map(\.label) == ["Movie", "Kitchen"])
        #expect(profile.actions.map(\.requiresConfirmation) == [true, false])
    }

    @Test func profileEncodingUsesStableSnakeCaseKeys() throws {
        let profile = GarminProfile(
            actions: [
                .init(
                    id: "garmin_action_1",
                    label: "Garage",
                    iconName: "mdi:garage",
                    requiresConfirmation: true
                ),
            ],
            statuses: [
                .init(id: "garmin_status_1", label: "Garage", iconName: "mdi:garage"),
            ]
        )
        let encoded = try String(decoding: JSONEncoder().encode(profile), as: UTF8.self)

        #expect(encoded.contains("\"icon_name\""))
        #expect(encoded.contains("\"requires_confirmation\""))
        #expect(!encoded.contains("\"iconName\""))
        #expect(!encoded.contains("\"requiresConfirmation\""))
    }

    @Test func profilePreservesStatusOrderLabelsAndOpaqueIds() throws {
        let first = MagicItem(
            id: "sensor.temperature",
            serverId: "server-1",
            type: .entity,
            displayText: "Temperature"
        )
        let second = MagicItem(
            id: "binary_sensor.front_door",
            serverId: "server-1",
            type: .entity,
            displayText: "Front door"
        )
        let config = GarminConfig(statusItems: [first, second])

        let profile = GarminProfile(config: config) { _ in nil }

        #expect(profile.statuses.map(\.label) == ["Temperature", "Front door"])
        #expect(profile.statuses.map(\.id) == [
            GarminConfig.opaqueStatusId(for: first),
            GarminConfig.opaqueStatusId(for: second),
        ])
    }
}
