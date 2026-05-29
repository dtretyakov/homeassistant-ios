import Foundation

public enum GarminProtocolVersion {
    public static let current = 2
}

public enum GarminPayloadLimits {
    public static let inboundCommandBytes = 1024
    public static let outboundMessageBytes = 4096
}

final class GarminValuesRevisionCounter {
    static let shared = GarminValuesRevisionCounter()

    private let lock = NSLock()
    private var revision = 0

    func next() -> Int {
        lock.lock()
        revision += 1
        let value = revision
        lock.unlock()
        return value
    }
}

public enum GarminInboundMessageType: String, Codable, Equatable {
    case getSection = "get"
    case callAction = "call"
    case promptResponse = "prompt_response"
}

public enum GarminOutboundMessageType: String, Codable, Equatable {
    case sectionSnapshot = "section"
    case sectionNotModified = "same"
    case valuesDelta = "values"
    case actionResult = "result"
    case prompt
}

public struct GarminInboundMessage: Codable, Equatable {
    public let version: Int
    public let type: GarminInboundMessageType
    public let id: String?
    public let etag: String?
    public let correlationId: String?
    public let actionId: String?

    public init(
        version: Int = GarminProtocolVersion.current,
        type: GarminInboundMessageType,
        id: String? = nil,
        etag: String? = nil,
        correlationId: String? = nil,
        actionId: String? = nil
    ) {
        self.version = version
        self.type = type
        self.id = id
        self.etag = etag
        self.correlationId = correlationId
        self.actionId = actionId
    }

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case type = "t"
        case id
        case etag = "e"
        case correlationId = "cid"
        case actionId = "action_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? GarminProtocolVersion.current
        type = try container.decode(GarminInboundMessageType.self, forKey: .type)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        etag = try container.decodeIfPresent(String.self, forKey: .etag)
        correlationId = try container.decodeIfPresent(String.self, forKey: .correlationId)
        actionId = try container.decodeIfPresent(String.self, forKey: .actionId)
    }
}

public struct GarminOutboundMessage: Encodable, Equatable {
    public let version: Int
    public let type: GarminOutboundMessageType
    public let id: String?
    public let correlationId: String?
    public let section: GarminOverviewSection?
    public let values: [GarminOverviewValue]?
    public let valuesRevision: Int?
    public let actionResult: GarminCommandResult?
    public let prompt: GarminNotificationPrompt?

    public init(
        version: Int = GarminProtocolVersion.current,
        type: GarminOutboundMessageType,
        id: String? = nil,
        correlationId: String? = nil,
        section: GarminOverviewSection? = nil,
        values: [GarminOverviewValue]? = nil,
        valuesRevision: Int? = nil,
        actionResult: GarminCommandResult? = nil,
        prompt: GarminNotificationPrompt? = nil
    ) {
        self.version = version
        self.type = type
        self.id = id
        self.correlationId = correlationId
        self.section = section
        self.values = values
        self.valuesRevision = valuesRevision
        self.actionResult = actionResult
        self.prompt = prompt
    }

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case type = "t"
        case id
        case correlationId = "cid"
        case section
        case values = "vals"
        case valuesRevision = "rev"
        case actionResult
        case state
        case error
        case title
        case body
        case actions
        case expiresAt = "expires_at"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(correlationId, forKey: .correlationId)
        try container.encodeIfPresent(section, forKey: .section)
        try container.encodeIfPresent(values, forKey: .values)
        try container.encodeIfPresent(valuesRevision, forKey: .valuesRevision)
        if let prompt {
            try container.encodeIfPresent(prompt.id, forKey: .id)
            try container.encodeIfPresent(prompt.correlationId, forKey: .correlationId)
            try container.encode(prompt.title, forKey: .title)
            try container.encodeIfPresent(prompt.body, forKey: .body)
            try container.encode(prompt.actions, forKey: .actions)
            try container.encodeIfPresent(prompt.expiresAt, forKey: .expiresAt)
        }
        if let actionResult {
            try container.encodeIfPresent(actionResult.id, forKey: .id)
            try container.encodeIfPresent(actionResult.correlationId, forKey: .correlationId)
            try container.encode(actionResult.state, forKey: .state)
            try container.encodeIfPresent(actionResult.error, forKey: .error)
        }
    }
}

public struct GarminNotificationPrompt: Codable, Equatable {
    public let id: String
    public let correlationId: String?
    public let title: String
    public let body: String?
    public let actions: [GarminNotificationPromptAction]
    public let expiresAt: Int?

    public init(
        id: String,
        correlationId: String?,
        title: String,
        body: String? = nil,
        actions: [GarminNotificationPromptAction],
        expiresAt: Int? = nil
    ) {
        self.id = id
        self.correlationId = correlationId
        self.title = title
        self.body = body
        self.actions = actions
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case correlationId = "cid"
        case title
        case body
        case actions
        case expiresAt = "expires_at"
    }
}

public struct GarminNotificationPromptAction: Codable, Equatable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct GarminCommandResult: Codable, Equatable {
    public let id: String?
    public let correlationId: String?
    public let state: GarminCommandState
    public let error: GarminIntegrationError?

    public init(id: String? = nil, correlationId: String?, state: GarminCommandState, error: GarminIntegrationError? = nil) {
        self.id = id
        self.correlationId = correlationId
        self.state = state
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case id
        case correlationId = "cid"
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
        let data = try JSONEncoder().encode(message)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    public static func decodeInboundDictionary(_ dictionary: [String: Any]) throws -> GarminInboundMessage {
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        return try JSONDecoder().decode(GarminInboundMessage.self, from: data)
    }

    public static func encodedByteCount<T: Encodable>(_ value: T) throws -> Int {
        return try JSONEncoder().encode(value).count
    }
}
