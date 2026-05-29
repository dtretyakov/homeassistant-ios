import Foundation
import Shared

enum GarminDiagnostics {
    enum Event: String {
        case configLoad = "config_load"
        case discovery
        case sync
        case disconnect
        case inboundMessage = "inbound_message"
        case actionExecution = "action_execution"
        case notificationPrompt = "notification_prompt"
        case statusObservation = "status_observation"
        case valueSnapshot = "value_snapshot"
        case statusSend = "status_send"
        case sdk
    }

    enum Status: String {
        case started
        case success
        case failed
        case skipped
        case unavailable
        case stopped
    }

    private static let allowedMetadataKeys: Set<String> = [
        "event_type",
        "status",
        "message_type",
        "command_state",
        "error_code",
        "connection_state",
        "protocol_version",
        "action_count",
        "status_count",
        "cache_status",
        "send_state",
        "subscription_state",
        "id",
        "check_type",
        "sdk_state",
        "sdk_result",
        "inbound_bytes",
        "outbound_bytes",
    ]

    static func record(
        _ event: Event,
        status: Status,
        metadata: [String: Any] = [:]
    ) {
        var safeMetadata = sanitized(metadata)
        safeMetadata["event_type"] = event.rawValue
        safeMetadata["status"] = status.rawValue

        Current.clientEventStore.addEvent(ClientEvent(
            text: "\(event.rawValue): \(status.rawValue)",
            type: .garmin,
            payload: safeMetadata
        ))
    }

    static func connectionState(_ state: GarminConnectionState) -> String {
        switch state {
        case .notConfigured:
            return "not_configured"
        case .selectingDevice:
            return "selecting_device"
        case .waitingForWatch:
            return "waiting_for_watch"
        case .sdkUnavailable:
            return "sdk_unavailable"
        case .appUnavailable:
            return "app_unavailable"
        case .deviceUnavailable:
            return "device_unavailable"
        case .ready:
            return "ready"
        }
    }

    private static func sanitized(_ metadata: [String: Any]) -> [String: Any] {
        metadata.reduce(into: [:]) { result, pair in
            guard allowedMetadataKeys.contains(pair.key), let value = sanitizedValue(pair.value) else { return }
            result[pair.key] = value
        }
    }

    private static func sanitizedValue(_ value: Any) -> Any? {
        switch value {
        case let value as String where value.isEmpty:
            return nil
        case let value as String:
            return value
        case let value as Bool:
            return value
        case let value as Int:
            return value
        case let value as Double:
            return value
        case let value as Float:
            return Double(value)
        default:
            return nil
        }
    }
}
