import SFSafeSymbols
import Shared
import SwiftUI

struct GarminConfigurationView: View {
    @StateObject private var viewModel: GarminConfigurationViewModel
    @State private var isLoaded = false
    @State private var isShowingUnpairConfirmation = false

    init(viewModel: GarminConfigurationViewModel = GarminConfigurationViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        List {
            connectionSection

            if viewModel.servers.isEmpty {
                noServerSection
            } else if isGarminPaired {
                if viewModel.servers.count > 1 {
                    serverSection
                }
                recommendedActionsSection
                actionsSection
                if GarminFeature.supportsStatusItems {
                    recommendedStatusesSection
                    statusSection
                }
            }

            #if DEBUG
            diagnosticsSection
            #endif
        }
        .navigationTitle("Garmin")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isGarminPaired && (!viewModel.config.actionItems.isEmpty || !viewModel.config.statusItems.isEmpty) {
                    EditButton()
                }
            }
        }
        .onAppear {
            guard !isLoaded else { return }
            viewModel.loadConfig()
            isLoaded = true
        }
        .sheet(isPresented: $viewModel.showAddAction) {
            MagicItemAddView(
                context: .garmin,
                initialItemType: .entities,
                visiblePickerOptions: [.entities]
            ) { item in
                guard let item else { return }
                viewModel.addAction(item)
            }
        }
        .sheet(isPresented: $viewModel.showAddStatus) {
            if GarminFeature.supportsStatusItems {
                MagicItemAddView(
                    context: .garmin,
                    initialItemType: .entities,
                    visiblePickerOptions: [.entities],
                    garminRawDomainFilters: Array(GarminSupportedDomains.statusDomainRawValues),
                    showsConfirmationToggle: false
                ) { item in
                    guard let item else { return }
                    viewModel.addStatus(item)
                }
            }
        }
        .alert(viewModel.errorMessage ?? "Garmin error", isPresented: $viewModel.showError) {
            Button("OK") {}
        }
        .confirmationDialog(
            "Unpair Garmin Watch?",
            isPresented: $isShowingUnpairConfirmation,
            titleVisibility: .visible
        ) {
            Button("Unpair Garmin Watch", role: .destructive) {
                viewModel.disconnect()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the Garmin watch pairing from Home Assistant. Your actions and statuses will stay configured.")
        }
    }

    private var noServerSection: some View {
        Section {
            Text("Add a Home Assistant server before choosing Garmin actions and statuses.")
                .foregroundStyle(.secondary)
            NavigationLink("Servers") {
                SettingsServersView()
            }
        }
    }

    private var serverSection: some View {
        Section("Home Assistant") {
            Picker("Server", selection: $viewModel.config.selectedServerId) {
                ForEach(viewModel.servers, id: \.identifier.rawValue) { server in
                    Text(server.info.name).tag(Optional(server.identifier.rawValue))
                }
            }
            .onChange(of: viewModel.config.selectedServerId) { _ in
                viewModel.save()
                viewModel.refreshDiscovery()
            }
        }
    }

    private var connectionSection: some View {
        Section("Garmin Watch") {
            HStack {
                Text("Paired device")
                Spacer()
                Text(pairedDeviceText)
                    .foregroundStyle(.secondary)
            }
            #if DEBUG
            HStack {
                Text("Last communication")
                Spacer()
                if let timestamp = viewModel.config.lastCommunicationTimestamp {
                    Text(Date(timeIntervalSince1970: timestamp), style: .relative)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Never")
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top) {
                Text("Transport")
                Spacer()
                Text(viewModel.connectionDiagnostics.displayText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            #endif
            if isGarminPaired {
                Button("Unpair Garmin Watch", role: .destructive) {
                    isShowingUnpairConfirmation = true
                }
            } else {
                Button(pairingActionTitle) {
                    viewModel.checkConnection()
                }
                .disabled(isPairingInProgress)
            }
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            ForEach(viewModel.config.actionItems, id: \.serverUniqueId) { item in
                NavigationLink {
                    MagicItemCustomizationView(mode: .edit, context: .garmin, item: item) { updatedItem in
                        viewModel.updateAction(updatedItem)
                    }
                } label: {
                    magicItemRow(item)
                }
            }
            .onDelete { offsets in
                viewModel.deleteAction(at: offsets)
            }
            .onMove { source, destination in
                viewModel.moveAction(from: source, to: destination)
            }
            Button {
                viewModel.showAddAction = true
            } label: {
                Label("Add action", systemSymbol: .plus)
            }
        }
    }

    @ViewBuilder
    private var recommendedActionsSection: some View {
        let candidates = viewModel.discoveryResult.recommendedActions.filter {
            !viewModel.isActionSelected($0)
        }
        if !candidates.isEmpty {
            Section("Recommended actions") {
                ForEach(candidates) { candidate in
                    Button {
                        viewModel.addRecommendedAction(candidate)
                    } label: {
                        candidateRow(candidate)
                    }
                }
            }
        }
    }

    private var statusSection: some View {
        Section("Statuses") {
            ForEach(viewModel.config.statusItems, id: \.serverUniqueId) { item in
                NavigationLink {
                    MagicItemCustomizationView(
                        mode: .edit,
                        context: .garmin,
                        item: item,
                        showsConfirmationToggle: false
                    ) { updatedItem in
                        viewModel.updateStatus(updatedItem)
                    }
                } label: {
                    magicItemRow(item)
                }
            }
            .onDelete { offsets in
                viewModel.deleteStatus(at: offsets)
            }
            .onMove { source, destination in
                viewModel.moveStatus(from: source, to: destination)
            }
            Button {
                viewModel.showAddStatus = true
            } label: {
                Label("Add status", systemSymbol: .plus)
            }
        }
    }

    @ViewBuilder
    private var recommendedStatusesSection: some View {
        let candidates = viewModel.discoveryResult.recommendedStatuses.filter {
            !viewModel.isStatusSelected($0)
        }
        if !candidates.isEmpty {
            Section("Recommended statuses") {
                ForEach(candidates) { candidate in
                    Button {
                        viewModel.addRecommendedStatus(candidate)
                    } label: {
                        candidateRow(candidate)
                    }
                }
            }
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            NavigationLink("Diagnostics log") {
                ClientEventsLogView(initialTypeFilter: .garmin)
            }
            if let lastSyncTimestamp = viewModel.config.lastSyncTimestamp {
                HStack {
                    Text("Last sync")
                    Spacer()
                    Text(Date(timeIntervalSince1970: lastSyncTimestamp), style: .relative)
                        .foregroundStyle(.secondary)
                }
            }
            if let lastError = viewModel.config.lastError {
                HStack {
                    Text("Last error")
                    Spacer()
                    Text(lastError)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func magicItemRow(_ item: MagicItem) -> some View {
        let info = viewModel.magicItemInfo(for: item) ?? .init(
            id: item.id,
            name: item.displayText ?? item.id,
            iconName: ""
        )
        return HStack {
            Text(item.name(info: info))
            Spacer()
            Text(item.domain?.rawValue ?? item.type.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func candidateRow(_ candidate: GarminEntityCandidate) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .foregroundStyle(.primary)
                Text(candidateDetail(candidate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "plus.circle")
                .foregroundStyle(Color.accentColor)
        }
    }

    private func candidateDetail(_ candidate: GarminEntityCandidate) -> String {
        var parts = [candidate.domain]
        if let areaName = candidate.areaName {
            parts.append(areaName)
        }
        if candidate.requiresConfirmation {
            parts.append("Confirmation")
        }
        return parts.joined(separator: " - ")
    }

    private var isGarminPaired: Bool {
        viewModel.config.deviceIdentifier != nil
    }

    private var pairedDeviceText: String {
        guard viewModel.config.deviceIdentifier != nil else { return "Not paired" }
        return viewModel.config.deviceName ?? "Garmin watch"
    }

    private var pairingActionTitle: String {
        switch viewModel.connectionState {
        case .selectingDevice, .waitingForWatch:
            return "Pairing..."
        case .notConfigured, .sdkUnavailable, .appUnavailable, .deviceUnavailable, .ready:
            return "Pair Garmin Watch"
        }
    }

    private var isPairingInProgress: Bool {
        switch viewModel.connectionState {
        case .selectingDevice, .waitingForWatch:
            return true
        case .notConfigured, .sdkUnavailable, .appUnavailable, .deviceUnavailable, .ready:
            return false
        }
    }
}

#Preview {
    GarminConfigurationView()
}
