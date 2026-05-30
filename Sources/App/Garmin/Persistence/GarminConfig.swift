import Foundation
import GRDB
import Shared

public struct GarminConfig: Codable, FetchableRecord, PersistableRecord, Equatable {
    public static var garminConfigId: String { "garmin-config" }
    public static var maxSectionItems: Int { 16 }
    public static var maxCustomSections: Int { 8 }
    public static var maxStatusItems: Int { maxSectionItems }
    public static var valueCapability: Int { 1 }
    public static var actionCapability: Int { 2 }

    public var id = GarminConfig.garminConfigId
    public var selectedServerId: String?
    public var serverConfigs: [GarminServerOverviewConfig] = []
    public var deviceIdentifier: String?
    public var appIdentifier: String?
    public var deviceName: String?
    public var lastCommunicationTimestamp: TimeInterval?
    public var lastSyncTimestamp: TimeInterval?
    public var lastError: String?

    public init(
        id: String = GarminConfig.garminConfigId,
        selectedServerId: String? = nil,
        serverConfigs: [GarminServerOverviewConfig] = [],
        deviceIdentifier: String? = nil,
        appIdentifier: String? = nil,
        deviceName: String? = nil,
        lastCommunicationTimestamp: TimeInterval? = nil,
        lastSyncTimestamp: TimeInterval? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.selectedServerId = selectedServerId
        self.serverConfigs = serverConfigs
        self.deviceIdentifier = deviceIdentifier
        self.appIdentifier = appIdentifier
        self.deviceName = deviceName
        self.lastCommunicationTimestamp = lastCommunicationTimestamp
        self.lastSyncTimestamp = lastSyncTimestamp
        self.lastError = lastError
    }

    public static func config() throws -> GarminConfig? {
        try GarminDatabaseSchema.createIfNeeded()
        return try Current.database().read { db in
            try GarminConfig.fetchOne(db)
        }
    }

    public func item(for opaqueId: String) -> MagicItem? {
        customItems.first { Self.opaqueItemId(for: $0) == opaqueId }
    }

    public func action(for opaqueId: String) -> MagicItem? {
        customActionItems.first { Self.opaqueItemId(for: $0) == opaqueId }
    }

    public var customItems: [MagicItem] {
        activeServerConfig.customSections.flatMap(\.items).map(\.item)
    }

    public var customStatusItems: [MagicItem] {
        customItems.filter(GarminSupportedDomains.supportsStatus)
    }

    public var customActionItems: [MagicItem] {
        customItems.filter(GarminSupportedDomains.supportsAction)
    }

    public var activeServerConfig: GarminServerOverviewConfig {
        if let selectedServerId, let config = serverConfigs.first(where: { $0.serverId == selectedServerId }) {
            return config
        }
        if let config = serverConfigs.first {
            return config
        }
        return .init(serverId: selectedServerId ?? "")
    }

    public var areasSectionEnabled: Bool {
        get { activeServerConfig.areasSectionEnabled }
        set { updateActiveServerConfig { $0.areasSectionEnabled = newValue } }
    }

    public var summariesSectionEnabled: Bool {
        get { activeServerConfig.summariesSectionEnabled }
        set { updateActiveServerConfig { $0.summariesSectionEnabled = newValue } }
    }

    public var customSections: [GarminCustomSection] {
        get { activeServerConfig.customSections }
        set { updateActiveServerConfig { $0.customSections = newValue } }
    }

    public mutating func ensureServerConfig(serverId: String) {
        if selectedServerId == nil {
            selectedServerId = serverId
        }
        if !serverConfigs.contains(where: { $0.serverId == serverId }) {
            serverConfigs.append(.init(serverId: serverId))
        }
    }

    private mutating func updateActiveServerConfig(_ update: (inout GarminServerOverviewConfig) -> Void) {
        let serverId = selectedServerId ?? serverConfigs.first?.serverId ?? ""
        if let index = serverConfigs.firstIndex(where: { $0.serverId == serverId }) {
            update(&serverConfigs[index])
        } else {
            var config = GarminServerOverviewConfig(serverId: serverId)
            update(&config)
            serverConfigs.append(config)
        }
    }

    public static func opaqueItemId(for item: MagicItem) -> String {
        "e_\(fnv1a64Hex(itemOpaqueSource(item)))"
    }

    public static func opaqueEntityId(serverId: String, entityId: String) -> String {
        "e_\(fnv1a64Hex("\(serverId)|\(entityId)|entity"))"
    }

    public static func compactCustomSectionId(for customSectionId: String) -> String {
        "c_\(fnv1a64Hex("custom_section|\(customSectionId)").prefix(8))"
    }

    public static func capability(for item: MagicItem) -> Int {
        var capability = 0
        if GarminSupportedDomains.supportsStatus(item) {
            capability |= valueCapability
        }
        if GarminSupportedDomains.supportsAction(item) {
            capability |= actionCapability
        }
        return capability
    }

    private static func itemOpaqueSource(_ item: MagicItem) -> String {
        "\(item.serverId)|\(item.id)|\(item.type.rawValue)"
    }

    public static func fnv1a64Hex(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

public struct GarminServerOverviewConfig: Codable, Equatable, Identifiable {
    public var id: String { serverId }
    public var serverId: String
    public var areasSectionEnabled: Bool
    public var summariesSectionEnabled: Bool
    public var customSections: [GarminCustomSection]

    public init(
        serverId: String,
        areasSectionEnabled: Bool = true,
        summariesSectionEnabled: Bool = true,
        customSections: [GarminCustomSection] = []
    ) {
        self.serverId = serverId
        self.areasSectionEnabled = areasSectionEnabled
        self.summariesSectionEnabled = summariesSectionEnabled
        self.customSections = customSections
    }

    enum CodingKeys: String, CodingKey {
        case serverId
        case areasSectionEnabled
        case summariesSectionEnabled
        case customSections
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverId = try container.decode(String.self, forKey: .serverId)
        areasSectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .areasSectionEnabled) ?? true
        summariesSectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .summariesSectionEnabled) ?? true
        customSections = try container.decodeIfPresent([GarminCustomSection].self, forKey: .customSections) ?? []
        customSections = customSections.map { section in
            var copy = section
            copy.items = Self.mergedItems(section.items)
            return copy
        }
    }

    private static func mergedItems(_ items: [GarminCustomSectionItem]) -> [GarminCustomSectionItem] {
        var seen = Set<String>()
        var merged: [GarminCustomSectionItem] = []
        for item in items {
            let key = item.item.serverUniqueId
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(item)
        }
        return merged
    }
}

public struct GarminCustomSection: Codable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var items: [GarminCustomSectionItem]

    public init(
        id: String = UUID().uuidString,
        title: String,
        items: [GarminCustomSectionItem] = []
    ) {
        self.id = id
        self.title = title
        self.items = items
    }
}

public struct GarminCustomSectionItem: Codable, Equatable, Identifiable {
    public var id: String
    public var item: MagicItem

    public init(
        id: String = UUID().uuidString,
        item: MagicItem
    ) {
        self.id = id
        self.item = item
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case item
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        item = try container.decode(MagicItem.self, forKey: .item)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(item, forKey: .item)
    }
}

public enum GarminActionConfirmationPolicy {
    public static func defaultRequiresConfirmation(for item: MagicItem) -> Bool {
        switch item.type {
        case .script, .scene:
            return true
        case .entity:
            return rawDomain(for: item) == Domain.lock.rawValue
        case .action, .folder, .assistPipeline, .assistPrompt:
            return false
        }
    }

    private static func rawDomain(for item: MagicItem) -> String {
        guard let domain = item.id.split(separator: ".").first else { return "" }
        return String(domain)
    }
}

public enum GarminSupportedDomains {
    public static var actionDomains: [Domain] = [
        .scene,
        .script,
        .light,
        .switch,
        .inputBoolean,
        .cover,
        .lock,
    ]

    public static var actionDomainRawValues: [String] {
        actionDomains.map(\.rawValue)
    }

    public static var statusDomainRawValues: Set<String> = [
        Domain.binarySensor.rawValue,
        Domain.sensor.rawValue,
        "alarm_control_panel",
        Domain.light.rawValue,
        Domain.switch.rawValue,
        Domain.inputBoolean.rawValue,
        Domain.lock.rawValue,
        Domain.cover.rawValue,
        Domain.person.rawValue,
        "device_tracker",
    ]

    public static var overviewDomainRawValues: [String] {
        Array(statusDomainRawValues.union(actionDomainRawValues)).sorted()
    }

    public static func supportsAction(_ domain: Domain?) -> Bool {
        guard let domain else { return false }
        return actionDomains.contains(domain)
    }

    public static func supportsAction(rawDomain: String) -> Bool {
        actionDomains.map(\.rawValue).contains(rawDomain)
    }

    public static func supportsStatus(rawDomain: String) -> Bool {
        statusDomainRawValues.contains(rawDomain)
    }

    public static func supportsStatus(_ item: MagicItem) -> Bool {
        supportsStatus(rawDomain: rawDomain(for: item))
    }

    public static func supportsAction(_ item: MagicItem) -> Bool {
        switch item.type {
        case .scene, .script:
            return true
        case .entity:
            return supportsAction(rawDomain: rawDomain(for: item))
        case .action, .folder, .assistPipeline, .assistPrompt:
            return false
        }
    }

    public static func compactDomainCode(for item: MagicItem) -> String? {
        switch item.type {
        case .scene:
            return "sc"
        case .script:
            return "sr"
        case .entity:
            return compactDomainCode(rawDomain: rawDomain(for: item))
        case .action, .folder, .assistPipeline, .assistPrompt:
            return nil
        }
    }

    public static func compactDomainCode(rawDomain: String) -> String? {
        switch rawDomain {
        case Domain.scene.rawValue:
            return "sc"
        case Domain.script.rawValue:
            return "sr"
        case Domain.light.rawValue:
            return "l"
        case Domain.switch.rawValue:
            return "sw"
        case Domain.inputBoolean.rawValue:
            return "ib"
        case Domain.cover.rawValue:
            return "cv"
        case Domain.lock.rawValue:
            return "lk"
        case "alarm_control_panel":
            return "al"
        case Domain.binarySensor.rawValue:
            return "bs"
        case Domain.sensor.rawValue:
            return "sn"
        case Domain.person.rawValue:
            return "p"
        case "device_tracker":
            return "dt"
        default:
            return nil
        }
    }

    private static func rawDomain(for item: MagicItem) -> String {
        guard let domain = item.id.split(separator: ".").first else { return "" }
        return String(domain)
    }
}
