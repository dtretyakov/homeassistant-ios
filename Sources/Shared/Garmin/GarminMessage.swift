import Foundation

public enum GarminProtocolVersion {
    public static let current = 1
}

public enum GarminInboundMessageType: String, Codable, Equatable {
    case ping
    case requestProfile = "request_profile"
    case callAction = "call_action"
    case requestStatus = "request_status"
}

public enum GarminOutboundMessageType: String, Codable, Equatable {
    case profileSync = "profile_sync"
    case statusSnapshot = "status_snapshot"
    case actionResult = "action_result"
}

public struct GarminInboundMessage: Codable, Equatable {
    public let version: Int
    public let type: GarminInboundMessageType
    public let actionId: String?
    public let statusId: String?
    public let correlationId: String?

    public init(
        version: Int = GarminProtocolVersion.current,
        type: GarminInboundMessageType,
        actionId: String? = nil,
        statusId: String? = nil,
        correlationId: String? = nil
    ) {
        self.version = version
        self.type = type
        self.actionId = actionId
        self.statusId = statusId
        self.correlationId = correlationId
    }

    enum CodingKeys: String, CodingKey {
        case version
        case type
        case actionId = "action_id"
        case statusId = "status_id"
        case correlationId = "correlation_id"
    }
}

public struct GarminOutboundMessage: Codable, Equatable {
    public let version: Int
    public let type: GarminOutboundMessageType
    public let profile: GarminProfile?
    public let statusSnapshot: GarminStatusSnapshot?
    public let actionResult: GarminCommandResult?

    public init(
        version: Int = GarminProtocolVersion.current,
        type: GarminOutboundMessageType,
        profile: GarminProfile? = nil,
        statusSnapshot: GarminStatusSnapshot? = nil,
        actionResult: GarminCommandResult? = nil
    ) {
        self.version = version
        self.type = type
        self.profile = profile
        self.statusSnapshot = statusSnapshot
        self.actionResult = actionResult
    }

    enum CodingKeys: String, CodingKey {
        case version
        case type
        case profile
        case statusSnapshot = "status_snapshot"
        case actionResult = "action_result"
    }
}

public struct GarminCommandResult: Codable, Equatable {
    public let correlationId: String?
    public let state: GarminCommandState
    public let error: GarminBridgeError?

    public init(correlationId: String?, state: GarminCommandState, error: GarminBridgeError? = nil) {
        self.correlationId = correlationId
        self.state = state
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case correlationId = "correlation_id"
        case state
        case error
    }
}

public enum GarminCommandState: String, Codable, Equatable {
    case pending
    case success
    case failed
}

public enum GarminBridgeError: String, Codable, Error, Equatable {
    case unsupportedProtocol = "unsupported_protocol"
    case missingConfig = "missing_config"
    case missingAction = "missing_action"
    case missingServer = "missing_server"
    case unsupportedAction = "unsupported_action"
    case unsupportedStatus = "unsupported_status"
    case homeAssistantUnavailable = "home_assistant_unavailable"
    case loginRequired = "login_required"
    case watchUnavailable = "watch_unavailable"
    case entityRemoved = "entity_removed"
    case commandFailed = "command_failed"
    case sdkUnavailable = "sdk_unavailable"
}
