import Combine
import Foundation
import Shared

final class GarminConfigurationViewModel: ObservableObject {
    @Published var config = GarminConfig()
    @Published var servers: [Server] = []
    @Published var showAddAction = false
    @Published var showAddStatus = false
    @Published var showError = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var connectionState: GarminConnectionState = .notConfigured
    @Published private(set) var discoveryResult = GarminEntityDiscoveryResult.empty

    private let magicItemProvider = Current.magicItemProvider()
    private let integrationController: GarminIntegrationControlling
    private let entityDiscoveryService: GarminEntityDiscoveryService
    private let prefilledItem: MagicItem?
    private var didApplyPrefilledItem = false
    private var cancellables = Set<AnyCancellable>()

    init(
        prefilledItem: MagicItem? = nil,
        integrationController: GarminIntegrationControlling = Current.garminIntegrationController,
        entityDiscoveryService: GarminEntityDiscoveryService = GarminEntityDiscoveryService()
    ) {
        self.prefilledItem = prefilledItem
        self.integrationController = integrationController
        self.entityDiscoveryService = entityDiscoveryService
        integrationController.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
            }
            .store(in: &cancellables)
        do {
            try GarminDatabaseSchema.createIfNeeded()
        } catch {
            Current.Log.error("Failed to initialize Garmin database schema, error: \(error.localizedDescription)")
        }
        connectionState = integrationController.connectionState
    }

    @MainActor
    func loadConfig() {
        servers = Current.servers.all
        magicItemProvider.loadInformation { [weak self] _ in
            guard let self else { return }
            loadDatabase()
        }
    }

    func magicItemInfo(for item: MagicItem) -> MagicItem.Info? {
        magicItemProvider.getInfo(for: item)
    }

    func addAction(_ item: MagicItem) {
        guard GarminSupportedDomains.supportsAction(item) else { return }
        guard !config.actionItems.contains(where: { $0.serverUniqueId == item.serverUniqueId }) else { return }
        guard config.actionItems.count < GarminConfig.maxActionItems else {
            showError(message: "Garmin supports up to \(GarminConfig.maxActionItems) favorite actions.")
            return
        }
        if config.selectedServerId == nil {
            config.selectedServerId = item.serverId
        }
        config.actionItems.append(item)
        save()
    }

    func addStatus(_ item: MagicItem) {
        guard GarminSupportedDomains.supportsStatus(item) else { return }
        guard !config.statusItems.contains(where: { $0.serverUniqueId == item.serverUniqueId }) else { return }
        guard config.statusItems.count < GarminConfig.maxStatusItems else {
            showError(message: "Garmin supports up to \(GarminConfig.maxStatusItems) status items.")
            return
        }
        if config.selectedServerId == nil {
            config.selectedServerId = item.serverId
        }
        config.statusItems.append(item)
        save()
    }

    func addRecommendedAction(_ candidate: GarminEntityCandidate) {
        guard candidate.supportsAction else { return }
        addAction(candidate.magicItem())
    }

    func addRecommendedStatus(_ candidate: GarminEntityCandidate) {
        guard candidate.supportsStatus else { return }
        addStatus(candidate.magicItem())
    }

    func isActionSelected(_ candidate: GarminEntityCandidate) -> Bool {
        config.actionItems.contains { $0.id == candidate.entityId && $0.serverId == candidate.serverId }
    }

    func isStatusSelected(_ candidate: GarminEntityCandidate) -> Bool {
        config.statusItems.contains { $0.id == candidate.entityId && $0.serverId == candidate.serverId }
    }

    func refreshDiscovery() {
        loadDiscovery()
    }

    func updateAction(_ item: MagicItem) {
        if let index = config.actionItems.firstIndex(where: { $0.id == item.id && $0.serverId == item.serverId }) {
            config.actionItems[index] = item
            save()
        }
    }

    func updateStatus(_ item: MagicItem) {
        if let index = config.statusItems.firstIndex(where: { $0.id == item.id && $0.serverId == item.serverId }) {
            config.statusItems[index] = item
            save()
        }
    }

    func deleteAction(at offsets: IndexSet) {
        config.actionItems.remove(atOffsets: offsets)
        save()
    }

    func moveAction(from source: IndexSet, to destination: Int) {
        config.actionItems.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func deleteStatus(at offsets: IndexSet) {
        config.statusItems.remove(atOffsets: offsets)
        save()
    }

    func moveStatus(from source: IndexSet, to destination: Int) {
        config.statusItems.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func sync() {
        guard config.actionItems.count <= GarminConfig.maxActionItems else {
            showError(message: "Garmin supports up to \(GarminConfig.maxActionItems) favorite actions.")
            GarminDiagnostics.record(.sync, status: .failed, metadata: [
                "error_code": "too_many_actions",
                "action_count": config.actionItems.count,
                "status_count": config.statusItems.count,
            ])
            return
        }
        guard config.statusItems.count <= GarminConfig.maxStatusItems else {
            showError(message: "Garmin supports up to \(GarminConfig.maxStatusItems) status items.")
            GarminDiagnostics.record(.sync, status: .failed, metadata: [
                "error_code": "too_many_statuses",
                "action_count": config.actionItems.count,
                "status_count": config.statusItems.count,
            ])
            return
        }
        connectionState = integrationController.connectionState
        GarminDiagnostics.record(.sync, status: .started, metadata: [
            "connection_state": GarminDiagnostics.connectionState(connectionState),
            "action_count": config.actionItems.count,
            "status_count": config.statusItems.count,
        ])
        integrationController.sync(config: config, itemInfo: { [weak self] item in
            self?.magicItemInfo(for: item)
        }) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.config.lastSyncTimestamp = Current.date().timeIntervalSince1970
                    self?.config.lastError = nil
                    GarminDiagnostics.record(.sync, status: .success, metadata: [
                        "connection_state": GarminDiagnostics.connectionState(self?.integrationController.connectionState ?? .notConfigured),
                        "action_count": self?.config.actionItems.count ?? 0,
                        "status_count": self?.config.statusItems.count ?? 0,
                    ])
                    _ = self?.save()
                case let .failure(error):
                    self?.config.lastError = error.rawValue
                    self?.showError(message: error.rawValue)
                    GarminDiagnostics.record(.sync, status: .failed, metadata: [
                        "connection_state": GarminDiagnostics.connectionState(self?.integrationController.connectionState ?? .notConfigured),
                        "error_code": error.rawValue,
                        "action_count": self?.config.actionItems.count ?? 0,
                        "status_count": self?.config.statusItems.count ?? 0,
                    ])
                    _ = self?.save()
                }
            }
        }
    }

    func checkConnection() {
        integrationController.requestConnectionCheck(force: true)
        connectionState = integrationController.connectionState
    }

    func disconnect() {
        integrationController.disconnect(config: config) { _ in }
        connectionState = integrationController.connectionState
        config.deviceIdentifier = nil
        config.appIdentifier = nil
        config.lastError = nil
        GarminDiagnostics.record(.disconnect, status: .success, metadata: [
            "connection_state": GarminDiagnostics.connectionState(connectionState),
            "action_count": config.actionItems.count,
            "status_count": config.statusItems.count,
        ])
        save()
    }

    @discardableResult
    func save() -> Bool {
        do {
            try Current.database().write { db in
                try config.insert(db, onConflict: .replace)
            }
            return true
        } catch {
            Current.Log.error("Failed to save Garmin config, error: \(error.localizedDescription)")
            showError(message: error.localizedDescription)
            return false
        }
    }

    @MainActor
    private func loadDatabase() {
        do {
            if let config = try GarminConfig.config() {
                self.config = config
            } else {
                var config = GarminConfig()
                config.selectedServerId = servers.first?.identifier.rawValue
                self.config = config
                save()
            }
            applyPrefilledItemIfNeeded()
            loadDiscovery()
            connectionState = integrationController.connectionState
            GarminDiagnostics.record(.configLoad, status: .success, metadata: [
                "connection_state": GarminDiagnostics.connectionState(connectionState),
                "action_count": self.config.actionItems.count,
                "status_count": self.config.statusItems.count,
            ])
        } catch {
            Current.Log.error("Failed to load Garmin config, error: \(error.localizedDescription)")
            GarminDiagnostics.record(.configLoad, status: .failed, metadata: [
                "error_code": "database",
            ])
            showError(message: error.localizedDescription)
        }
    }

    private func applyPrefilledItemIfNeeded() {
        guard let prefilledItem, !didApplyPrefilledItem else { return }
        didApplyPrefilledItem = true
        addAction(prefilledItem)
    }

    private func loadDiscovery() {
        guard let serverId = config.selectedServerId ?? servers.first?.identifier.rawValue else {
            discoveryResult = .empty
            return
        }
        do {
            discoveryResult = try entityDiscoveryService.discover(serverId: serverId)
            GarminDiagnostics.record(.discovery, status: .success, metadata: [
                "action_count": discoveryResult.recommendedActions.count,
                "status_count": discoveryResult.recommendedStatuses.count,
            ])
        } catch {
            Current.Log.error("Failed to load Garmin entity discovery, error: \(error.localizedDescription)")
            GarminDiagnostics.record(.discovery, status: .failed, metadata: [
                "error_code": "home_assistant_unavailable",
            ])
            discoveryResult = .empty
        }
    }

    private func showError(message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = message
            self?.showError = true
        }
    }
}
