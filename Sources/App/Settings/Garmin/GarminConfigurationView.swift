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
                overviewSectionsSection
                customSectionsSection
            }

            #if DEBUG
            diagnosticsSection
            #endif
        }
        .navigationTitle("Garmin")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isGarminPaired, !viewModel.config.customSections.isEmpty {
                    EditButton()
                }
            }
        }
        .onAppear {
            guard !isLoaded else { return }
            viewModel.loadConfig()
            isLoaded = true
        }
        .sheet(isPresented: $viewModel.showAddItem) {
            MagicItemAddView(
                context: .garmin,
                initialItemType: .entities,
                visiblePickerOptions: [.entities],
                garminRawDomainFilters: GarminSupportedDomains.overviewDomainRawValues,
                showsConfirmationToggle: true
            ) { item in
                guard let item else { return }
                viewModel.addItem(item, to: viewModel.targetCustomSectionId)
            }
        }
        .alert(viewModel.errorMessage ?? "Garmin error", isPresented: $viewModel.showError) {
            Button("OK") {}
        }
        .confirmationDialog(
            "Unpair Garmin watch?",
            isPresented: $isShowingUnpairConfirmation,
            titleVisibility: .visible
        ) {
            Button("Unpair Garmin watch", role: .destructive) {
                viewModel.disconnect()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the Garmin watch pairing from Home Assistant. Your custom sections will stay configured.")
        }
    }

    private var noServerSection: some View {
        Section {
            Text("Add a Home Assistant server before choosing Garmin sections.")
                .foregroundStyle(.secondary)
            NavigationLink("Servers") {
                SettingsServersView()
            }
        }
    }

    private var serverSection: some View {
        Section("Home Assistant") {
            Picker("Server", selection: Binding(
                get: { viewModel.config.selectedServerId },
                set: { viewModel.setSelectedServerId($0) }
            )) {
                ForEach(viewModel.servers, id: \.identifier.rawValue) { server in
                    Text(server.info.name).tag(Optional(server.identifier.rawValue))
                }
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
                Button("Unpair Garmin watch", role: .destructive) {
                    isShowingUnpairConfirmation = true
                }
            } else {
                Button(pairingActionTitle) {
                    viewModel.checkConnection()
                }
                .disabled(isPairingInProgress)
            }
            if isPairingInProgress {
                Text("Open Home Assistant on the watch and keep this screen open.")
                    .foregroundStyle(.secondary)
            } else if !isGarminPaired {
                Text("Select your Garmin watch, then open Home Assistant on the watch.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var overviewSectionsSection: some View {
        Section {
            Toggle(
                "Areas",
                isOn: Binding(
                    get: { viewModel.config.areasSectionEnabled },
                    set: { viewModel.setAreasSectionEnabled($0) }
                )
            )
            Toggle(
                "Summaries",
                isOn: Binding(
                    get: { viewModel.config.summariesSectionEnabled },
                    set: { viewModel.setSummariesSectionEnabled($0) }
                )
            )
        } header: {
            Text("Overview sections")
        } footer: {
            Text("Built-in Home Assistant sections are shown on Garmin when data is available.")
        }
    }

    private var customSectionsSection: some View {
        Section {
            ForEach(viewModel.config.customSections) { section in
                NavigationLink {
                    GarminCustomSectionDetailView(viewModel: viewModel, sectionId: section.id)
                } label: {
                    HStack {
                        Text(section.title)
                        Spacer()
                        Text("\(section.items.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                viewModel.deleteCustomSection(at: offsets)
            }
            .onMove { source, destination in
                viewModel.moveCustomSection(from: source, to: destination)
            }

            Button {
                viewModel.addCustomSection()
            } label: {
                Label("Add section", systemSymbol: .plus)
            }
            .disabled(viewModel.config.customSections.count >= GarminConfig.maxCustomSections)

            Text("\(viewModel.config.customSections.count)/\(GarminConfig.maxCustomSections) sections.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Custom sections")
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

    private var isGarminPaired: Bool {
        viewModel.config.deviceIdentifier != nil
    }

    private var pairedDeviceText: String {
        guard viewModel.config.deviceIdentifier != nil else { return "Not paired" }
        return viewModel.config.deviceName ?? "Garmin watch"
    }

    private var pairingActionTitle: String {
        switch viewModel.connectionState {
        case .selectingDevice:
            return "Selecting Garmin watch..."
        case let .waitingForWatch(deviceName):
            return "Waiting for \(deviceName ?? "Garmin watch")"
        default:
            return "Pair Garmin watch"
        }
    }

    private var isPairingInProgress: Bool {
        switch viewModel.connectionState {
        case .selectingDevice, .waitingForWatch:
            return true
        default:
            return false
        }
    }
}

private struct GarminCustomSectionDetailView: View {
    @ObservedObject var viewModel: GarminConfigurationViewModel
    let sectionId: String
    @State private var draftTitle = ""

    var body: some View {
        List {
            titleSection
            itemsSection
        }
        .navigationTitle(section?.title ?? "Section")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !(section?.items.isEmpty ?? true) {
                    EditButton()
                }
            }
        }
        .onAppear {
            draftTitle = section?.title ?? ""
        }
        .onDisappear {
            commitTitle()
        }
    }

    private var section: GarminCustomSection? {
        viewModel.customSection(sectionId: sectionId)
    }

    private var titleSection: some View {
        Section("Section") {
            TextField(
                "Name",
                text: $draftTitle
            )
            .onSubmit(commitTitle)
        }
    }

    private var itemsSection: some View {
        Section {
            ForEach(section?.items ?? []) { customItem in
                NavigationLink {
                    MagicItemCustomizationView(
                        mode: .edit,
                        context: .garmin,
                        item: customItem.item,
                        showsConfirmationToggle: GarminSupportedDomains.supportsAction(customItem.item)
                    ) { updatedItem in
                        viewModel.updateCustomItem(
                            sectionId: sectionId,
                            itemId: customItem.id,
                            updatedItem: updatedItem
                        )
                    }
                } label: {
                    customItemRow(customItem)
                }
            }
            .onDelete { offsets in
                viewModel.deleteCustomItem(sectionId: sectionId, at: offsets)
            }
            .onMove { source, destination in
                viewModel.moveCustomItem(sectionId: sectionId, from: source, to: destination)
            }

            Button {
                viewModel.beginAddingItem(to: sectionId)
            } label: {
                Label("Add item", systemSymbol: .plus)
            }
            .disabled((section?.items.count ?? 0) >= GarminConfig.maxSectionItems)

            Text("\(section?.items.count ?? 0)/\(GarminConfig.maxSectionItems) items.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Items")
        }
    }

    private func customItemRow(_ customItem: GarminCustomSectionItem) -> some View {
        let item = customItem.item
        let info = viewModel.magicItemInfo(for: item) ?? .init(
            id: item.id,
            name: item.displayText ?? item.id,
            iconName: ""
        )
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name(info: info))
                Text(capabilityText(for: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.domain?.rawValue ?? item.type.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func capabilityText(for item: MagicItem) -> String {
        let capability = GarminConfig.capability(for: item)
        if capability == (GarminConfig.valueCapability | GarminConfig.actionCapability) {
            return "Value and action"
        } else if capability & GarminConfig.actionCapability != 0 {
            return "Action"
        } else {
            return "Value"
        }
    }

    private func commitTitle() {
        viewModel.updateCustomSectionTitle(sectionId: sectionId, title: draftTitle)
    }
}
