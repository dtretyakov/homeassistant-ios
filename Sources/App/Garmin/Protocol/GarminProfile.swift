import Foundation
import Shared

public struct GarminStatusSnapshot: Codable, Equatable {
    public let statuses: [GarminStatusValue]
    public let updatedAt: TimeInterval

    public init(statuses: [GarminStatusValue], updatedAt: TimeInterval = Date().timeIntervalSince1970) {
        self.statuses = statuses
        self.updatedAt = updatedAt
    }

    public init(
        config: GarminConfig,
        itemInfo: (MagicItem) -> MagicItem.Info?,
        valueProvider: (MagicItem) -> String?,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.init(statuses: config.customStatusItems.prefix(GarminConfig.maxStatusItems).compactMap { item in
            guard GarminSupportedDomains.supportsStatus(item) else { return nil }
            let info = itemInfo(item)
            return GarminStatusValue(
                id: GarminConfig.opaqueItemId(for: item),
                label: item.name(info: info ?? .fallback(for: item)),
                value: valueProvider(item) ?? "",
                iconName: item.customization?.icon ?? info?.iconName
            )
        }, updatedAt: updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case statuses
        case updatedAt = "updated_at"
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

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case value
        case iconName = "icon_name"
    }
}

public enum GarminOverviewSectionID {
    public static let root = "root"
    public static let areas = "areas"
    public static let summaries = "sum"

    public static func area(_ areaId: String) -> String {
        "area:\(areaId)"
    }

    public static func summary(_ id: String) -> String {
        "summary:\(id)"
    }

    public static func custom(_ id: String) -> String {
        GarminConfig.compactCustomSectionId(for: id)
    }
}

public enum GarminOverviewItemType: String, Codable, Equatable {
    case section
    case item
}

public enum GarminOverviewActionConfirmation: String, Codable, Equatable {
    case none
    case required
}

public struct GarminOverviewSection: Codable, Equatable {
    public let id: String
    public let title: String
    public let etag: String
    public let items: [GarminOverviewItem]
    public let values: [GarminOverviewValue]
    public let hasMore: Bool

    public init(
        id: String,
        title: String,
        etag: String,
        items: [GarminOverviewItem],
        values: [GarminOverviewValue] = [],
        hasMore: Bool = false
    ) {
        self.id = id
        self.title = title
        self.etag = etag
        self.items = Array(items.prefix(GarminConfig.maxSectionItems))
        self.values = Array(values.prefix(GarminConfig.maxSectionItems))
        self.hasMore = hasMore || items.count > GarminConfig.maxSectionItems
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case etag
        case items
        case values = "vals"
        case hasMore = "has_more"
    }
}

public struct GarminOverviewItem: Codable, Equatable {
    public let id: String
    public let label: String
    public let type: GarminOverviewItemType
    public let cap: Int?
    public let confirmation: GarminOverviewActionConfirmation?

    public init(
        id: String,
        label: String,
        type: GarminOverviewItemType,
        cap: Int? = nil,
        confirmation: GarminOverviewActionConfirmation? = nil
    ) {
        self.id = id
        self.label = label
        self.type = type
        self.cap = cap
        self.confirmation = confirmation
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case type
        case cap
        case confirmation
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(type, forKey: .type)
        if let cap, cap > 0 {
            try container.encode(cap, forKey: .cap)
        }
        if confirmation == .required {
            try container.encode(confirmation, forKey: .confirmation)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        type = try container.decode(GarminOverviewItemType.self, forKey: .type)
        cap = try container.decodeIfPresent(Int.self, forKey: .cap)
        confirmation = try container.decodeIfPresent(GarminOverviewActionConfirmation.self, forKey: .confirmation)
    }
}

public struct GarminOverviewValue: Codable, Equatable {
    public let id: String
    public let value: String

    public init(id: String, value: String) {
        self.id = id
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case id
        case value = "v"
    }
}

final class GarminOverviewVisibleEntityRegistry {
    static let shared = GarminOverviewVisibleEntityRegistry()

    private let lock = NSLock()
    private var entitiesByItemId: [String: MagicItem] = [:]
    private var visibleIds: Set<String> = []

    func register(entity: HAAppEntity) {
        register(
            itemId: GarminConfig.opaqueEntityId(serverId: entity.serverId, entityId: entity.entityId),
            item: MagicItem(
                id: entity.entityId,
                serverId: entity.serverId,
                type: .entity,
                displayText: entity.name
            )
        )
    }

    func register(item: MagicItem) {
        register(
            itemId: GarminConfig.opaqueItemId(for: item),
            item: item
        )
    }

    func setVisible(ids: Set<String>) {
        lock.lock()
        visibleIds = ids
        lock.unlock()
    }

    func clearVisible() {
        lock.lock()
        visibleIds.removeAll()
        lock.unlock()
    }

    func visibleStatusItems(limit: Int) -> [MagicItem] {
        lock.lock()
        let ids = visibleIds
        let items = ids.compactMap { entitiesByItemId[$0] }
        lock.unlock()

        var seen = Set<String>()
        return items
            .sorted { $0.serverUniqueId < $1.serverUniqueId }
            .filter { item in
                guard GarminSupportedDomains.supportsStatus(item), !seen.contains(item.serverUniqueId) else { return false }
                seen.insert(item.serverUniqueId)
                return true
            }
            .prefix(limit)
            .map { $0 }
    }

    private func register(itemId: String, item: MagicItem) {
        lock.lock()
        entitiesByItemId[itemId] = item
        lock.unlock()
    }
}

final class GarminOverviewActionRegistry {
    static let shared = GarminOverviewActionRegistry()

    private let lock = NSLock()
    private var actionsById: [String: MagicItem] = [:]

    func register(item: MagicItem) {
        lock.lock()
        actionsById[GarminConfig.opaqueItemId(for: item)] = item
        lock.unlock()
    }

    func action(for id: String) -> MagicItem? {
        lock.lock()
        let item = actionsById[id]
        lock.unlock()
        return item
    }

    func clear() {
        lock.lock()
        actionsById.removeAll()
        lock.unlock()
    }
}

final class GarminHomeOverviewSource {
    typealias EntityProvider = () throws -> [HAAppEntity]
    typealias AreaProvider = (String) throws -> [AppArea]
    typealias ValueProvider = (GarminOverviewItem) -> String?

    private let entityProvider: EntityProvider
    private let areaProvider: AreaProvider

    init(
        entityProvider: @escaping EntityProvider = { try HAAppEntity.config() },
        areaProvider: @escaping AreaProvider = { serverId in try AppArea.fetchAreas(for: serverId) }
    ) {
        self.entityProvider = entityProvider
        self.areaProvider = areaProvider
    }

    func section(
        id: String,
        config: GarminConfig,
        itemInfo: (MagicItem) -> MagicItem.Info?,
        valueProvider: ValueProvider = { _ in nil }
    ) throws -> GarminOverviewSection? {
        let serverId = config.selectedServerId
            ?? config.customItems.first?.serverId
        guard let serverId else { return nil }

        if id == GarminOverviewSectionID.root {
            return try rootSection(config: config, itemInfo: itemInfo, serverId: serverId, valueProvider: valueProvider)
        } else if id == GarminOverviewSectionID.areas {
            return try areasSection(serverId: serverId)
        } else if id.hasPrefix("area:") {
            let areaId = String(id.dropFirst("area:".count))
            return try areaDetailSection(serverId: serverId, areaId: areaId, valueProvider: valueProvider)
        } else if id == GarminOverviewSectionID.summaries || id == "summaries" {
            return try summariesSection(serverId: serverId, valueProvider: valueProvider)
        } else if id.hasPrefix("summary:") {
            let summaryId = String(id.dropFirst("summary:".count))
            return try summaryDetailSection(serverId: serverId, summaryId: summaryId, valueProvider: valueProvider)
        } else if let custom = config.customSections.first(where: { GarminOverviewSectionID.custom($0.id) == id || "custom:\($0.id)" == id }) {
            return customSection(id: custom.id, serverId: serverId, config: config, itemInfo: itemInfo, valueProvider: valueProvider)
        }

        return nil
    }

    func valueItems(
        id: String,
        config: GarminConfig,
        itemInfo: (MagicItem) -> MagicItem.Info?
    ) throws -> [MagicItem] {
        let serverId = config.selectedServerId
            ?? config.customItems.first?.serverId
        guard let serverId else { return [] }

        if id.hasPrefix("area:") {
            let areaId = String(id.dropFirst("area:".count))
            guard let area = try areaProvider(serverId).first(where: { $0.areaId == areaId }) else { return [] }
            let allowed = area.entities
            return try entityProvider()
                .filter { $0.serverId == serverId && allowed.contains($0.entityId) && GarminSupportedDomains.supportsStatus(rawDomain: $0.domain) }
                .sorted(by: sortEntity)
                .map(magicItem)
        } else if id.hasPrefix("summary:") {
            let summaryId = String(id.dropFirst("summary:".count))
            return try entityProvider()
                .filter { $0.serverId == serverId && summaryMatches(entity: $0, summaryId: summaryId) && GarminSupportedDomains.supportsStatus(rawDomain: $0.domain) }
                .sorted(by: sortEntity)
                .map(magicItem)
        } else if let custom = config.customSections.first(where: { GarminOverviewSectionID.custom($0.id) == id || "custom:\($0.id)" == id }) {
            return custom.items
                .map(\.item)
                .filter { $0.serverId == serverId && GarminSupportedDomains.supportsStatus($0) }
        }

        _ = itemInfo
        return []
    }

    private func rootSection(
        config: GarminConfig,
        itemInfo: (MagicItem) -> MagicItem.Info?,
        serverId: String,
        valueProvider: ValueProvider
    ) throws -> GarminOverviewSection {
        var items: [GarminOverviewItem] = []
        if config.areasSectionEnabled, let section = try section(id: GarminOverviewSectionID.areas, config: config, itemInfo: itemInfo) {
            items.append(sectionItem(for: section))
        }
        if config.summariesSectionEnabled, let section = try section(id: GarminOverviewSectionID.summaries, config: config, itemInfo: itemInfo) {
            items.append(sectionItem(for: section))
        }
        for section in config.customSections.prefix(GarminConfig.maxCustomSections) {
            guard let overviewSection = customSection(
                id: section.id,
                serverId: serverId,
                config: config,
                itemInfo: itemInfo,
                valueProvider: valueProvider
            ) else { continue }
            items.append(sectionItem(for: overviewSection))
        }

        _ = serverId
        return overviewSection(id: GarminOverviewSectionID.root, title: "Home", items: items)
    }

    private func areasSection(serverId: String) throws -> GarminOverviewSection {
        let items = try areaProvider(serverId).map { area in
            GarminOverviewItem(
                id: "area:\(area.areaId)",
                label: area.name,
                type: .section
            )
        }
        return overviewSection(id: GarminOverviewSectionID.areas, title: "Areas", items: items)
    }

    private func areaDetailSection(serverId: String, areaId: String, valueProvider: ValueProvider) throws -> GarminOverviewSection? {
        guard let area = try areaProvider(serverId).first(where: { $0.areaId == areaId }) else { return nil }
        let allowed = area.entities
        let items = try entityProvider()
            .filter { $0.serverId == serverId && allowed.contains($0.entityId) && GarminSupportedDomains.supportsStatus(rawDomain: $0.domain) }
            .sorted(by: sortEntity)
            .map(statusItem)
        return overviewSection(id: GarminOverviewSectionID.area(areaId), title: area.name, items: items, valueProvider: valueProvider)
    }

    private func summariesSection(serverId: String, valueProvider: ValueProvider) throws -> GarminOverviewSection {
        let entities = try entityProvider().filter { $0.serverId == serverId }
        let definitions = summaryDefinitions(entities: entities)
        let items = definitions.map { definition in
            GarminOverviewItem(
                id: "summary:\(definition.id)",
                label: definition.title,
                type: .section
            )
        }
        _ = valueProvider
        return overviewSection(id: GarminOverviewSectionID.summaries, title: "Summaries", items: items)
    }

    private func summaryDetailSection(serverId: String, summaryId: String, valueProvider: ValueProvider) throws -> GarminOverviewSection {
        let entities = try entityProvider().filter { $0.serverId == serverId }
        let items = summaryContributors(entities: entities, summaryId: summaryId, valueProvider: valueProvider)
            .sorted(by: sortEntity)
            .map(statusItem)
        let title = summaryTitle(summaryId)
        return overviewSection(id: GarminOverviewSectionID.summary(summaryId), title: title, items: items, valueProvider: valueProvider)
    }

    private func customSection(
        id: String,
        serverId: String,
        config: GarminConfig,
        itemInfo: (MagicItem) -> MagicItem.Info?,
        valueProvider: ValueProvider = { _ in nil }
    ) -> GarminOverviewSection? {
        guard let section = config.customSections.first(where: { $0.id == id }) else { return nil }
        let items = section.items.compactMap { customItem -> GarminOverviewItem? in
            guard customItem.item.serverId == serverId else { return nil }
            guard GarminConfig.capability(for: customItem.item) > 0 else { return nil }
            return item(customItem.item, itemInfo: itemInfo)
        }
        return overviewSection(id: GarminOverviewSectionID.custom(section.id), title: section.title, items: items, valueProvider: valueProvider)
    }

    private func overviewSection(
        id: String,
        title: String,
        items: [GarminOverviewItem],
        valueProvider: ValueProvider = { _ in nil }
    ) -> GarminOverviewSection {
        let values = items.compactMap { item -> GarminOverviewValue? in
            guard (item.cap ?? 0) & GarminConfig.valueCapability != 0 else { return nil }
            guard let value = valueProvider(item) else { return nil }
            return GarminOverviewValue(id: item.id, value: value)
        }
        return GarminOverviewSection(
            id: id,
            title: title,
            etag: etag(items.map { "\($0.id)|\($0.label)|\($0.type.rawValue)|\($0.cap ?? 0)|\($0.confirmation?.rawValue ?? "")" }),
            items: items,
            values: values
        )
    }

    private func sectionItem(for section: GarminOverviewSection) -> GarminOverviewItem {
        GarminOverviewItem(
            id: section.id,
            label: section.title,
            type: .section
        )
    }

    private func statusItem(_ entity: HAAppEntity) -> GarminOverviewItem {
        let item = magicItem(entity)
        register(item: item, capability: GarminConfig.capability(for: item))
        return GarminOverviewItem(
            id: GarminConfig.opaqueEntityId(serverId: entity.serverId, entityId: entity.entityId),
            label: entity.name,
            type: .item,
            cap: GarminConfig.capability(for: item),
            confirmation: confirmation(for: item)
        )
    }

    private func statusItem(item: MagicItem, itemInfo: (MagicItem) -> MagicItem.Info?) -> GarminOverviewItem {
        self.item(item, itemInfo: itemInfo)
    }

    private func item(_ item: MagicItem, itemInfo: (MagicItem) -> MagicItem.Info?) -> GarminOverviewItem {
        let info = itemInfo(item)
        let capability = GarminConfig.capability(for: item)
        register(item: item, capability: capability)
        return GarminOverviewItem(
            id: GarminConfig.opaqueItemId(for: item),
            label: item.name(info: info ?? .fallback(for: item)),
            type: .item,
            cap: capability,
            confirmation: confirmation(for: item)
        )
    }

    private func actionItem(_ entity: HAAppEntity) -> GarminOverviewItem {
        let item = magicItem(entity)
        let capability = GarminConfig.capability(for: item)
        register(item: item, capability: capability)
        return GarminOverviewItem(
            id: GarminConfig.opaqueItemId(for: item),
            label: entity.name,
            type: .item,
            cap: capability,
            confirmation: confirmation(for: item)
        )
    }

    private func actionItem(item: MagicItem, itemInfo: (MagicItem) -> MagicItem.Info?) -> GarminOverviewItem {
        self.item(item, itemInfo: itemInfo)
    }

    private func register(item: MagicItem, capability: Int) {
        if capability & GarminConfig.valueCapability != 0 {
            GarminOverviewVisibleEntityRegistry.shared.register(item: item)
        }
        if capability & GarminConfig.actionCapability != 0 {
            GarminOverviewActionRegistry.shared.register(item: item)
        }
    }

    private func confirmation(for item: MagicItem) -> GarminOverviewActionConfirmation? {
        guard GarminSupportedDomains.supportsAction(item) else { return nil }
        let requiresConfirmation = item.customization?.requiresConfirmation
            ?? GarminActionConfirmationPolicy.defaultRequiresConfirmation(for: item)
        return requiresConfirmation ? .required : nil
    }

    private func magicItemType(for domain: String) -> MagicItem.ItemType {
        switch domain {
        case Domain.script.rawValue: return .script
        case Domain.scene.rawValue: return .scene
        default: return .entity
        }
    }

    private func magicItem(_ entity: HAAppEntity) -> MagicItem {
        MagicItem(
            id: entity.entityId,
            serverId: entity.serverId,
            type: magicItemType(for: entity.domain),
            displayText: entity.name
        )
    }

    private func sortEntity(_ lhs: HAAppEntity, _ rhs: HAAppEntity) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func summaryDefinitions(entities: [HAAppEntity]) -> [(id: String, title: String, iconName: String)] {
        var definitions: [(String, String, String)] = []
        if entities.contains(where: { $0.domain == "light" }) { definitions.append(("lights", "Lights", "mdi:lightbulb")) }
        if entities.contains(where: { $0.domain == "cover" }) { definitions.append(("covers", "Covers", "mdi:window-shutter")) }
        if entities.contains(where: { $0.domain == "lock" }) { definitions.append(("locks", "Locks", "mdi:lock")) }
        if entities.contains(where: { $0.domain == "binary_sensor" && ($0.rawDeviceClass == "door" || $0.rawDeviceClass == "window") }) {
            definitions.append(("openings", "Doors & windows", "mdi:door-open"))
        }
        if entities.contains(where: { $0.domain == "person" || $0.domain == "device_tracker" }) { definitions.append(("people", "People", "mdi:account")) }
        return definitions
    }

    private func summaryMatches(entity: HAAppEntity, summaryId: String) -> Bool {
        switch summaryId {
        case "lights": return entity.domain == "light"
        case "covers": return entity.domain == "cover"
        case "locks": return entity.domain == "lock"
        case "openings": return entity.domain == "binary_sensor" && (entity.rawDeviceClass == "door" || entity.rawDeviceClass == "window")
        case "people": return entity.domain == "person" || entity.domain == "device_tracker"
        default: return false
        }
    }

    private func summaryContributors(
        entities: [HAAppEntity],
        summaryId: String,
        valueProvider: ValueProvider
    ) -> [HAAppEntity] {
        entities.filter { entity in
            guard summaryMatches(entity: entity, summaryId: summaryId) else { return false }
            let item = statusItem(entity)
            guard let value = valueProvider(item)?.lowercased(), !value.isEmpty else { return false }
            switch summaryId {
            case "lights":
                return value == "on"
            case "covers", "openings":
                return value == "open" || value == "opening" || value == "on"
            case "locks":
                return value == "unlocked" || value == "unlocking" || value == "jammed" || value == "on"
            case "people":
                return value == "home"
            default:
                return false
            }
        }
    }

    private func summaryValue(summaryId: String, count: Int) -> String {
        switch summaryId {
        case "lights": return "\(count) on"
        case "covers": return "\(count) open"
        case "locks": return "\(count) unlocked"
        case "openings": return "\(count) open"
        case "people": return "\(count) home"
        default: return "\(count)"
        }
    }

    private func summaryTitle(_ summaryId: String) -> String {
        switch summaryId {
        case "lights": return "Lights"
        case "covers": return "Covers"
        case "locks": return "Locks"
        case "openings": return "Doors & windows"
        case "people": return "People"
        default: return "Summary"
        }
    }

    private func etag(_ parts: [String]) -> String {
        GarminConfig.fnv1a64Hex(parts.joined(separator: "\n"))
    }
}

private extension MagicItem.Info {
    static func fallback(for item: MagicItem) -> MagicItem.Info {
        .init(id: item.type.rawValue, name: item.displayText ?? item.type.rawValue, iconName: "")
    }
}
