import Foundation
import HAKit
import Shared

enum GarminHomeSummaryDetailMode: Equatable {
    case list
    case singleStatus
}

struct GarminHomeSummaryDefinition: Equatable {
    let id: String
    let title: String
    let value: String
    let detailMode: GarminHomeSummaryDetailMode
    let sortOrder: Int
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

struct GarminHomeSummaryDetailItem {
    let item: GarminOverviewItem
    let value: String?
    let valueItem: MagicItem?
}

enum GarminDesiredStateActionResolver {
    private static let mediaPlayerFeaturePause = 1
    private static let mediaPlayerFeaturePlay = 16_384

    static func actionId(
        rawDomain: String,
        state: String,
        attributes: [String: Any] = [:]
    ) -> String? {
        let normalizedState = state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedState != "unknown", normalizedState != "unavailable" else { return nil }

        switch rawDomain {
        case Domain.light.rawValue,
             Domain.switch.rawValue,
             Domain.inputBoolean.rawValue:
            if normalizedState == "on" { return Service.turnOff.rawValue }
            if normalizedState == "off" { return Service.turnOn.rawValue }
            return nil
        case Domain.cover.rawValue:
            if normalizedState == "open" { return Service.closeCover.rawValue }
            if normalizedState == "closed" { return Service.openCover.rawValue }
            return nil
        case Domain.lock.rawValue:
            if normalizedState == "locked" { return Service.unlock.rawValue }
            if normalizedState == "unlocked" { return Service.lock.rawValue }
            return nil
        case Domain.mediaPlayer.rawValue:
            if normalizedState == "playing", supportsMediaPlayerFeature(attributes, feature: mediaPlayerFeaturePause) {
                return Service.mediaPause.rawValue
            }
            if (normalizedState == "paused" || normalizedState == "idle" || normalizedState == "on"),
               supportsMediaPlayerFeature(attributes, feature: mediaPlayerFeaturePlay) {
                return Service.mediaPlay.rawValue
            }
            return nil
        default:
            return nil
        }
    }

    static func service(for domain: Domain, actionId: String) -> Service? {
        switch (domain, actionId) {
        case (.light, Service.turnOn.rawValue),
             (.switch, Service.turnOn.rawValue),
             (.inputBoolean, Service.turnOn.rawValue):
            return .turnOn
        case (.light, Service.turnOff.rawValue),
             (.switch, Service.turnOff.rawValue),
             (.inputBoolean, Service.turnOff.rawValue):
            return .turnOff
        case (.cover, Service.openCover.rawValue):
            return .openCover
        case (.cover, Service.closeCover.rawValue):
            return .closeCover
        case (.lock, Service.lock.rawValue):
            return .lock
        case (.lock, Service.unlock.rawValue):
            return .unlock
        case (.mediaPlayer, Service.mediaPlay.rawValue):
            return .mediaPlay
        case (.mediaPlayer, Service.mediaPause.rawValue):
            return .mediaPause
        default:
            return nil
        }
    }

    private static func supportsMediaPlayerFeature(_ attributes: [String: Any], feature: Int) -> Bool {
        guard let rawValue = attributes["supported_features"] else { return false }
        let supportedFeatures: Int?
        if let int = rawValue as? Int {
            supportedFeatures = int
        } else if let double = rawValue as? Double {
            supportedFeatures = Int(double)
        } else if let string = rawValue as? String {
            supportedFeatures = Int(string)
        } else {
            supportedFeatures = nil
        }
        guard let supportedFeatures else { return false }
        return supportedFeatures & feature != 0
    }
}

protocol GarminHomeSummaryProviding {
    func summaries(serverId: String, entities: [HAAppEntity]) throws -> [GarminHomeSummaryDefinition]
    func detailItems(serverId: String, summaryId: String, entities: [HAAppEntity]) throws -> [GarminHomeSummaryDetailItem]
    func isSupportedSummaryId(_ id: String) -> Bool
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
    private var fetchCompletionsByServerId: [String: [(Bool) -> Void]] = [:]
    private var fetchCancellablesByServerId: [String: HACancellable] = [:]

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

    func hasFreshStates(serverId: String) -> Bool {
        lock.lock()
        guard let cached = statesByServerId[serverId] else {
            lock.unlock()
            return false
        }
        guard Date().timeIntervalSince(cached.updatedAt) <= Self.freshnessInterval else {
            statesByServerId.removeValue(forKey: serverId)
            lock.unlock()
            return false
        }
        lock.unlock()
        return true
    }

    func beginFetch(serverId: String, completion: @escaping (Bool) -> Void) -> Bool {
        lock.lock()
        if let cached = statesByServerId[serverId] {
            if Date().timeIntervalSince(cached.updatedAt) <= Self.freshnessInterval {
                lock.unlock()
                completion(true)
                return false
            } else {
                statesByServerId.removeValue(forKey: serverId)
            }
        }
        if fetchCompletionsByServerId[serverId] != nil {
            fetchCompletionsByServerId[serverId]?.append(completion)
            lock.unlock()
            return false
        }
        fetchCompletionsByServerId[serverId] = [completion]
        lock.unlock()
        return true
    }

    func completeFetch(serverId: String) {
        lock.lock()
        let completions = fetchCompletionsByServerId.removeValue(forKey: serverId) ?? []
        fetchCancellablesByServerId.removeValue(forKey: serverId)
        lock.unlock()
        completions.forEach { $0(true) }
    }

    func failFetch(serverId: String) {
        lock.lock()
        guard fetchCompletionsByServerId[serverId] != nil else {
            lock.unlock()
            return
        }
        statesByServerId.removeValue(forKey: serverId)
        let completions = fetchCompletionsByServerId.removeValue(forKey: serverId) ?? []
        let cancellable = fetchCancellablesByServerId.removeValue(forKey: serverId)
        lock.unlock()
        cancellable?.cancel()
        completions.forEach { $0(false) }
    }

    func setFetchCancellable(_ cancellable: HACancellable, serverId: String) {
        lock.lock()
        let shouldKeep = fetchCompletionsByServerId[serverId] != nil
        if shouldKeep {
            fetchCancellablesByServerId[serverId] = cancellable
        }
        lock.unlock()
        if !shouldKeep {
            cancellable.cancel()
        }
    }

    func clear() {
        lock.lock()
        let cancellables = Array(fetchCancellablesByServerId.values)
        statesByServerId.removeAll()
        fetchCompletionsByServerId.removeAll()
        fetchCancellablesByServerId.removeAll()
        lock.unlock()
        cancellables.forEach { $0.cancel() }
    }

    func clear(serverId: String) {
        lock.lock()
        statesByServerId.removeValue(forKey: serverId)
        lock.unlock()
    }
}

final class GarminHomeSummaryProvider: GarminHomeSummaryProviding {
    typealias RegistryProvider = (String) throws -> [AppEntityRegistry]
    typealias StateProvider = (String) -> [GarminHomeSummaryEntityState]

    private static let lowBatteryThreshold = 20.0
    private static let summaryOrder = [
        "light",
        "climate",
        "security",
        "media_players",
        "maintenance",
        "weather",
        "persons",
    ]

    private let registryProvider: RegistryProvider
    private let stateProvider: StateProvider

    init(
        registryProvider: @escaping RegistryProvider = { try AppEntityRegistry.config(serverId: $0) },
        stateProvider: @escaping StateProvider = { GarminHomeSummaryStateCache.shared.states(serverId: $0) }
    ) {
        self.registryProvider = registryProvider
        self.stateProvider = stateProvider
    }

    func summaries(serverId: String, entities: [HAAppEntity]) throws -> [GarminHomeSummaryDefinition] {
        let context = try context(serverId: serverId, entities: entities)
        return Self.summaryOrder.enumerated().compactMap { index, summaryId -> GarminHomeSummaryDefinition? in
            let matching = availabilityEntities(summaryId: summaryId, context: context, requiresState: false)
            guard hasWatchSupportedDetail(summaryId: summaryId, matching: matching, context: context) else { return nil }
            return .init(
                id: summaryId,
                title: summaryTitle(summaryId),
                value: summaryValue(summaryId: summaryId, matching: matching, context: context),
                detailMode: summaryId == "weather" ? .singleStatus : .list,
                sortOrder: index
            )
        }
    }

    func detailItems(serverId: String, summaryId: String, entities: [HAAppEntity]) throws -> [GarminHomeSummaryDetailItem] {
        guard isSupportedSummaryId(summaryId) else { return [] }
        let context = try context(serverId: serverId, entities: entities)
        guard context.hasStates else { return [] }
        let matching = availabilityEntities(summaryId: summaryId, context: context)
        return detailItems(summaryId: summaryId, matching: matching, context: context)
    }

    private func hasWatchSupportedDetail(
        summaryId: String,
        matching: [HAAppEntity],
        context: SummaryContext
    ) -> Bool {
        if summaryId == "weather" {
            return !weatherDetailItems(matching: matching, context: context).isEmpty
        }
        return matching.contains { entity in
            let item = magicItem(entity)
            return detailCapability(for: entity, item: item, context: context) > 0
        }
    }

    func isSupportedSummaryId(_ id: String) -> Bool {
        Self.summaryOrder.contains(id)
    }

    private func context(serverId: String, entities: [HAAppEntity]) throws -> SummaryContext {
        let registryByEntityId = Dictionary(
            try registryProvider(serverId).compactMap { registry -> (String, AppEntityRegistry)? in
                guard let entityId = registry.entityId else { return nil }
                return (entityId, registry)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let localEntities = entities
            .filter { $0.serverId == serverId }
        let states = stateProvider(serverId)
        let localEntitiesByEntityId = Dictionary(
            localEntities.map { ($0.entityId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let sourceEntities = states.map { state in
            localEntitiesByEntityId[state.entityId] ?? entity(serverId: serverId, state: state)
        }
        let serverEntities = sourceEntities
            .filter { $0.serverId == serverId }
            .filter { entity in
                guard let registry = registryByEntityId[entity.entityId] else { return true }
                return registry.hiddenBy == nil
                    && registry.disabledBy == nil
            }
            .sorted(by: sortEntity)
        return SummaryContext(
            entities: serverEntities,
            registryByEntityId: registryByEntityId,
            statesByEntityId: Dictionary(states.map { ($0.entityId, $0) }, uniquingKeysWith: { first, _ in first })
        )
    }

    private func entity(serverId: String, state: GarminHomeSummaryEntityState) -> HAAppEntity {
        let domain = state.entityId.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        let friendlyName = state.attributes["friendly_name"] as? String
        let fallbackName = state.entityId.replacingOccurrences(of: "_", with: " ")
        let name = friendlyName.flatMap { name -> String? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? fallbackName
        return HAAppEntity(
            id: ServerEntity.uniqueId(serverId: serverId, entityId: state.entityId),
            entityId: state.entityId,
            serverId: serverId,
            domain: domain,
            name: name,
            icon: state.attributes["icon"] as? String,
            rawDeviceClass: state.attributes["device_class"] as? String
        )
    }

    private func availabilityEntities(
        summaryId: String,
        context: SummaryContext,
        requiresState: Bool = true
    ) -> [HAAppEntity] {
        guard let filters = filters(summaryId: summaryId) else { return [] }
        var seen = Set<String>()
        var result: [HAAppEntity] = []

        for filter in filters {
            for entity in context.entities where !seen.contains(entity.entityId) {
                guard matches(entity: entity, filter: filter, context: context, requiresState: requiresState) else { continue }
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
        case "persons":
            return [.init(domain: "person")]
        default:
            return nil
        }
    }

    private func matches(
        entity: HAAppEntity,
        filter: SummaryEntityFilter,
        context: SummaryContext,
        requiresState: Bool
    ) -> Bool {
        if requiresState, context.statesByEntityId[entity.entityId] == nil {
            return false
        }
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

    private func summaryValue(
        summaryId: String,
        matching: [HAAppEntity],
        context: SummaryContext
    ) -> String {
        switch summaryId {
        case "light":
            let count = matching.filter { state($0, context: context) == "on" }.count
            return count > 0 ? "\(count) on" : "All lights off"
        case "climate":
            return ""
        case "security":
            return securitySummaryValue(matching: matching, context: context)
        case "media_players":
            let count = matching.filter { state($0, context: context) == "playing" }.count
            return count > 0 ? "\(count) playing" : "No media playing"
        case "maintenance":
            return maintenanceSummaryValue(matching: matching, context: context)
        case "weather":
            guard let weather = matching.sorted(by: { $0.entityId < $1.entityId }).first else { return "" }
            return weatherSummaryValue(entity: weather, context: context)
        case "persons":
            let count = matching.filter { state($0, context: context) == "home" }.count
            return count > 0 ? "\(count) home" : "Nobody home"
        default:
            return ""
        }
    }

    private func securitySummaryValue(matching: [HAAppEntity], context: SummaryContext) -> String {
        let locks = matching.filter { $0.domain == "lock" }
        let alarms = matching.filter { $0.domain == "alarm_control_panel" }
        guard !locks.isEmpty || !alarms.isEmpty else { return "" }

        let unlockedLocks = locks.filter { entity in
            let rawState = state(entity, context: context)
            return rawState == "unlocked" || rawState == "jammed" || rawState == "open"
        }
        if !unlockedLocks.isEmpty {
            return "\(unlockedLocks.count) \(unlockedLocks.count == 1 ? "lock" : "locks") unlocked"
        }

        let disarmedAlarms = alarms.filter { state($0, context: context) == "disarmed" }
        if !disarmedAlarms.isEmpty {
            return "\(disarmedAlarms.count) \(disarmedAlarms.count == 1 ? "alarm" : "alarms") disarmed"
        }

        return "All secure"
    }

    private func maintenanceSummaryValue(matching: [HAAppEntity], context: SummaryContext) -> String {
        let lowBatteryCount = matching.filter { isLowBattery(entity: $0, context: context) }.count
        let unavailableCount = matching.filter { state($0, context: context) == "unavailable" }.count
        var parts: [String] = []

        if lowBatteryCount > 0 {
            parts.append("\(lowBatteryCount) low \(lowBatteryCount == 1 ? "battery" : "batteries")")
        }
        if unavailableCount > 0 {
            parts.append("\(unavailableCount) unavailable \(unavailableCount == 1 ? "device" : "devices")")
        }
        return parts.isEmpty ? "All good" : parts.joined(separator: ", ")
    }

    private func weatherSummaryValue(entity: HAAppEntity, context: SummaryContext) -> String {
        guard let weatherState = context.statesByEntityId[entity.entityId] else { return "" }
        let condition = displayState(weatherState.state)
        guard let temperature = weatherState.attributes["temperature"] else { return condition }

        let unit = (weatherState.attributes["temperature_unit"] as? String)
            ?? (weatherState.attributes["unit_of_measurement"] as? String)
            ?? ""
        let temperatureText: String
        if let value = temperature as? Double {
            temperatureText = formatNumber(value)
        } else if let value = temperature as? Float {
            temperatureText = formatNumber(Double(value))
        } else if let value = temperature as? Int {
            temperatureText = String(value)
        } else {
            temperatureText = "\(temperature)"
        }

        let value = unit.isEmpty ? temperatureText : "\(temperatureText) \(unit)"
        return condition.isEmpty ? value : "\(value) · \(condition)"
    }

    private func detailItems(
        summaryId: String,
        matching: [HAAppEntity],
        context: SummaryContext
    ) -> [GarminHomeSummaryDetailItem] {
        if summaryId == "weather" {
            return weatherDetailItems(matching: matching, context: context)
        }

        return matching
            .sorted { lhs, rhs in sortDetail(lhs, rhs, summaryId: summaryId, context: context) }
            .compactMap { detailItem(entity: $0, context: context) }
    }

    private func detailItem(entity: HAAppEntity, context: SummaryContext) -> GarminHomeSummaryDetailItem? {
        let magicItem = magicItem(entity)
        let capability = detailCapability(for: entity, item: magicItem, context: context)
        guard capability > 0 else { return nil }
        return GarminHomeSummaryDetailItem(
            item: GarminOverviewItem(
                id: GarminConfig.opaqueEntityId(serverId: entity.serverId, entityId: entity.entityId),
                label: entity.name,
                type: .item,
                cap: capability,
                confirmation: confirmation(for: magicItem),
                domain: GarminSupportedDomains.compactDomainCode(rawDomain: entity.domain)
            ),
            value: displayValue(entity: entity, context: context),
            valueItem: magicItem
        )
    }

    private func detailCapability(for entity: HAAppEntity, item: MagicItem, context: SummaryContext) -> Int {
        var capability = GarminConfig.capability(for: item)
        guard capability & GarminConfig.actionCapability != 0 else { return capability }
        if !supportsDesiredStateAction(
            entity: entity,
            state: state(entity, context: context),
            attributes: stateAttributes(entity, context: context)
        ) {
            capability &= ~GarminConfig.actionCapability
        }
        return capability
    }

    private func supportsDesiredStateAction(entity: HAAppEntity, state: String, attributes: [String: Any]) -> Bool {
        GarminDesiredStateActionResolver.actionId(
            rawDomain: entity.domain,
            state: state,
            attributes: attributes
        ) != nil
    }

    private func weatherDetailItems(matching: [HAAppEntity], context: SummaryContext) -> [GarminHomeSummaryDetailItem] {
        guard let weather = matching.sorted(by: { $0.entityId < $1.entityId }).first,
              let weatherState = context.statesByEntityId[weather.entityId] else {
            return []
        }

        var rows: [(String, String)] = []
        rows.append(("Condition", displayState(weatherState.state)))
        appendWeatherRow("Temperature", value: weatherState.attributes["temperature"], unit: weatherState.attributes["temperature_unit"], to: &rows)
        appendWeatherRow("Humidity", value: weatherState.attributes["humidity"], unit: "%", to: &rows)
        appendWeatherRow("Pressure", value: weatherState.attributes["pressure"], unit: weatherState.attributes["pressure_unit"], to: &rows)
        appendWeatherRow("Wind speed", value: weatherState.attributes["wind_speed"], unit: weatherState.attributes["wind_speed_unit"], to: &rows)
        appendWeatherRow("Wind bearing", value: weatherState.attributes["wind_bearing"], unit: "°", to: &rows)
        appendWeatherRow("Visibility", value: weatherState.attributes["visibility"], unit: weatherState.attributes["visibility_unit"], to: &rows)
        appendWeatherRow("Precipitation", value: weatherState.attributes["precipitation"], unit: weatherState.attributes["precipitation_unit"], to: &rows)

        return rows.compactMap { label, value in
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let id = "s_\(GarminConfig.fnv1a64Hex("\(weather.serverId)|\(weather.entityId)|weather|\(label)"))"
            return GarminHomeSummaryDetailItem(
                item: GarminOverviewItem(
                    id: id,
                    label: label,
                    type: .item,
                    cap: GarminConfig.valueCapability,
                    domain: "w"
                ),
                value: value,
                valueItem: nil
            )
        }
    }

    private func appendWeatherRow(
        _ label: String,
        value: Any?,
        unit: Any?,
        to rows: inout [(String, String)]
    ) {
        guard let text = formattedAttributeValue(value, unit: unit) else { return }
        rows.append((label, text))
    }

    private func sortDetail(
        _ lhs: HAAppEntity,
        _ rhs: HAAppEntity,
        summaryId: String,
        context: SummaryContext
    ) -> Bool {
        let lhsPriority = detailPriority(entity: lhs, summaryId: summaryId, context: context)
        let rhsPriority = detailPriority(entity: rhs, summaryId: summaryId, context: context)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        return sortEntity(lhs, rhs)
    }

    private func detailPriority(entity: HAAppEntity, summaryId: String, context: SummaryContext) -> Int {
        let rawState = state(entity, context: context)
        if summaryId != "maintenance", isUnavailableState(rawState) {
            return 2
        }

        switch summaryId {
        case "light", "climate", "security", "media_players":
            return isActive(entity: entity, summaryId: summaryId, context: context) ? 0 : 1
        case "maintenance":
            if isLowBattery(entity: entity, state: rawState) {
                return 0
            }
            if isUnavailableState(rawState) {
                return 1
            }
            return 2
        case "persons":
            return rawState == "home" ? 0 : 1
        default:
            return 1
        }
    }

    private func isActive(entity: HAAppEntity, summaryId: String, context: SummaryContext) -> Bool {
        let rawState = state(entity, context: context)
        guard !rawState.isEmpty else { return false }

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
        state == "unavailable" || isLowBattery(entity: entity, state: state)
    }

    private func isLowBattery(entity: HAAppEntity, context: SummaryContext) -> Bool {
        isLowBattery(entity: entity, state: state(entity, context: context))
    }

    private func isLowBattery(entity: HAAppEntity, state: String) -> Bool {
        if entity.domain == "binary_sensor" {
            return state == "on"
        }
        guard let value = Double(state) else { return false }
        return value <= Self.lowBatteryThreshold
    }

    private func state(_ entity: HAAppEntity, context: SummaryContext) -> String {
        context.statesByEntityId[entity.entityId]?.state.lowercased() ?? ""
    }

    private func stateAttributes(_ entity: HAAppEntity, context: SummaryContext) -> [String: Any] {
        context.statesByEntityId[entity.entityId]?.attributes ?? [:]
    }

    private func displayValue(entity: HAAppEntity, context: SummaryContext) -> String? {
        guard let state = context.statesByEntityId[entity.entityId] else { return nil }
        let value = entity.domain == "person" ? displayPersonState(state.state) : displayState(state.state)
        guard let unit = state.attributes["unit_of_measurement"] as? String,
              !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.contains(unit) else {
            return value
        }
        return "\(value) \(unit)"
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

    private func titleCase(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { part in
                guard let first = part.first else { return "" }
                return first.uppercased() + part.dropFirst()
            }
            .joined(separator: " ")
    }

    private func displayState(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.lowercased() == "partlycloudy" {
            return "Partly Cloudy"
        }
        return titleCase(trimmed.lowercased())
    }

    private func displayPersonState(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "home":
            return "Home"
        case "not_home":
            return "Away"
        case "unknown":
            return "Unknown"
        case "unavailable":
            return "Unavailable"
        default:
            return displayState(value)
        }
    }

    private func formattedAttributeValue(_ value: Any?, unit: Any?) -> String? {
        guard let value else { return nil }
        let text: String
        if let value = value as? Double {
            text = formatNumber(value)
        } else if let value = value as? Float {
            text = formatNumber(Double(value))
        } else if let value = value as? Int {
            text = String(value)
        } else {
            text = "\(value)"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let unit = unit as? String,
              !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !trimmed.contains(unit) else {
            return trimmed
        }
        return "\(trimmed) \(unit)"
    }

    private func formatNumber(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(rounded))
        }
        return String(rounded)
    }

    private func isUnavailableState(_ state: String) -> Bool {
        state == "unavailable" || state == "unknown"
    }

    private func magicItem(_ entity: HAAppEntity) -> MagicItem {
        MagicItem(
            id: entity.entityId,
            serverId: entity.serverId,
            type: magicItemType(for: entity.domain),
            displayText: entity.name
        )
    }

    private func magicItemType(for domain: String) -> MagicItem.ItemType {
        switch domain {
        case Domain.script.rawValue: return .script
        case Domain.scene.rawValue: return .scene
        default: return .entity
        }
    }

    private func confirmation(for item: MagicItem) -> GarminOverviewActionConfirmation? {
        guard GarminSupportedDomains.supportsAction(item) else { return nil }
        let requiresConfirmation = item.customization?.requiresConfirmation
            ?? GarminActionConfirmationPolicy.defaultRequiresConfirmation(for: item)
        return requiresConfirmation ? .required : nil
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
        let statesByEntityId: [String: GarminHomeSummaryEntityState]

        var hasStates: Bool {
            !statesByEntityId.isEmpty
        }
    }
}
