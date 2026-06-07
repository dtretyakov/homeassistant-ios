import Foundation
import Shared

final class GarminPendingDesiredValueGate {
    static let shared = GarminPendingDesiredValueGate()

    private static let defaultTimeout: TimeInterval = 12

    private struct Entry {
        let expectedValue: String
        let expiresAt: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func recordExpectedValue(for item: MagicItem, actionId: String?, now: Date = Date()) {
        guard let expectedValue = Self.expectedProtocolValue(for: item, actionId: actionId) else { return }
        recordExpectedValue(expectedValue, for: GarminConfig.opaqueItemId(for: item), now: now)
    }

    func recordExpectedValue(_ expectedValue: String, for itemId: String, now: Date = Date()) {
        lock.lock()
        entries[itemId] = Entry(expectedValue: expectedValue, expiresAt: now.addingTimeInterval(Self.defaultTimeout))
        lock.unlock()
    }

    func filter(_ values: [GarminOverviewValue], now: Date = Date()) -> [GarminOverviewValue] {
        lock.lock()
        defer { lock.unlock() }

        pruneExpired(now: now)
        return values.compactMap { value in
            guard let entry = entries[value.id] else { return value }
            guard Self.normalized(value.value) == Self.normalized(entry.expectedValue) else {
                return nil
            }
            entries.removeValue(forKey: value.id)
            return value
        }
    }

    func reset() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    private func pruneExpired(now: Date) {
        entries = entries.filter { $0.value.expiresAt > now }
    }

    private static func expectedProtocolValue(for item: MagicItem, actionId: String?) -> String? {
        guard item.type == .entity, let domain = item.domain else { return nil }
        switch (domain, actionId) {
        case (.light, Service.turnOn.rawValue),
             (.switch, Service.turnOn.rawValue),
             (.inputBoolean, Service.turnOn.rawValue):
            return Domain.State.on.rawValue
        case (.light, Service.turnOff.rawValue),
             (.switch, Service.turnOff.rawValue),
             (.inputBoolean, Service.turnOff.rawValue):
            return Domain.State.off.rawValue
        default:
            return nil
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
