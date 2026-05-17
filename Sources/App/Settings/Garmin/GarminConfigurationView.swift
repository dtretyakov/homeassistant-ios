import SFSafeSymbols
import Shared
import SwiftUI

struct GarminConfigurationView: View {
    @StateObject private var viewModel: GarminConfigurationViewModel
    @State private var isLoaded = false

    init(viewModel: GarminConfigurationViewModel = GarminConfigurationViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        List {
            if viewModel.servers.isEmpty {
                noServerSection
            } else {
                serverSection
                connectionSection
                actionsSection
                if GarminFeature.supportsStatusItems {
                    statusSection
                }
                diagnosticsSection
            }
        }
        .navigationTitle("Garmin")
        .navigationBarTitleDisplayMode(.inline)
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
                    visiblePickerOptions: [.entities]
                ) { item in
                    guard let item else { return }
                    viewModel.addStatus(item)
                }
            }
        }
        .alert(viewModel.errorMessage ?? "Garmin error", isPresented: $viewModel.showError) {
            Button("OK") {}
        }
    }

    private var noServerSection: some View {
        Section {
            Text("Add a Home Assistant server before configuring Garmin.")
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
            }
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            HStack {
                Text("State")
                Spacer()
                Text(connectionStateText)
                    .foregroundStyle(.secondary)
            }
            Button("Sync to Garmin") {
                viewModel.sync()
            }
            Button("Disconnect Garmin", role: .destructive) {
                viewModel.disconnect()
            }
        }
    }

    private var actionsSection: some View {
        Section("Actions") {
            ForEach(viewModel.config.actionItems, id: \.serverUniqueId) { item in
                magicItemRow(item)
            }
            .onDelete { offsets in
                viewModel.deleteAction(at: offsets)
            }
            Button {
                viewModel.showAddAction = true
            } label: {
                Label("Add action", systemSymbol: .plus)
            }
        }
    }

    private var statusSection: some View {
        Section("Statuses") {
            ForEach(viewModel.config.statusItems, id: \.serverUniqueId) { item in
                magicItemRow(item)
            }
            .onDelete { offsets in
                viewModel.deleteStatus(at: offsets)
            }
            Button {
                viewModel.showAddStatus = true
            } label: {
                Label("Add status", systemSymbol: .plus)
            }
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
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
        let info = viewModel.magicItemInfo(for: item) ?? .init(id: item.id, name: item.displayText ?? item.id, iconName: "")
        return HStack {
            Text(item.name(info: info))
            Spacer()
            Text(item.domain?.rawValue ?? item.type.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var connectionStateText: String {
        switch viewModel.connectionState {
        case .notConfigured:
            return "Not configured"
        case .sdkUnavailable:
            return "SDK unavailable"
        case .appUnavailable:
            return "Garmin app unavailable"
        case .deviceUnavailable:
            return "Device unavailable"
        case let .ready(deviceName):
            return deviceName ?? "Ready"
        }
    }
}

#Preview {
    GarminConfigurationView()
}
