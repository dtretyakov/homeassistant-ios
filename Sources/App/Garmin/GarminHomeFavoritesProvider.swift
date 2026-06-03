import Foundation
import Shared

protocol GarminHomeFavoritesProviding {
    func favorites(serverId: String, entities: [HAAppEntity]) throws -> [HAAppEntity]
}

struct GarminHomeFavoritesStrategy {
    let favoriteEntities: [String]
    let hideSuggestedEntities: Bool

    init(
        favoriteEntities: [String] = [],
        hideSuggestedEntities: Bool = false
    ) {
        self.favoriteEntities = favoriteEntities
        self.hideSuggestedEntities = hideSuggestedEntities
    }

    init(_ config: HAHomeFrontendSystemData) {
        self.init(
            favoriteEntities: config.favoriteEntities,
            hideSuggestedEntities: config.hideSuggestedEntities
        )
    }
}

final class GarminHomeFavoritesCache {
    static let shared = GarminHomeFavoritesCache()

    static let defaultLimit = 8
    private static let freshnessInterval: TimeInterval = 5

    struct Entry: Equatable {
        let entityIds: [String]
    }

    private struct CachedFavorites {
        let entry: Entry
        let updatedAt: Date
    }

    private let lock = NSLock()
    private var favoritesByServerId: [String: CachedFavorites] = [:]
    private var inFlightCompletionsByServerId: [String: [() -> Void]] = [:]

    func setEntry(_ entry: Entry, serverId: String) {
        lock.lock()
        favoritesByServerId[serverId] = CachedFavorites(entry: entry, updatedAt: Date())
        lock.unlock()
    }

    func freshEntry(serverId: String) -> Entry? {
        lock.lock()
        guard let cached = favoritesByServerId[serverId] else {
            lock.unlock()
            return nil
        }
        guard Date().timeIntervalSince(cached.updatedAt) <= Self.freshnessInterval else {
            favoritesByServerId.removeValue(forKey: serverId)
            lock.unlock()
            return nil
        }
        lock.unlock()
        return cached.entry
    }

    func beginResolve(serverId: String, completion: @escaping () -> Void) -> Bool {
        lock.lock()
        if inFlightCompletionsByServerId[serverId] != nil {
            inFlightCompletionsByServerId[serverId]?.append(completion)
            lock.unlock()
            return false
        }
        inFlightCompletionsByServerId[serverId] = [completion]
        lock.unlock()
        return true
    }

    func completeResolve(serverId: String) {
        lock.lock()
        let completions = inFlightCompletionsByServerId.removeValue(forKey: serverId) ?? []
        lock.unlock()

        completions.forEach { $0() }
    }

    func clear() {
        lock.lock()
        favoritesByServerId.removeAll()
        inFlightCompletionsByServerId.removeAll()
        lock.unlock()
    }

    func clear(serverId: String) {
        lock.lock()
        favoritesByServerId.removeValue(forKey: serverId)
        inFlightCompletionsByServerId.removeValue(forKey: serverId)
        lock.unlock()
    }
}

final class GarminHomeFavoritesResolver {
    typealias RegistryProvider = (String) throws -> [AppEntityRegistry]

    private let registryProvider: RegistryProvider
    private let defaultLimit: Int

    init(
        registryProvider: @escaping RegistryProvider = { try AppEntityRegistry.config(serverId: $0) },
        defaultLimit: Int = GarminHomeFavoritesCache.defaultLimit
    ) {
        self.registryProvider = registryProvider
        self.defaultLimit = defaultLimit
    }

    func pinnedEntityIds(
        serverId: String,
        entities: [HAAppEntity],
        strategy: GarminHomeFavoritesStrategy
    ) -> [String] {
        resolvedEntityIds(
            serverId: serverId,
            entities: entities,
            strategy: strategy,
            predictedEntityIds: [],
            includeSuggested: false
        )
    }

    func resolvedEntityIds(
        serverId: String,
        entities: [HAAppEntity],
        strategy: GarminHomeFavoritesStrategy,
        predictedEntityIds: [String],
        includeSuggested: Bool = true
    ) -> [String] {
        let registryByEntityId: [String: AppEntityRegistry]
        let registryAvailable: Bool
        do {
            registryByEntityId = try registryMap(serverId: serverId)
            registryAvailable = true
        } catch {
            registryByEntityId = [:]
            registryAvailable = false
        }
        let entitiesByEntityId = Dictionary(
            entities
                .filter { $0.serverId == serverId }
                .map { ($0.entityId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let supportedDomains = Set(GarminSupportedDomains.overviewDomainRawValues)
        var seen = Set<String>()
        var result: [String] = []

        appendEntities(
            strategy.favoriteEntities,
            entitiesByEntityId: entitiesByEntityId,
            registryByEntityId: registryByEntityId,
            supportedDomains: supportedDomains,
            seen: &seen,
            result: &result,
            allowHidden: true,
            limit: nil
        )

        let limit = max(defaultLimit, result.count)
        guard registryAvailable, includeSuggested, !strategy.hideSuggestedEntities, result.count < limit else {
            return result
        }

        appendEntities(
            predictedEntityIds,
            entitiesByEntityId: entitiesByEntityId,
            registryByEntityId: registryByEntityId,
            supportedDomains: supportedDomains,
            seen: &seen,
            result: &result,
            allowHidden: false,
            limit: limit
        )
        return result
    }

    private func appendEntities(
        _ entityIds: [String],
        entitiesByEntityId: [String: HAAppEntity],
        registryByEntityId: [String: AppEntityRegistry],
        supportedDomains: Set<String>,
        seen: inout Set<String>,
        result: inout [String],
        allowHidden: Bool,
        limit: Int?
    ) {
        for entityId in entityIds {
            if let limit, result.count >= limit { return }
            guard !seen.contains(entityId),
                  let entity = entitiesByEntityId[entityId],
                  supportedDomains.contains(entity.domain) else {
                continue
            }
            if let registry = registryByEntityId[entityId] {
                if registry.disabledBy != nil { continue }
                if !allowHidden, registry.hiddenBy != nil { continue }
            }
            seen.insert(entityId)
            result.append(entityId)
        }
    }

    private func registryMap(serverId: String) throws -> [String: AppEntityRegistry] {
        let registries = try registryProvider(serverId)
        return Dictionary(
            registries.compactMap { registry -> (String, AppEntityRegistry)? in
                guard let entityId = registry.entityId else { return nil }
                return (entityId, registry)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

final class GarminHomeFavoritesProvider: GarminHomeFavoritesProviding {
    typealias EntryProvider = (String) -> GarminHomeFavoritesCache.Entry?

    private let entryProvider: EntryProvider

    init(
        entryProvider: @escaping EntryProvider = { GarminHomeFavoritesCache.shared.freshEntry(serverId: $0) }
    ) {
        self.entryProvider = entryProvider
    }

    func favorites(serverId: String, entities: [HAAppEntity]) throws -> [HAAppEntity] {
        guard let entry = entryProvider(serverId) else { return [] }
        let entitiesByEntityId = Dictionary(
            entities
                .filter { $0.serverId == serverId }
                .map { ($0.entityId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let supportedDomains = Set(GarminSupportedDomains.overviewDomainRawValues)

        return entry.entityIds.compactMap { entityId -> HAAppEntity? in
            guard let entity = entitiesByEntityId[entityId] ?? HAAppEntity.entity(id: entityId, serverId: serverId),
                  supportedDomains.contains(entity.domain) else {
                return nil
            }
            return entity
        }
    }
}
