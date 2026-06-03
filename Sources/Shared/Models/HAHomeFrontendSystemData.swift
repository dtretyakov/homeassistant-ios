import Foundation
import HAKit

public struct HAHomeFrontendSystemData: Codable, Equatable, HADataDecodable {
    public let favoriteEntities: [String]
    public let hideSuggestedEntities: Bool

    public init(
        favoriteEntities: [String] = [],
        hideSuggestedEntities: Bool = false
    ) {
        self.favoriteEntities = favoriteEntities
        self.hideSuggestedEntities = hideSuggestedEntities
    }

    public init(data: HAData) throws {
        guard case let .dictionary(dictionary) = data,
              let value = dictionary["value"] as? [String: Any] else {
            self.init()
            return
        }
        self.init(
            favoriteEntities: Self.stringArray(from: value["favorite_entities"]),
            hideSuggestedEntities: value["hide_suggested_entities"] as? Bool ?? false
        )
    }

    private static func stringArray(from value: Any?) -> [String] {
        value as? [String]
            ?? (value as? [Any])?.compactMap { $0 as? String }
            ?? []
    }
}
