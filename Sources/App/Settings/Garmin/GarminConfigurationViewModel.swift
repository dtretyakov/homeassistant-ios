import Combine
import Foundation
import Shared

final class GarminConfigurationViewModel: ObservableObject {
    @Published var config = GarminConfig()
    @Published var servers: [Server] = []
    @Published var showAddItem = false
    @Published var targetCustomSectionId: String?
    @Published var showError = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var connectionState: GarminConnectionState = .notConfigured
    @Published private(set) var connectionDiagnostics = GarminConnectionDiagnostics.idle

    private let magicItemProvider = Current.magicItemProvider()
    private let integrationController: GarminIntegrationControlling
    private let prefilledItem: MagicItem?
    private var didApplyPrefilledItem = false
    private var cancellables = Set<AnyCancellable>()

    init(
        prefilledItem: MagicItem? = nil,
        integrationController: GarminIntegrationControlling = Current.garminIntegrationController
    ) {
        self.prefilledItem = prefilledItem
        self.integrationController = integrationController
        integrationController.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
                self?.refreshPersistedConnectionFields()
            }
            .store(in: &cancellables)
        integrationController.connectionDiagnosticsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] diagnostics in
                self?.connectionDiagnostics = diagnostics
            }
            .store(in: &cancellables)
        do {
            try GarminDatabaseSchema.createIfNeeded()
        } catch {
            Current.Log.error("Failed to initialize Garmin database schema, error: \(error.localizedDescription)")
        }
        connectionState = integrationController.connectionState
        connectionDiagnostics = integrationController.connectionDiagnostics
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

    func customSection(sectionId: String) -> GarminCustomSection? {
        config.customSections.first(where: { $0.id == sectionId })
    }

    func addCustomSection() {
        ensureSelectedServerConfig()
        guard config.customSections.count < GarminConfig.maxCustomSections else {
            showError(message: "Garmin supports up to \(GarminConfig.maxCustomSections) custom sections.")
            return
        }
        var sections = config.customSections
        sections.append(.init(title: "New section"))
        config.customSections = sections
        save(syncAfterSave: true)
    }

    func updateCustomSectionTitle(sectionId: String, title: String) {
        var sections = config.customSections
        guard let index = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New section" : title
        guard sections[index].title != resolvedTitle else { return }
        sections[index].title = resolvedTitle
        config.customSections = sections
        save(syncAfterSave: true)
    }

    func deleteCustomSection(at offsets: IndexSet) {
        var sections = config.customSections
        sections.remove(atOffsets: offsets)
        config.customSections = sections
        save(syncAfterSave: true)
    }

    func moveCustomSection(from source: IndexSet, to destination: Int) {
        var sections = config.customSections
        sections.move(fromOffsets: source, toOffset: destination)
        config.customSections = sections
        save(syncAfterSave: true)
    }

    func beginAddingItem(to sectionId: String) {
        targetCustomSectionId = sectionId
        showAddItem = true
    }

    func addItem(_ item: MagicItem, to sectionId: String? = nil) {
        var item = item
        guard GarminConfig.capability(for: item) > 0 else { return }
        if config.selectedServerId == nil {
            config.selectedServerId = item.serverId
        }
        config.ensureServerConfig(serverId: item.serverId)
        guard let sectionIndex = customSectionIndex(sectionId: sectionId) else { return }
        guard canUseServer(for: item) else { return }
        guard canAddItem(to: sectionIndex, item: item) else { return }
        applyDefaultConfirmationIfNeeded(to: &item)
        var sections = config.customSections
        sections[sectionIndex].items.append(.init(item: item))
        config.customSections = sections
        save(syncAfterSave: true)
    }

    func updateCustomItem(sectionId: String, itemId: String, updatedItem: MagicItem) {
        var sections = config.customSections
        guard let sectionIndex = sections.firstIndex(where: { $0.id == sectionId }),
              let itemIndex = sections[sectionIndex].items.firstIndex(where: { $0.id == itemId }) else {
            return
        }
        sections[sectionIndex].items[itemIndex].item = updatedItem
        config.customSections = sections
        save(syncAfterSave: true)
    }

    func deleteCustomItem(sectionId: String, at offsets: IndexSet) {
        var sections = config.customSections
        guard let sectionIndex = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        sections[sectionIndex].items.remove(atOffsets: offsets)
        config.customSections = sections
        save(syncAfterSave: true)
    }

    func moveCustomItem(sectionId: String, from source: IndexSet, to destination: Int) {
        var sections = config.customSections
        guard let sectionIndex = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        sections[sectionIndex].items.move(fromOffsets: source, toOffset: destination)
        config.customSections = sections
        save(syncAfterSave: true)
    }

    func setAreasSectionEnabled(_ isEnabled: Bool) {
        ensureSelectedServerConfig()
        config.areasSectionEnabled = isEnabled
        save(syncAfterSave: true)
    }

    func setSummariesSectionEnabled(_ isEnabled: Bool) {
        ensureSelectedServerConfig()
        config.summariesSectionEnabled = isEnabled
        save(syncAfterSave: true)
    }

    func setSelectedServerId(_ serverId: String?) {
        guard config.selectedServerId != serverId else { return }
        config.selectedServerId = serverId
        if let serverId {
            config.ensureServerConfig(serverId: serverId)
        }
        save(syncAfterSave: true)
    }

    func sync() {
        sync(showsErrors: true)
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
        config.deviceName = nil
        config.lastCommunicationTimestamp = nil
        config.lastError = nil
        GarminDiagnostics.record(.disconnect, status: .success, metadata: diagnosticsCounts)
        save()
    }

    @discardableResult
    func save(syncAfterSave: Bool = false) -> Bool {
        do {
            try Current.database().write { db in
                try config.insert(db, onConflict: .replace)
            }
            if syncAfterSave, integrationController.connectionState.isReady {
                sync(showsErrors: false)
            }
            return true
        } catch {
            Current.Log.error("Failed to save Garmin config, error: \(error.localizedDescription)")
            showError(message: error.localizedDescription)
            return false
        }
    }

    private var diagnosticsCounts: [String: Any] {
        [
            "connection_state": GarminDiagnostics.connectionState(connectionState),
            "section_count": config.customSections.count,
            "item_count": config.customSections.reduce(0) { $0 + $1.items.count },
            "server_config_count": config.serverConfigs.count,
        ]
    }

    private func sync(showsErrors: Bool) {
        guard config.customSections.count <= GarminConfig.maxCustomSections else {
            if showsErrors {
                showError(message: "Garmin supports up to \(GarminConfig.maxCustomSections) custom sections.")
            }
            GarminDiagnostics.record(.sync, status: .failed, metadata: diagnosticsCounts.merging([
                "error_code": "too_many_sections",
            ]) { current, _ in current })
            return
        }
        guard config.customSections.allSatisfy({ $0.items.count <= GarminConfig.maxSectionItems }) else {
            if showsErrors {
                showError(message: "Garmin supports up to \(GarminConfig.maxSectionItems) items per section.")
            }
            GarminDiagnostics.record(.sync, status: .failed, metadata: diagnosticsCounts.merging([
                "error_code": "too_many_section_items",
            ]) { current, _ in current })
            return
        }

        connectionState = integrationController.connectionState
        GarminDiagnostics.record(.sync, status: .started, metadata: diagnosticsCounts)
        integrationController.sync(config: config, itemInfo: { [weak self] item in
            self?.magicItemInfo(for: item)
        }) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.config.lastSyncTimestamp = Current.date().timeIntervalSince1970
                    self.config.lastError = nil
                    GarminDiagnostics.record(.sync, status: .success, metadata: self.diagnosticsCounts)
                    _ = self.save()
                case let .failure(error):
                    self.config.lastError = error.rawValue
                    if showsErrors {
                        self.showError(message: error.rawValue)
                    }
                    GarminDiagnostics.record(.sync, status: .failed, metadata: self.diagnosticsCounts.merging([
                        "error_code": error.rawValue,
                    ]) { current, _ in current })
                    _ = self.save()
                }
            }
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
            ensureSelectedServerConfig()
            applyPrefilledItemIfNeeded()
            connectionState = integrationController.connectionState
            GarminDiagnostics.record(.configLoad, status: .success, metadata: diagnosticsCounts)
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
        addItem(prefilledItem)
    }

    private func customSectionIndex(sectionId: String?) -> Int? {
        if let sectionId {
            return config.customSections.firstIndex(where: { $0.id == sectionId })
        }
        if config.customSections.isEmpty {
            ensureSelectedServerConfig()
            config.customSections.append(.init(title: "New section"))
        }
        return config.customSections.indices.first
    }

    private func canAddItem(to sectionIndex: Int, item: MagicItem) -> Bool {
        guard config.customSections[sectionIndex].items.count < GarminConfig.maxSectionItems else {
            showError(message: "Garmin supports up to \(GarminConfig.maxSectionItems) items per section.")
            return false
        }
        let exists = config.customSections[sectionIndex].items.contains { existing in
            existing.item.serverUniqueId == item.serverUniqueId
        }
        guard !exists else {
            showError(message: "This item is already in the section.")
            return false
        }
        return true
    }

    private func canUseServer(for item: MagicItem) -> Bool {
        guard let selectedServerId = config.selectedServerId else { return true }
        guard selectedServerId == item.serverId else {
            showError(message: "Garmin sections can only contain items from the selected server.")
            return false
        }
        return true
    }

    private func ensureSelectedServerConfig() {
        if config.selectedServerId == nil {
            config.selectedServerId = servers.first?.identifier.rawValue
        }
        guard let serverId = config.selectedServerId else { return }
        config.ensureServerConfig(serverId: serverId)
    }

    private func applyDefaultConfirmationIfNeeded(to item: inout MagicItem) {
        guard GarminSupportedDomains.supportsAction(item) else { return }
        if item.customization == nil {
            item.customization = .init(requiresConfirmation: GarminActionConfirmationPolicy.defaultRequiresConfirmation(for: item))
        }
    }

    private func refreshPersistedConnectionFields() {
        guard let persistedConfig = try? GarminConfig.config() else { return }
        config.deviceIdentifier = persistedConfig.deviceIdentifier
        config.appIdentifier = persistedConfig.appIdentifier
        config.deviceName = persistedConfig.deviceName
        config.lastCommunicationTimestamp = persistedConfig.lastCommunicationTimestamp
        config.lastError = persistedConfig.lastError
    }

    private func showError(message: String) {
        errorMessage = message
        showError = true
    }
}
