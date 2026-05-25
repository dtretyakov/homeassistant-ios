import Foundation

public enum GarminProtocolVersion {
    public static let current = 1
}

public enum GarminPayloadLimits {
    public static let inboundCommandBytes = 1024
    public static let outboundMessageBytes = 4096
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
    case connectionStatus = "connection_status"
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
        case correlationId = "id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? GarminProtocolVersion.current
        type = try container.decode(GarminInboundMessageType.self, forKey: .type)
        actionId = try container.decodeIfPresent(String.self, forKey: .actionId)
        statusId = try container.decodeIfPresent(String.self, forKey: .statusId)
        correlationId = try container.decodeIfPresent(String.self, forKey: .correlationId)
    }
}

public struct GarminOutboundMessage: Codable, Equatable {
    public let version: Int
    public let type: GarminOutboundMessageType
    public let profile: GarminProfile?
    public let statusSnapshot: GarminStatusSnapshot?
    public let actionResult: GarminCommandResult?
    public let connectionStatus: GarminConnectionStatus?

    public init(
        version: Int = GarminProtocolVersion.current,
        type: GarminOutboundMessageType,
        profile: GarminProfile? = nil,
        statusSnapshot: GarminStatusSnapshot? = nil,
        actionResult: GarminCommandResult? = nil,
        connectionStatus: GarminConnectionStatus? = nil
    ) {
        self.version = version
        self.type = type
        self.profile = profile
        self.statusSnapshot = statusSnapshot
        self.actionResult = actionResult
        self.connectionStatus = connectionStatus
    }

    enum CodingKeys: String, CodingKey {
        case version
        case type
        case profile
        case statusSnapshot = "status_snapshot"
        case actionResult = "action_result"
        case connectionStatus = "connection_status"
    }
}

public struct GarminConnectionStatus: Codable, Equatable {
    public let correlationId: String?
    public let state: GarminCommandState
    public let error: GarminIntegrationError?
    public let maxPayloadBytes: Int

    public init(
        correlationId: String?,
        state: GarminCommandState,
        error: GarminIntegrationError? = nil,
        maxPayloadBytes: Int = GarminPayloadLimits.outboundMessageBytes
    ) {
        self.correlationId = correlationId
        self.state = state
        self.error = error
        self.maxPayloadBytes = maxPayloadBytes
    }

    enum CodingKeys: String, CodingKey {
        case correlationId = "id"
        case state
        case error
        case maxPayloadBytes = "max_payload_bytes"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        correlationId = try container.decodeIfPresent(String.self, forKey: .correlationId)
        let encodedState = try container.decode(String.self, forKey: .state)
        switch encodedState {
        case "ok":
            state = .success
        case "error":
            state = .failed
        default:
            guard let commandState = GarminCommandState(rawValue: encodedState) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .state,
                    in: container,
                    debugDescription: "Unknown Garmin command state \(encodedState)"
                )
            }
            state = commandState
        }
        if let encodedError = try container.decodeIfPresent(String.self, forKey: .error) {
            switch encodedError {
            case "unavailable":
                error = .watchUnavailable
            default:
                error = GarminIntegrationError(rawValue: encodedError)
            }
        } else {
            error = nil
        }
        maxPayloadBytes = try container.decodeIfPresent(Int.self, forKey: .maxPayloadBytes)
            ?? GarminPayloadLimits.outboundMessageBytes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(correlationId, forKey: .correlationId)
        switch state {
        case .success:
            try container.encode("ok", forKey: .state)
        case .failed:
            try container.encode("error", forKey: .state)
        case .pending:
            try container.encode("pending", forKey: .state)
        }
        try container.encodeIfPresent(encodedConnectionError(error), forKey: .error)
        if maxPayloadBytes != GarminPayloadLimits.outboundMessageBytes {
            try container.encode(maxPayloadBytes, forKey: .maxPayloadBytes)
        }
    }

    private func encodedConnectionError(_ error: GarminIntegrationError?) -> String? {
        switch error {
        case .sdkUnavailable, .watchUnavailable:
            return "unavailable"
        case let .some(error):
            return error.rawValue
        case .none:
            return nil
        }
    }
}

public struct GarminCommandResult: Codable, Equatable {
    public let correlationId: String?
    public let state: GarminCommandState
    public let error: GarminIntegrationError?

    public init(correlationId: String?, state: GarminCommandState, error: GarminIntegrationError? = nil) {
        self.correlationId = correlationId
        self.state = state
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case correlationId = "id"
        case state
        case error
    }
}

public enum GarminCommandState: String, Codable, Equatable {
    case pending
    case success
    case failed
}

public enum GarminIntegrationError: String, Codable, Error, Equatable {
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
    case payloadTooLarge = "payload_too_large"
}

public enum GarminPayloadCodec {
    public static func encodeOutboundDictionary(_ message: GarminOutboundMessage) throws -> [String: Any] {
        if message.type == .connectionStatus, let status = message.connectionStatus {
            let data = try JSONEncoder().encode(status)
            var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            object["type"] = message.type.rawValue
            return object
        }

        let data = try JSONEncoder().encode(message)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    public static func decodeInboundDictionary(_ dictionary: [String: Any]) throws -> GarminInboundMessage {
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        return try JSONDecoder().decode(GarminInboundMessage.self, from: data)
    }

    public static func encodedByteCount<T: Encodable>(_ value: T) throws -> Int {
        if let message = value as? GarminOutboundMessage, message.type == .connectionStatus {
            let object = try encodeOutboundDictionary(message)
            return try JSONSerialization.data(withJSONObject: object).count
        }

        return try JSONEncoder().encode(value).count
    }
}
