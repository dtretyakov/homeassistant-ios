import Foundation
import HAKit
import Shared

struct GarminHomeSummaryDefinition: Equatable {
    let id: String
    let title: String
}

struct GarminHomeSummaryEntityState {
    let entityId: String
    let state: String
    let attributes: [String: Any]

    init(entityId: String, state: String, attributes: [String: Any] = [:]) {
        self.entityId = entityId
        self.state = state
        self.attributes = attributes
    }

    init(entity: HAEntity) {
        self.init(
            entityId: entity.entityId,
            state: entity.state,
            attributes: entity.attributes.dictionary
        )
    }
}

protocol GarminHomeSummaryProviding {
    func summaries(serverId: String, entities: [HAAppEntity]) throws -> [GarminHomeSummaryDefinition]
    func contributors(serverId: String, summaryId: String, entities: [HAAppEntity]) throws -> [HAAppEntity]
    func canonicalSummaryId(_ id: String) -> String?
}

final class GarminHomeSummaryStateCache {
    static let shared = GarminHomeSummaryStateCache()

    private static let freshnessInterval: TimeInterval = 5

    private struct CachedStates {
        let states: [GarminHomeSummaryEntityState]
        let updatedAt: Date
    }

    private let lock = NSLock()
    private var statesByServerId: [String: CachedStates] = [:]

    func setStates(_ states: [GarminHomeSummaryEntityState], serverId: String) {
        lock.lock()
        statesByServerId[serverId] = CachedStates(states: states, updatedAt: Date())
        lock.unlock()
    }

    func states(serverId: String) -> [GarminHomeSummaryEntityState] {
        lock.lock()
        guard let cached = statesByServerId[serverId] else {
            lock.unlock()
            return []
        }
        guard Date().timeIntervalSince(cached.updatedAt) <= Self.freshnessInterval else {
            statesByServerId.removeValue(forKey: serverId)
            lock.unlock()
            return []
        }
        lock.unlock()
        return cached.states
    }

    func clear() {
        lock.lock()
        statesByServerId.removeAll()
        lock.unlock()
    }

    func clear(serverId: String) {
        lock.lock()
        statesByServerId.removeValue(forKey: serverId)
        lock.unlock()
    }
}

final class GarminHomeSummaryProvider: GarminHomeSummaryProviding {
    typealias RegistryProvider = (String) throws -> [AppEntityRegistry]
    typealias PanelProvider = (String) throws -> [AppPanel]
    typealias StateProvider = (String) -> [GarminHomeSummaryEntityState]

    private static let lowBatteryThreshold = 20.0

    private let registryProvider: RegistryProvider
    private let panelProvider: PanelProvider
    private let stateProvider: StateProvider

    init(
        registryProvider: @escaping RegistryProvider = { try AppEntityRegistry.config(serverId: $0) },
        panelProvider: @escaping PanelProvider = { try AppPanel.panels(serverId: $0) ?? [] },
        stateProvider: @escaping StateProvider = { GarminHomeSummaryStateCache.shared.states(serverId: $0) }
    ) {
        self.registryProvider = registryProvider
        self.panelProvider = panelProvider
        self.stateProvider = stateProvider
    }

    func summaries(serverId: String, entities: [HAAppEntity]) throws -> [GarminHomeSummaryDefinition] {
        let context = try context(serverId: serverId, entities: entities)
        var result: [GarminHomeSummaryDefinition] = []

        if context.hasPanel("light"), !availabilityEntities(summaryId: "light", context: context).isEmpty {
            result.append(.init(id: "light", title: "Lights"))
        }
        if context.hasPanel("climate"), !availabilityEntities(summaryId: "climate", context: context).isEmpty {
            result.append(.init(id: "climate", title: "Climate"))
        }
        if context.hasPanel("security"), !availabilityEntities(summaryId: "security", context: context).isEmpty {
            result.append(.init(id: "security", title: "Security"))
        }
        if !availabilityEntities(summaryId: "media_players", context: context).isEmpty {
            result.append(.init(id: "media_players", title: "Media players"))
        }
        if context.hasPanel("maintenance"), !availabilityEntities(summaryId: "maintenance", context: context).isEmpty {
            result.append(.init(id: "maintenance", title: "Maintenance"))
        }
        if !availabilityEntities(summaryId: "weather", context: context).isEmpty {
            result.append(.init(id: "weather", title: "Weather"))
        }

        return result
    }

    func contributors(serverId: String, summaryId: String, entities: [HAAppEntity]) throws -> [HAAppEntity] {
        guard let summaryId = canonicalSummaryId(summaryId) else { return [] }
        let context = try context(serverId: serverId, entities: entities)
        guard context.hasStates else { return [] }
        let matching = availabilityEntities(summaryId: summaryId, context: context)

        switch summaryId {
        case "weather":
            return Array(matching.prefix(1))
        default:
            return matching.filter { isActive(entity: $0, summaryId: summaryId, context: context) }
        }
    }

    func canonicalSummaryId(_ id: String) -> String? {
        switch id {
        case "light", "climate", "security", "media_players", "maintenance", "weather", "energy":
            return id
        case "lights":
            return "light"
        case "locks", "openings":
            return "security"
        default:
            return nil
        }
    }

    private func context(serverId: String, entities: [HAAppEntity]) throws -> SummaryContext {
        let registryByEntityId = Dictionary(
            try registryProvider(serverId).compactMap { registry -> (String, AppEntityRegistry)? in
                guard let entityId = registry.entityId else { return nil }
                return (entityId, registry)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let serverEntities = entities
            .filter { $0.serverId == serverId }
            .filter { entity in
                guard let registry = registryByEntityId[entity.entityId] else { return true }
                return registry.hiddenBy == nil
                    && registry.disabledBy == nil
            }
            .sorted(by: sortEntity)
        let states = stateProvider(serverId)
        return SummaryContext(
            entities: serverEntities,
            registryByEntityId: registryByEntityId,
            panels: try panelProvider(serverId),
            statesByEntityId: Dictionary(states.map { ($0.entityId, $0) }, uniquingKeysWith: { first, _ in first })
        )
    }

    private func availabilityEntities(summaryId: String, context: SummaryContext) -> [HAAppEntity] {
        guard let filters = filters(summaryId: summaryId) else { return [] }
        var seen = Set<String>()
        var result: [HAAppEntity] = []

        for filter in filters {
            for entity in context.entities where !seen.contains(entity.entityId) {
                guard matches(entity: entity, filter: filter, context: context) else { continue }
                seen.insert(entity.entityId)
                result.append(entity)
            }
        }

        if summaryId == "weather" {
            return result.sorted { $0.entityId < $1.entityId }
        }
        return result
    }

    private func filters(summaryId: String) -> [SummaryEntityFilter]? {
        switch summaryId {
        case "light":
            return [.init(domain: "light", entityCategories: ["none"])]
        case "climate":
            return [
                .init(domain: "climate", entityCategories: ["none"]),
                .init(domain: "humidifier", entityCategories: ["none"]),
                .init(domain: "fan", entityCategories: ["none"]),
                .init(domain: "water_heater", entityCategories: ["none"]),
                .init(domain: "cover", deviceClasses: ["awning", "blind", "curtain", "shade", "shutter", "window", "none"], entityCategories: ["none"]),
                .init(domain: "binary_sensor", deviceClasses: ["window"], entityCategories: ["none"]),
            ]
        case "security":
            return [
                .init(domain: "camera", entityCategories: ["none"]),
                .init(domain: "alarm_control_panel", entityCategories: ["none"]),
                .init(domain: "lock", entityCategories: ["none"]),
                .init(domain: "cover", deviceClasses: ["door", "garage", "gate", "window"], entityCategories: ["none"]),
                .init(domain: "binary_sensor", deviceClasses: ["lock", "door", "window", "garage_door", "opening", "carbon_monoxide", "gas", "moisture", "safety", "smoke", "tamper"], entityCategories: ["none"]),
                .init(domain: "binary_sensor", deviceClasses: ["tamper"], entityCategories: ["diagnostic"]),
            ]
        case "media_players":
            return [.init(domain: "media_player", entityCategories: ["none"])]
        case "maintenance":
            return [
                .init(domain: "sensor", deviceClasses: ["battery"]),
                .init(domain: "binary_sensor", deviceClasses: ["battery"], entityCategories: ["none"]),
            ]
        case "weather":
            return [.init(domain: "weather", entityCategories: ["none"])]
        default:
            return nil
        }
    }

    private func matches(entity: HAAppEntity, filter: SummaryEntityFilter, context: SummaryContext) -> Bool {
        guard context.statesByEntityId[entity.entityId] != nil else { return false }
        guard entity.domain == filter.domain else { return false }

        if let deviceClasses = filter.deviceClasses, !deviceClasses.contains(deviceClass(entity: entity, context: context)) {
            return false
        }

        if let entityCategories = filter.entityCategories {
            let category = context.registryByEntityId[entity.entityId]?.entityCategory ?? "none"
            if !entityCategories.contains(category) {
                return false
            }
        }

        return true
    }

    private func isActive(entity: HAAppEntity, summaryId: String, context: SummaryContext) -> Bool {
        guard let rawState = context.statesByEntityId[entity.entityId]?.state.lowercased() else {
            return false
        }

        switch summaryId {
        case "light":
            return rawState == "on"
        case "climate":
            return isActiveClimateState(entity: entity, state: rawState)
        case "security":
            return isActiveSecurityState(entity: entity, state: rawState)
        case "media_players":
            return rawState == "playing"
        case "maintenance":
            return isActiveMaintenanceState(entity: entity, state: rawState)
        default:
            return false
        }
    }

    private func isActiveClimateState(entity: HAAppEntity, state: String) -> Bool {
        switch entity.domain {
        case "cover":
            return state == "open" || state == "opening"
        case "binary_sensor":
            return state == "on" || state == "open"
        default:
            return state != "off"
                && state != "idle"
                && state != "unavailable"
                && state != "unknown"
        }
    }

    private func isActiveSecurityState(entity: HAAppEntity, state: String) -> Bool {
        switch entity.domain {
        case "lock":
            return state == "unlocked" || state == "unlocking" || state == "jammed" || state == "open"
        case "alarm_control_panel":
            return state == "triggered" || state == "disarmed"
        case "cover":
            return state == "open" || state == "opening"
        case "binary_sensor":
            return state == "on" || state == "open"
        default:
            return false
        }
    }

    private func isActiveMaintenanceState(entity: HAAppEntity, state: String) -> Bool {
        if state == "unavailable" {
            return true
        }
        if entity.domain == "binary_sensor" {
            return state == "on"
        }
        guard let value = Double(state) else { return false }
        return value <= Self.lowBatteryThreshold
    }

    private func deviceClass(entity: HAAppEntity, context: SummaryContext) -> String {
        if let deviceClass = context.statesByEntityId[entity.entityId]?.attributes["device_class"] as? String {
            return deviceClass
        }
        if let deviceClass = entity.rawDeviceClass {
            return deviceClass
        }
        if let registry = context.registryByEntityId[entity.entityId] {
            return registry.deviceClass ?? registry.originalDeviceClass ?? "none"
        }
        return "none"
    }

    private func sortEntity(_ lhs: HAAppEntity, _ rhs: HAAppEntity) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private struct SummaryEntityFilter {
        let domain: String
        let deviceClasses: Set<String>?
        let entityCategories: Set<String>?

        init(domain: String, deviceClasses: Set<String>? = nil, entityCategories: Set<String>? = nil) {
            self.domain = domain
            self.deviceClasses = deviceClasses
            self.entityCategories = entityCategories
        }
    }

    private struct SummaryContext {
        let entities: [HAAppEntity]
        let registryByEntityId: [String: AppEntityRegistry]
        let panels: [AppPanel]
        let statesByEntityId: [String: GarminHomeSummaryEntityState]

        var hasStates: Bool {
            !statesByEntityId.isEmpty
        }

        func hasPanel(_ path: String) -> Bool {
            panels.contains { $0.path == path }
        }
    }
}
