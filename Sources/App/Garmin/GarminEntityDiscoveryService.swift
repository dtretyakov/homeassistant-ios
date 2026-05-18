import Foundation
import Shared

enum GarminEntityCandidateKind: String, Codable, Equatable {
    case action
    case status
    case actionAndStatus
}

struct GarminEntityCandidate: Identifiable, Equatable {
    let entityId: String
    let serverId: String
    let domain: String
    let name: String
    let icon: String?
    let areaName: String?
    let candidateKind: GarminEntityCandidateKind
    let requiresConfirmation: Bool
    let score: Int

    var id: String {
        "\(serverId)-\(entityId)-\(candidateKind.rawValue)"
    }

    var supportsAction: Bool {
        candidateKind == .action || candidateKind == .actionAndStatus
    }

    var supportsStatus: Bool {
        candidateKind == .status || candidateKind == .actionAndStatus
    }

    func magicItem() -> MagicItem {
        let type: MagicItem.ItemType
        switch domain {
        case "scene":
            type = .scene
        case "script":
            type = .script
        default:
            type = .entity
        }

        return MagicItem(
            id: entityId,
            serverId: serverId,
            type: type,
            customization: .init(
                requiresConfirmation: requiresConfirmation,
                icon: icon
            ),
            displayText: name
        )
    }

    func matches(searchTerm: String) -> Bool {
        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return true }
        return name.lowercased().contains(term)
            || entityId.lowercased().contains(term)
            || domain.lowercased().contains(term)
            || areaName?.lowercased().contains(term) == true
    }
}

struct GarminEntityDiscoveryResult: Equatable {
    static let empty = GarminEntityDiscoveryResult(
        recommendedActions: [],
        recommendedStatuses: [],
        actionsByDomain: [:],
        statusesByDomain: [:],
        searchableCandidates: []
    )

    let recommendedActions: [GarminEntityCandidate]
    let recommendedStatuses: [GarminEntityCandidate]
    let actionsByDomain: [String: [GarminEntityCandidate]]
    let statusesByDomain: [String: [GarminEntityCandidate]]
    let searchableCandidates: [GarminEntityCandidate]

    func search(_ searchTerm: String) -> [GarminEntityCandidate] {
        searchableCandidates.filter { $0.matches(searchTerm: searchTerm) }
    }

    func candidate(for item: MagicItem) -> GarminEntityCandidate? {
        searchableCandidates.first {
            $0.entityId == item.id && $0.serverId == item.serverId
        }
    }
}

struct GarminEntityRegistryInfo: Equatable {
    let entityId: String
    let isHidden: Bool
    let isDisabled: Bool
    let isConfiguration: Bool
    let isDiagnostic: Bool
}

struct GarminEntityAreaInfo: Equatable {
    let name: String
    let entities: Set<String>
}

final class GarminEntityDiscoveryService {
    typealias EntityProvider = () throws -> [HAAppEntity]
    typealias RegistryProvider = (String) throws -> [GarminEntityRegistryInfo]
    typealias AreaProvider = (String) throws -> [GarminEntityAreaInfo]

    private let entityProvider: EntityProvider
    private let registryProvider: RegistryProvider
    private let areaProvider: AreaProvider

    init(
        entityProvider: @escaping EntityProvider = { try HAAppEntity.config() },
        registryProvider: @escaping RegistryProvider = { serverId in
            try AppEntityRegistry.config(serverId: serverId).compactMap { registry in
                guard let entityId = registry.entityId else { return nil }
                return GarminEntityRegistryInfo(
                    entityId: entityId,
                    isHidden: registry.hiddenBy != nil,
                    isDisabled: registry.disabledBy != nil,
                    isConfiguration: registry.entityCategory == "config",
                    isDiagnostic: registry.entityCategory == "diagnostic"
                )
            }
        },
        areaProvider: @escaping AreaProvider = { serverId in
            try AppArea.fetchAreas(for: serverId).map {
                GarminEntityAreaInfo(name: $0.name, entities: $0.entities)
            }
        }
    ) {
        self.entityProvider = entityProvider
        self.registryProvider = registryProvider
        self.areaProvider = areaProvider
    }

    func discover(serverId: String) throws -> GarminEntityDiscoveryResult {
        let registryByEntityId = Dictionary(
            try registryProvider(serverId).map { ($0.entityId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let areaNameByEntityId = areaNameMap(areas: try areaProvider(serverId))

        let candidates = try entityProvider()
            .filter { $0.serverId == serverId }
            .filter { entity in
                guard let registry = registryByEntityId[entity.entityId] else { return true }
                return !registry.isHidden
                    && !registry.isDisabled
                    && !registry.isConfiguration
                    && !registry.isDiagnostic
            }
            .compactMap { entity in
                candidate(
                    for: entity,
                    areaName: areaNameByEntityId[entity.entityId]
                )
            }
            .sorted(by: sortCandidates)

        let actionCandidates = candidates.filter { $0.supportsAction }
        let statusCandidates = candidates.filter { $0.supportsStatus }

        return GarminEntityDiscoveryResult(
            recommendedActions: Array(actionCandidates.prefix(8)),
            recommendedStatuses: Array(statusCandidates.prefix(5)),
            actionsByDomain: groupedByDomain(actionCandidates),
            statusesByDomain: groupedByDomain(statusCandidates),
            searchableCandidates: candidates.sorted(by: sortByName)
        )
    }

    private func candidate(for entity: HAAppEntity, areaName: String?) -> GarminEntityCandidate? {
        let supportsAction = GarminSupportedDomains.supportsAction(rawDomain: entity.domain)
        let supportsStatus = GarminSupportedDomains.supportsStatus(rawDomain: entity.domain)
        guard supportsAction || supportsStatus else { return nil }

        let kind: GarminEntityCandidateKind
        switch (supportsAction, supportsStatus) {
        case (true, true):
            kind = .actionAndStatus
        case (true, false):
            kind = .action
        case (false, true):
            kind = .status
        case (false, false):
            kind = .status
        }

        return GarminEntityCandidate(
            entityId: entity.entityId,
            serverId: entity.serverId,
            domain: entity.domain,
            name: entity.name,
            icon: entity.icon,
            areaName: areaName,
            candidateKind: kind,
            requiresConfirmation: false,
            score: score(entity: entity, supportsAction: supportsAction, supportsStatus: supportsStatus)
        )
    }

    private func areaNameMap(areas: [GarminEntityAreaInfo]) -> [String: String] {
        areas.reduce(into: [:]) { result, area in
            area.entities.forEach { entityId in
                result[entityId] = area.name
            }
        }
    }

    private func groupedByDomain(_ candidates: [GarminEntityCandidate]) -> [String: [GarminEntityCandidate]] {
        Dictionary(grouping: candidates, by: \.domain)
            .mapValues { $0.sorted(by: sortCandidates) }
    }

    private func sortCandidates(_ lhs: GarminEntityCandidate, _ rhs: GarminEntityCandidate) -> Bool {
        if lhs.score != rhs.score {
            return lhs.score > rhs.score
        }
        return sortByName(lhs, rhs)
    }

    private func sortByName(_ lhs: GarminEntityCandidate, _ rhs: GarminEntityCandidate) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func score(entity: HAAppEntity, supportsAction: Bool, supportsStatus: Bool) -> Int {
        var actionScore = 0
        var statusScore = 0

        if supportsAction {
            switch entity.domain {
            case "script":
                actionScore = 100
            case "scene":
                actionScore = 95
            case "input_boolean":
                actionScore = 90
            case "light":
                actionScore = 80
            case "switch":
                actionScore = 70
            case "cover":
                actionScore = 45
            default:
                break
            }
        }

        if supportsStatus {
            switch entity.domain {
            case "alarm_control_panel":
                statusScore = 100
            case "binary_sensor":
                statusScore = 95
            case "light":
                statusScore = 90
            case "sensor":
                statusScore = 85
            case "person", "device_tracker":
                statusScore = 80
            case "lock", "cover":
                statusScore = 75
            case "switch", "input_boolean":
                statusScore = 60
            default:
                break
            }
        }

        var score = max(actionScore, statusScore)
        if entity.rawDeviceClass == "door" || entity.rawDeviceClass == "window" {
            score += 10
        }

        return score
    }
}
