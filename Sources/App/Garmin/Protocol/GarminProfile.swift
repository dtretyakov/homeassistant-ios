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
    public static let favorites = "fav"
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
    public let pageOffset: Int
    public let pageLimit: Int
    public let previousOffset: Int?
    public let nextOffset: Int?

    public init(
        id: String,
        title: String,
        etag: String,
        items: [GarminOverviewItem],
        values: [GarminOverviewValue] = [],
        pageOffset: Int = 0,
        pageLimit: Int = GarminConfig.maxSectionItems,
        previousOffset: Int? = nil,
        nextOffset: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.etag = etag
        self.items = Array(items.prefix(Self.sanitizedLimit(pageLimit)))
        self.values = values
        self.pageOffset = max(0, pageOffset)
        self.pageLimit = Self.sanitizedLimit(pageLimit)
        self.previousOffset = previousOffset
        self.nextOffset = nextOffset
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case etag
        case items
        case values = "vals"
        case pageOffset = "o"
        case pageLimit = "l"
        case previousOffset = "po"
        case nextOffset = "no"
    }

    public static func sanitizedLimit(_ limit: Int) -> Int {
        min(max(1, limit), GarminConfig.maxSectionItems)
    }
}

public struct GarminOverviewItem: Codable, Equatable {
    public let id: String
    public let label: String
    public let type: GarminOverviewItemType
    public let cap: Int?
    public let confirmation: GarminOverviewActionConfirmation?
    public let domain: String?
    public let actions: [GarminOverviewAction]

    public init(
        id: String,
        label: String,
        type: GarminOverviewItemType,
        cap: Int? = nil,
        confirmation: GarminOverviewActionConfirmation? = nil,
        domain: String? = nil,
        actions: [GarminOverviewAction] = []
    ) {
        self.id = id
        self.label = label
        self.type = type
        self.cap = cap
        self.confirmation = confirmation
        self.domain = domain
        self.actions = actions
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case type
        case cap
        case confirmation
        case domain = "d"
        case actions
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
        if type == .item, let domain {
            try container.encode(domain, forKey: .domain)
        }
        if type == .item, !actions.isEmpty {
            try container.encode(actions, forKey: .actions)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        type = try container.decode(GarminOverviewItemType.self, forKey: .type)
        cap = try container.decodeIfPresent(Int.self, forKey: .cap)
        confirmation = try container.decodeIfPresent(GarminOverviewActionConfirmation.self, forKey: .confirmation)
        domain = try container.decodeIfPresent(String.self, forKey: .domain)
        actions = try container.decodeIfPresent([GarminOverviewAction].self, forKey: .actions) ?? []
    }
}

public struct GarminOverviewAction: Codable, Equatable {
    public let id: String
    public let label: String
    public let confirmation: GarminOverviewActionConfirmation?
    public let primary: Bool

    public init(
        id: String,
        label: String,
        confirmation: GarminOverviewActionConfirmation? = nil,
        primary: Bool = false
    ) {
        self.id = id
        self.label = label
        self.confirmation = confirmation
        self.primary = primary
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case confirmation
        case primary
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        if confirmation == .required {
            try container.encode(confirmation, forKey: .confirmation)
        }
        if primary {
            try container.encode(primary, forKey: .primary)
        }
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
    typealias StateProvider = (String) -> [GarminHomeSummaryEntityState]

    private let entityProvider: EntityProvider
    private let areaProvider: AreaProvider
    private let favoritesProvider: GarminHomeFavoritesProviding
    private let summaryProvider: GarminHomeSummaryProviding
    private let stateProvider: StateProvider

    init(
        entityProvider: @escaping EntityProvider = { try HAAppEntity.config() },
        areaProvider: @escaping AreaProvider = { serverId in try AppArea.fetchAreas(for: serverId) },
        favoritesProvider: GarminHomeFavoritesProviding = GarminHomeFavoritesProvider(),
        summaryProvider: GarminHomeSummaryProviding = GarminHomeSummaryProvider(),
        stateProvider: @escaping StateProvider = { GarminHomeSummaryStateCache.shared.states(serverId: $0) }
    ) {
        self.entityProvider = entityProvider
        self.areaProvider = areaProvider
        self.favoritesProvider = favoritesProvider
        self.summaryProvider = summaryProvider
        self.stateProvider = stateProvider
    }

    func section(
        id: String,
        config: GarminConfig,
        itemInfo: (MagicItem) -> MagicItem.Info?,
        valueProvider: ValueProvider = { _ in nil },
        offset: Int = 0,
        limit: Int = GarminConfig.maxSectionItems
    ) throws -> GarminOverviewSection? {
        let serverId = config.selectedServerId
            ?? config.customItems.first?.serverId
        guard let serverId else { return nil }

        if id == GarminOverviewSectionID.root {
            return try rootSection(config: config, itemInfo: itemInfo, serverId: serverId, valueProvider: valueProvider, offset: offset, limit: limit)
        } else if id == GarminOverviewSectionID.favorites {
            return try favoritesSection(serverId: serverId, valueProvider: valueProvider, offset: offset, limit: limit)
        } else if id == GarminOverviewSectionID.areas {
            return try areasSection(serverId: serverId, offset: offset, limit: limit)
        } else if id.hasPrefix("area:") {
            let areaId = String(id.dropFirst("area:".count))
            return try areaDetailSection(serverId: serverId, areaId: areaId, valueProvider: valueProvider, offset: offset, limit: limit)
        } else if id == GarminOverviewSectionID.summaries || id == "summaries" {
            return try summariesSection(serverId: serverId, valueProvider: valueProvider, offset: offset, limit: limit)
        } else if id.hasPrefix("summary:") {
            let summaryId = String(id.dropFirst("summary:".count))
            guard summaryProvider.isSupportedSummaryId(summaryId) else {
                return nil
            }
            return try summaryDetailSection(serverId: serverId, summaryId: summaryId, valueProvider: valueProvider, offset: offset, limit: limit)
        } else if let custom = config.customSections.first(where: { GarminOverviewSectionID.custom($0.id) == id || "custom:\($0.id)" == id }) {
            return customSection(id: custom.id, serverId: serverId, config: config, itemInfo: itemInfo, valueProvider: valueProvider, offset: offset, limit: limit)
        }

        return nil
    }

    func valueItems(
        id: String,
        config: GarminConfig,
        itemInfo: (MagicItem) -> MagicItem.Info?,
        offset: Int = 0,
        limit: Int = GarminConfig.maxSectionItems
    ) throws -> [MagicItem] {
        let serverId = config.selectedServerId
            ?? config.customItems.first?.serverId
        guard let serverId else { return [] }

        if id == GarminOverviewSectionID.favorites {
            return pageSlice(try favoritesProvider.favorites(serverId: serverId, entities: entityProvider())
                .filter { GarminSupportedDomains.supportsStatus(rawDomain: $0.domain) }
                .map(magicItem), offset: offset, limit: limit)
        } else if id.hasPrefix("area:") {
            let areaId = String(id.dropFirst("area:".count))
            guard let area = try areaProvider(serverId).first(where: { $0.areaId == areaId }) else { return [] }
            let allowed = area.entities
            return pageSlice(try entityProvider()
                .filter { $0.serverId == serverId && allowed.contains($0.entityId) && GarminSupportedDomains.supportsStatus(rawDomain: $0.domain) }
                .sorted(by: sortEntity)
                .map(magicItem), offset: offset, limit: limit)
        } else if id.hasPrefix("summary:") {
            let summaryId = String(id.dropFirst("summary:".count))
            guard summaryProvider.isSupportedSummaryId(summaryId) else {
                return []
            }
            _ = offset
            _ = limit
            return []
        } else if let custom = config.customSections.first(where: { GarminOverviewSectionID.custom($0.id) == id || "custom:\($0.id)" == id }) {
            return pageSlice(custom.items
                .map(\.item)
                .filter { $0.serverId == serverId && GarminSupportedDomains.supportsStatus($0) }, offset: offset, limit: limit)
        }

        _ = itemInfo
        return []
    }

    private func rootSection(
        config: GarminConfig,
        itemInfo: (MagicItem) -> MagicItem.Info?,
        serverId: String,
        valueProvider: ValueProvider,
        offset: Int,
        limit: Int
    ) throws -> GarminOverviewSection {
        var items: [GarminOverviewItem] = []
        if config.favoritesSectionEnabled,
           let section = try section(
               id: GarminOverviewSectionID.favorites,
               config: config,
               itemInfo: itemInfo
           ),
           !section.items.isEmpty {
            items.append(sectionItem(for: section))
        }
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
                valueProvider: valueProvider,
                offset: 0,
                limit: GarminConfig.maxSectionItems
            ) else { continue }
            items.append(sectionItem(for: overviewSection))
        }

        _ = serverId
        return overviewSection(id: GarminOverviewSectionID.root, title: "Home", items: items, offset: offset, limit: limit)
    }

    private func favoritesSection(
        serverId: String,
        valueProvider: ValueProvider,
        offset: Int,
        limit: Int
    ) throws -> GarminOverviewSection {
        let items = try favoritesProvider.favorites(serverId: serverId, entities: entityProvider())
            .map(statusItem)
        return overviewSection(
            id: GarminOverviewSectionID.favorites,
            title: "Favorites",
            items: items,
            valueProvider: valueProvider,
            offset: offset,
            limit: limit
        )
    }

    private func areasSection(serverId: String, offset: Int, limit: Int) throws -> GarminOverviewSection {
        let items = try areaProvider(serverId).map { area in
            GarminOverviewItem(
                id: "area:\(area.areaId)",
                label: area.name,
                type: .section
            )
        }
        return overviewSection(id: GarminOverviewSectionID.areas, title: "Areas", items: items, offset: offset, limit: limit)
    }

    private func areaDetailSection(serverId: String, areaId: String, valueProvider: ValueProvider, offset: Int, limit: Int) throws -> GarminOverviewSection? {
        guard let area = try areaProvider(serverId).first(where: { $0.areaId == areaId }) else { return nil }
        let allowed = area.entities
        let items = try entityProvider()
            .filter { $0.serverId == serverId && allowed.contains($0.entityId) && GarminSupportedDomains.supportsStatus(rawDomain: $0.domain) }
            .sorted(by: sortEntity)
            .map(statusItem)
        return overviewSection(id: GarminOverviewSectionID.area(areaId), title: area.name, items: items, valueProvider: valueProvider, offset: offset, limit: limit)
    }

    private func summariesSection(serverId: String, valueProvider: ValueProvider, offset: Int, limit: Int) throws -> GarminOverviewSection {
        let entities = try entityProvider().filter { $0.serverId == serverId }
        let definitions = try summaryProvider.summaries(serverId: serverId, entities: entities)
        let valuesById = Dictionary(uniqueKeysWithValues: definitions.map { ("summary:\($0.id)", $0.value) })
        let items = definitions.map { definition in
            GarminOverviewItem(
                id: "summary:\(definition.id)",
                label: definition.title,
                type: .section
            )
        }
        _ = valueProvider
        return overviewSection(
            id: GarminOverviewSectionID.summaries,
            title: "Summaries",
            items: items,
            valueProvider: { valuesById[$0.id] },
            allowSectionValues: true,
            includeValuesInEtag: true,
            offset: offset,
            limit: limit
        )
    }

    private func summaryDetailSection(serverId: String, summaryId: String, valueProvider: ValueProvider, offset: Int, limit: Int) throws -> GarminOverviewSection {
        let detailItems = try summaryProvider.detailItems(
            serverId: serverId,
            summaryId: summaryId,
            entities: entityProvider()
        )
        detailItems.compactMap(\.valueItem).forEach {
            register(item: $0, capability: GarminConfig.capability(for: $0))
        }
        let valuesById = Dictionary(uniqueKeysWithValues: detailItems.compactMap { detailItem -> (String, String)? in
            guard let value = detailItem.value else { return nil }
            return (detailItem.item.id, value)
        })
        let title = summaryTitle(summaryId)
        _ = valueProvider
        return overviewSection(
            id: GarminOverviewSectionID.summary(summaryId),
            title: title,
            items: detailItems.map(\.item),
            valueProvider: { valuesById[$0.id] },
            includeValuesInEtag: true,
            offset: offset,
            limit: limit
        )
    }

    private func customSection(
        id: String,
        serverId: String,
        config: GarminConfig,
        itemInfo: (MagicItem) -> MagicItem.Info?,
        valueProvider: ValueProvider = { _ in nil },
        offset: Int,
        limit: Int
    ) -> GarminOverviewSection? {
        guard let section = config.customSections.first(where: { $0.id == id }) else { return nil }
        let items = section.items.compactMap { customItem -> GarminOverviewItem? in
            guard customItem.item.serverId == serverId else { return nil }
            guard capability(for: customItem.item) > 0 else { return nil }
            return item(customItem.item, itemInfo: itemInfo)
        }
        return overviewSection(id: GarminOverviewSectionID.custom(section.id), title: section.title, items: items, valueProvider: valueProvider, offset: offset, limit: limit)
    }

    private func overviewSection(
        id: String,
        title: String,
        items: [GarminOverviewItem],
        valueProvider: ValueProvider = { _ in nil },
        allowSectionValues: Bool = false,
        includeValuesInEtag: Bool = false,
        offset: Int = 0,
        limit: Int = GarminConfig.maxSectionItems
    ) -> GarminOverviewSection {
        let page = pagedItems(items, offset: offset, limit: limit)
        let values = page.items.compactMap { item -> GarminOverviewValue? in
            if item.type == .section, !allowSectionValues {
                return nil
            }
            if item.type == .item, (item.cap ?? 0) & GarminConfig.valueCapability == 0 {
                return nil
            }
            guard let value = valueProvider(item) else { return nil }
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return GarminOverviewValue(id: item.id, value: value)
        }
        let valueEtagParts = includeValuesInEtag ? values.map { "v:\($0.id)|\($0.value)" } : []
        return GarminOverviewSection(
            id: id,
            title: title,
            etag: etag([
                "id:\(id)",
                "o:\(page.offset)",
                "l:\(page.limit)",
                "po:\(page.previousOffset.map(String.init) ?? "")",
                "no:\(page.nextOffset.map(String.init) ?? "")",
            ] + page.items.map { item in
                let actions = item.actions
                    .map { "\($0.id),\($0.label),\($0.confirmation?.rawValue ?? ""),\($0.primary)" }
                    .joined(separator: ";")
                return "\(item.id)|\(item.label)|\(item.type.rawValue)|\(item.cap ?? 0)|\(item.confirmation?.rawValue ?? "")|\(item.domain ?? "")|\(actions)"
            } + valueEtagParts),
            items: page.items,
            values: values,
            pageOffset: page.offset,
            pageLimit: page.limit,
            previousOffset: page.previousOffset,
            nextOffset: page.nextOffset
        )
    }

    private func pageSlice<T>(_ items: [T], offset: Int, limit: Int) -> [T] {
        pagedItems(items, offset: offset, limit: limit).items
    }

    private func pagedItems<T>(_ items: [T], offset: Int, limit: Int) -> (items: [T], offset: Int, limit: Int, previousOffset: Int?, nextOffset: Int?) {
        let sanitizedLimit = GarminOverviewSection.sanitizedLimit(limit)
        let sanitizedOffset = min(max(0, offset), items.count)
        let realItemLimit = realItemLimit(itemsCount: items.count, offset: sanitizedOffset, limit: sanitizedLimit)
        let endIndex = min(items.count, sanitizedOffset + realItemLimit)
        let pageItems = Array(items[sanitizedOffset..<endIndex])
        let previousOffset: Int?
        if sanitizedOffset == 0 {
            previousOffset = nil
        } else if sanitizedOffset <= GarminConfig.maxSectionItems - 1 {
            previousOffset = 0
        } else {
            previousOffset = max(0, sanitizedOffset - previousPageStep(limit: sanitizedLimit))
        }
        let nextOffset = endIndex < items.count ? endIndex : nil
        return (pageItems, sanitizedOffset, realItemLimit, previousOffset, nextOffset)
    }

    private func realItemLimit(itemsCount: Int, offset: Int, limit: Int) -> Int {
        if limit == GarminConfig.maxSectionItems - 1, offset > 0, itemsCount - offset > limit {
            return limit - 1
        }
        return limit
    }

    private func previousPageStep(limit: Int) -> Int {
        if limit == GarminConfig.maxSectionItems - 1 {
            return limit - 1
        }
        return limit
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
        let capability = capability(for: item)
        register(item: item, capability: capability)
        return GarminOverviewItem(
            id: GarminConfig.opaqueEntityId(serverId: entity.serverId, entityId: entity.entityId),
            label: entity.name,
            type: .item,
            cap: capability,
            confirmation: confirmation(for: item),
            domain: GarminSupportedDomains.compactDomainCode(rawDomain: entity.domain),
            actions: actions(for: item)
        )
    }

    private func statusItem(item: MagicItem, itemInfo: (MagicItem) -> MagicItem.Info?) -> GarminOverviewItem {
        self.item(item, itemInfo: itemInfo)
    }

    private func item(_ item: MagicItem, itemInfo: (MagicItem) -> MagicItem.Info?) -> GarminOverviewItem {
        let info = itemInfo(item)
        let capability = capability(for: item)
        register(item: item, capability: capability)
        return GarminOverviewItem(
            id: GarminConfig.opaqueItemId(for: item),
            label: item.name(info: info ?? .fallback(for: item)),
            type: .item,
            cap: capability,
            confirmation: confirmation(for: item),
            domain: GarminSupportedDomains.compactDomainCode(for: item),
            actions: actions(for: item)
        )
    }

    private func actionItem(_ entity: HAAppEntity) -> GarminOverviewItem {
        let item = magicItem(entity)
        let capability = capability(for: item)
        register(item: item, capability: capability)
        return GarminOverviewItem(
            id: GarminConfig.opaqueItemId(for: item),
            label: entity.name,
            type: .item,
            cap: capability,
            confirmation: confirmation(for: item),
            domain: GarminSupportedDomains.compactDomainCode(rawDomain: entity.domain),
            actions: actions(for: item)
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

    private func capability(for item: MagicItem) -> Int {
        var capability = GarminConfig.capability(for: item)
        guard capability & GarminConfig.actionCapability != 0,
              item.type == .entity,
              item.domain == .mediaPlayer else {
            return capability
        }
        guard let state = stateProvider(item.serverId).first(where: { $0.entityId == item.id }),
              GarminDesiredStateActionResolver.actionId(
                  rawDomain: Domain.mediaPlayer.rawValue,
                  state: state.state,
                  attributes: state.attributes
              ) != nil else {
            capability &= ~GarminConfig.actionCapability
            return capability
        }
        return capability
    }

    private func confirmation(for item: MagicItem) -> GarminOverviewActionConfirmation? {
        guard GarminSupportedDomains.supportsAction(item) else { return nil }
        let requiresConfirmation = item.customization?.requiresConfirmation
            ?? GarminActionConfirmationPolicy.defaultRequiresConfirmation(for: item)
        return requiresConfirmation ? .required : nil
    }

    private func actions(for item: MagicItem) -> [GarminOverviewAction] {
        guard GarminSupportedDomains.supportsAction(item) else { return [] }
        let confirmation = confirmation(for: item)

        switch item.type {
        case .script, .scene:
            return [.init(id: Service.turnOn.rawValue, label: "Run", confirmation: confirmation, primary: true)]
        case .entity:
            guard let domain = item.domain else { return [] }
            let state = stateProvider(item.serverId).first(where: { $0.entityId == item.id })
            return actions(for: item, domain: domain, state: state, confirmation: confirmation)
        case .action, .folder, .assistPipeline, .assistPrompt:
            return []
        }
    }

    private func actions(
        for item: MagicItem,
        domain: Domain,
        state: GarminHomeSummaryEntityState?,
        confirmation: GarminOverviewActionConfirmation?
    ) -> [GarminOverviewAction] {
        let actionId = state.flatMap {
            GarminDesiredStateActionResolver.actionId(rawDomain: domain.rawValue, state: $0.state, attributes: $0.attributes)
        }
        let lockSupportsOpen = supportsLockOpen(state, itemServerId: item.serverId, itemId: item.id)
        let isPrimary = domain != .lock || !lockSupportsOpen
        var actions: [GarminOverviewAction] = []

        if domain == .lock, lockSupportsOpen {
            actions.append(.init(
                id: GarminDesiredStateActionResolver.openLockActionId,
                label: "Open",
                confirmation: confirmation,
                primary: true
            ))
        }

        if let actionId {
            actions.append(.init(
                id: actionId,
                label: label(for: actionId),
                confirmation: confirmation,
                primary: isPrimary
            ))
        }

        return actions
    }

    private func supportsLockOpen(_ state: GarminHomeSummaryEntityState?, itemServerId: String?, itemId: String?) -> Bool {
        if let state, GarminDesiredStateActionResolver.supportsLockOpen(state.attributes) {
            return true
        }
        guard let itemServerId, let itemId else { return false }
        return registrySupportedFeatures(serverId: itemServerId, entityId: itemId).map { ($0 & 1) != 0 } ?? false
    }

    private func registrySupportedFeatures(serverId: String, entityId: String) -> Int? {
        try? AppEntityRegistry.config(serverId: serverId).first { $0.entityId == entityId }?.supportedFeatures
    }

    private func label(for actionId: String) -> String {
        switch actionId {
        case Service.turnOn.rawValue:
            return "Turn on"
        case Service.turnOff.rawValue:
            return "Turn off"
        case Service.openCover.rawValue:
            return "Open"
        case Service.closeCover.rawValue:
            return "Close"
        case Service.lock.rawValue:
            return "Lock"
        case Service.unlock.rawValue:
            return "Unlock"
        case Service.mediaPlay.rawValue:
            return "Play"
        case Service.mediaPause.rawValue:
            return "Pause"
        default:
            return "Run"
        }
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

    private func summaryTitle(_ summaryId: String) -> String {
        switch summaryId {
        case "light": return "Lights"
        case "climate": return "Climate"
        case "security": return "Security"
        case "media_players": return "Media players"
        case "maintenance": return "Maintenance"
        case "weather": return "Weather"
        case "persons": return "Persons"
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
