import Foundation
import GRDB
import Shared

final class ClientEventsLogViewModel: ObservableObject {
    static let garminDiagnosticsLimit = 50

    @Published var events: [ClientEvent] = []
    @Published var searchTerm: String = ""
    @Published var typeFilter: ClientEvent.EventType?

    init(initialTypeFilter: ClientEvent.EventType? = nil) {
        typeFilter = initialTypeFilter
    }

    var filteredEvents: [ClientEvent] {
        events.filter { event in
            let matchesType = typeFilter.map { event.type == $0 } ?? true
            let matchesSearch = searchTerm.isEmpty || event.text.lowercased().contains(searchTerm.lowercased())
            return matchesType && matchesSearch
        }
    }

    var visibleEvents: [ClientEvent] {
        let events = filteredEvents
        guard typeFilter == .garmin else { return events }
        return Array(events.prefix(Self.garminDiagnosticsLimit))
    }

    func loadEvents() {
        events = Current.clientEventStore.getEvents().sorted(by: { $0.date > $1.date })
    }

    func resetTypeFilter() {
        typeFilter = nil
    }

    func copyFilteredEventsText() -> String {
        let formatter = ISO8601DateFormatter()

        return visibleEvents.map { event in
            var parts = [
                "timestamp=\(formatter.string(from: event.date))",
                "type=\(event.type.rawValue)",
                "status=\(sanitizedCopyText(event.text))",
            ]

            let metadata = sanitizedCopyPayload(event.jsonPayloadJSONObject())
            if !metadata.isEmpty {
                parts.append("metadata=\(jsonString(metadata))")
            }

            return parts.joined(separator: " ")
        }
        .joined(separator: "\n")
    }

    private func sanitizedCopyPayload(_ payload: [String: Any]) -> [String: Any] {
        payload.reduce(into: [:]) { result, pair in
            guard !isSensitiveCopyKey(pair.key) else {
                result[pair.key] = "[redacted]"
                return
            }
            if let dictionary = pair.value as? [String: Any] {
                result[pair.key] = sanitizedCopyPayload(dictionary)
            } else if let array = pair.value as? [Any] {
                result[pair.key] = array.map { value -> Any in
                    if let dictionary = value as? [String: Any] {
                        return sanitizedCopyPayload(dictionary)
                    }
                    return value
                }
            } else {
                result[pair.key] = pair.value
            }
        }
    }

    private func sanitizedCopyText(_ text: String) -> String {
        var sanitized = text
        [
            #"https?://[^\s]+"#,
            #"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#,
            #"(?i)(access_token|refresh_token|token|authorization|password|secret)=\S+"#,
        ].forEach { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                range: NSRange(sanitized.startIndex..., in: sanitized),
                withTemplate: "[redacted]"
            )
        }
        return sanitized
    }

    private func isSensitiveCopyKey(_ key: String) -> Bool {
        let key = key.lowercased()
        return [
            "token",
            "authorization",
            "auth",
            "password",
            "secret",
            "credential",
            "url",
            "headers",
            "service_data",
            "raw_payload",
            "payload",
            "entity_id",
            "access_token",
            "refresh_token",
        ].contains { key.contains($0) }
    }

    private func jsonString(_ payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: payload)
        }
        return string
    }
}
