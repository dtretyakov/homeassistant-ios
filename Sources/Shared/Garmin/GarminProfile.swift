import Foundation

public struct GarminProfile: Codable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    public let actions: [GarminProfileAction]
    public let statuses: [GarminProfileStatus]

    public init(
        version: Int = GarminProfile.currentVersion,
        actions: [GarminProfileAction] = [],
        statuses: [GarminProfileStatus] = []
    ) {
        self.version = version
        self.actions = actions
        self.statuses = statuses
    }

    public init(config: GarminConfig, itemInfo: (MagicItem) -> MagicItem.Info?) {
        self.init(
            actions: config.actionItems.compactMap { item in
                guard GarminSupportedDomains.supportsAction(item) else { return nil }
                let info = itemInfo(item)
                return GarminProfileAction(
                    id: GarminConfig.opaqueActionId(for: item),
                    label: item.name(info: info ?? .fallback(for: item)),
                    iconName: item.customization?.icon ?? info?.iconName,
                    requiresConfirmation: item.customization?.requiresConfirmation ?? false
                )
            },
            statuses: config.statusItems.map { item in
                let info = itemInfo(item)
                return GarminProfileStatus(
                    id: GarminConfig.opaqueStatusId(for: item),
                    label: item.name(info: info ?? .fallback(for: item)),
                    iconName: item.customization?.icon ?? info?.iconName
                )
            }
        )
    }
}

public struct GarminProfileAction: Codable, Equatable {
    public let id: String
    public let label: String
    public let iconName: String?
    public let requiresConfirmation: Bool

    public init(id: String, label: String, iconName: String? = nil, requiresConfirmation: Bool = false) {
        self.id = id
        self.label = label
        self.iconName = iconName
        self.requiresConfirmation = requiresConfirmation
    }
}

public struct GarminProfileStatus: Codable, Equatable {
    public let id: String
    public let label: String
    public let iconName: String?

    public init(id: String, label: String, iconName: String? = nil) {
        self.id = id
        self.label = label
        self.iconName = iconName
    }
}

public struct GarminStatusSnapshot: Codable, Equatable {
    public let statuses: [GarminStatusValue]

    public init(statuses: [GarminStatusValue]) {
        self.statuses = statuses
    }

    public init(
        config: GarminConfig,
        itemInfo: (MagicItem) -> MagicItem.Info?,
        valueProvider: (MagicItem) -> String?
    ) {
        self.init(statuses: config.statusItems.map { item in
            let info = itemInfo(item)
            return GarminStatusValue(
                id: GarminConfig.opaqueStatusId(for: item),
                label: item.name(info: info ?? .fallback(for: item)),
                value: valueProvider(item) ?? "",
                iconName: item.customization?.icon ?? info?.iconName
            )
        })
    }
}

public struct GarminStatusValue: Codable, Equatable {
    public let id: String
    public let label: String
    public let value: String
    public let iconName: String?

    public init(id: String, label: String, value: String, iconName: String? = nil) {
        self.id = id
        self.label = label
        self.value = value
        self.iconName = iconName
    }
}

private extension MagicItem.Info {
    static func fallback(for item: MagicItem) -> MagicItem.Info {
        .init(id: item.type.rawValue, name: item.displayText ?? item.type.rawValue, iconName: "")
    }
}
