@testable import Shared
import Testing

struct GarminProfileTests {
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
}
