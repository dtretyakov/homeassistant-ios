import Foundation
import GRDB

public struct GarminConfig: Codable, FetchableRecord, PersistableRecord, Equatable {
    public static var garminConfigId: String { "garmin-config" }

    public var id = GarminConfig.garminConfigId
    public var selectedServerId: String?
    public var actionItems: [MagicItem] = []
    public var statusItems: [MagicItem] = []
    public var deviceIdentifier: String?
    public var appIdentifier: String?
    public var lastSyncTimestamp: TimeInterval?
    public var lastError: String?

    public init(
        id: String = GarminConfig.garminConfigId,
        selectedServerId: String? = nil,
        actionItems: [MagicItem] = [],
        statusItems: [MagicItem] = [],
        deviceIdentifier: String? = nil,
        appIdentifier: String? = nil,
        lastSyncTimestamp: TimeInterval? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.selectedServerId = selectedServerId
        self.actionItems = actionItems
        self.statusItems = statusItems
        self.deviceIdentifier = deviceIdentifier
        self.appIdentifier = appIdentifier
        self.lastSyncTimestamp = lastSyncTimestamp
        self.lastError = lastError
    }

    public static func config() throws -> GarminConfig? {
        try Current.database().read { db in
            try GarminConfig.fetchOne(db)
        }
    }

    public func action(for opaqueId: String) -> MagicItem? {
        actionItems.first { Self.opaqueActionId(for: $0) == opaqueId }
    }

    public func status(for opaqueId: String) -> MagicItem? {
        statusItems.first { Self.opaqueStatusId(for: $0) == opaqueId }
    }

    public static func opaqueActionId(for item: MagicItem) -> String {
        opaqueId(prefix: "garmin_action", item: item)
    }

    public static func opaqueStatusId(for item: MagicItem) -> String {
        opaqueId(prefix: "garmin_status", item: item)
    }

    private static func opaqueId(prefix: String, item: MagicItem) -> String {
        let source = "\(item.serverId)|\(item.id)|\(item.type.rawValue)"
        return "\(prefix)_\(fnv1a64Hex(source))"
    }

    private static func fnv1a64Hex(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

public enum GarminSupportedDomains {
    public static var actionDomains: [Domain] = [
        .scene,
        .script,
        .light,
        .switch,
        .inputBoolean,
    ]

    public static func supportsAction(_ domain: Domain?) -> Bool {
        guard let domain else { return false }
        return actionDomains.contains(domain)
    }

    public static func supportsAction(_ item: MagicItem) -> Bool {
        switch item.type {
        case .scene, .script:
            return true
        case .entity:
            return supportsAction(item.domain)
        case .action, .folder, .assistPipeline, .assistPrompt:
            return false
        }
    }
}
