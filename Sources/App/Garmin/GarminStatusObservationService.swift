import Foundation
import GRDB
import HAKit
import Shared
import UIKit

final class GarminStatusObservationService {
    typealias ConfigProvider = () -> GarminConfig?
    typealias SnapshotProvider = (
        GarminConfig,
        @escaping (Swift.Result<GarminStatusSnapshot, GarminBridgeError>) -> Void
    ) -> Void
    typealias SubscriptionProvider = (
        GarminConfig,
        @escaping () -> Void,
        @escaping (GarminBridgeError) -> Void
    ) -> HACancellable?

    private let client: GarminConnectIQClient
    private let configProvider: ConfigProvider
    private let snapshotProvider: SnapshotProvider
    private let subscriptionProvider: SubscriptionProvider
    private let isAppActive: () -> Bool
    private let debounceInterval: TimeInterval
    private let workQueue: DispatchQueue
    private let notificationCenter: NotificationCenter
    private let observeDatabase: Bool

    private var configObservation: AnyDatabaseCancellable?
    private var subscription: HACancellable?
    private var debounceWorkItem: DispatchWorkItem?
    private var currentSignature: ObservationSignature?
    private var isStarted = false
    private var isSending = false
    private var inFlightSnapshotSignature: SnapshotSignature?
    private var lastAttemptedSnapshotSignature: SnapshotSignature?
    private var pendingSnapshot: GarminStatusSnapshot?
    private var sendGeneration = 0

    init(
        client: GarminConnectIQClient,
        configProvider: @escaping ConfigProvider,
        snapshotProvider: @escaping SnapshotProvider,
        subscriptionProvider: @escaping SubscriptionProvider = GarminStatusObservationService.subscribeToStatusChanges,
        isAppActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active },
        debounceInterval: TimeInterval = 0.75,
        workQueue: DispatchQueue = DispatchQueue(label: "io.home-assistant.garmin.status-observation"),
        notificationCenter: NotificationCenter = .default,
        observeDatabase: Bool = true
    ) {
        self.client = client
        self.configProvider = configProvider
        self.snapshotProvider = snapshotProvider
        self.subscriptionProvider = subscriptionProvider
        self.isAppActive = isAppActive
        self.debounceInterval = debounceInterval
        self.workQueue = workQueue
        self.notificationCenter = notificationCenter
        self.observeDatabase = observeDatabase
    }

    deinit {
        stop()
    }

    func start() {
        guard !isStarted else {
            refreshConfiguration()
            return
        }

        isStarted = true
        Current.servers.add(observer: self)
        notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        observeConfigChanges()
        refreshConfiguration()
    }

    func stop() {
        guard isStarted else { return }

        isStarted = false
        notificationCenter.removeObserver(self)
        Current.servers.remove(observer: self)
        configObservation?.cancel()
        configObservation = nil
        cancelActiveObservation(resetDeliveryState: true)
    }

    func refreshConfiguration() {
        let config = configProvider()
        workQueue.async { [weak self] in
            self?.restartObservation(config: config, forceRestart: false)
        }
    }

    private func observeConfigChanges() {
        guard observeDatabase else { return }

        configObservation?.cancel()
        let observation = ValueObservation.tracking(GarminConfig.fetchOne)
        configObservation = observation.start(
            in: Current.database(),
            onError: { error in
                Current.Log.error("Garmin config observation failed with error: \(error)")
            },
            onChange: { [weak self] _ in
                self?.refreshConfiguration()
            }
        )
    }

    @objc private func applicationDidBecomeActive() {
        refreshConfiguration()
    }

    @objc private func applicationDidEnterBackground() {
        workQueue.async { [weak self] in
            self?.cancelActiveObservation()
        }
    }

    private func restartObservation(config: GarminConfig?, forceRestart: Bool) {
        guard isStarted, isAppActive(), let config else { return }

        let signature = ObservationSignature(config: config)
        guard !signature.statusIds.isEmpty else {
            cancelActiveObservation()
            return
        }

        if !forceRestart, currentSignature == signature, subscription != nil {
            refreshSnapshot(config: config, signature: signature)
            return
        }

        cancelActiveObservation()

        currentSignature = signature
        refreshSnapshot(config: config, signature: signature)

        subscription = subscriptionProvider(
            config,
            { [weak self] in
                self?.scheduleSnapshotRefresh(config: config, signature: signature)
            },
            { [weak self] error in
                Current.Log.error("Garmin status subscription failed with error: \(error)")
                self?.scheduleSnapshotRefresh(config: config, signature: signature)
            }
        )

        if subscription == nil {
            Current.Log.error("Garmin status subscription unavailable")
            scheduleSnapshotRefresh(config: config, signature: signature)
        }
    }

    private func cancelActiveObservation(resetDeliveryState: Bool = false) {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        subscription?.cancel()
        subscription = nil
        currentSignature = nil
        pendingSnapshot = nil
        sendGeneration += 1
        isSending = false
        inFlightSnapshotSignature = nil
        if resetDeliveryState {
            lastAttemptedSnapshotSignature = nil
        }
    }

    private func scheduleSnapshotRefresh(config: GarminConfig, signature: ObservationSignature) {
        workQueue.async { [weak self] in
            guard let self, self.currentSignature == signature else { return }

            self.debounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.refreshSnapshot(config: config, signature: signature)
            }
            self.debounceWorkItem = workItem

            if self.debounceInterval <= 0 {
                self.workQueue.async(execute: workItem)
            } else {
                self.workQueue.asyncAfter(deadline: .now() + self.debounceInterval, execute: workItem)
            }
        }
    }

    private func refreshSnapshot(config: GarminConfig, signature: ObservationSignature) {
        snapshotProvider(config) { [weak self] result in
            self?.workQueue.async {
                guard let self, self.currentSignature == signature else { return }

                switch result {
                case let .success(snapshot):
                    self.cache(snapshot, statusIds: signature.statusIds)
                    self.enqueue(snapshot)
                case let .failure(error):
                    Current.Log.error("Garmin status snapshot refresh failed with error: \(error)")
                }
            }
        }
    }

    private func cache(_ snapshot: GarminStatusSnapshot, statusIds: [String]) {
        do {
            try GarminStatusSnapshotCache.save(snapshot, statusIds: statusIds)
        } catch {
            Current.Log.error("Failed to cache Garmin status observation snapshot: \(error)")
        }
    }

    private func enqueue(_ snapshot: GarminStatusSnapshot) {
        guard client.state.isReady else {
            return
        }

        let signature = SnapshotSignature(snapshot: snapshot)

        if signature == lastAttemptedSnapshotSignature {
            return
        }

        if isSending {
            if signature == inFlightSnapshotSignature {
                return
            }
            pendingSnapshot = snapshot
            return
        }

        send(snapshot, signature: signature)
    }

    private func send(_ snapshot: GarminStatusSnapshot, signature: SnapshotSignature) {
        isSending = true
        inFlightSnapshotSignature = signature
        let generation = sendGeneration

        client.sendStatusSnapshot(snapshot) { [weak self] result in
            self?.workQueue.async {
                guard let self, self.sendGeneration == generation else { return }

                if case let .failure(error) = result {
                    Current.Log.error("Failed to send Garmin status snapshot: \(error)")
                }

                self.lastAttemptedSnapshotSignature = signature
                self.isSending = false
                self.inFlightSnapshotSignature = nil

                guard let pendingSnapshot = self.pendingSnapshot else { return }
                self.pendingSnapshot = nil

                let pendingSignature = SnapshotSignature(snapshot: pendingSnapshot)
                guard pendingSignature != self.lastAttemptedSnapshotSignature else { return }
                self.send(pendingSnapshot, signature: pendingSignature)
            }
        }
    }

    private static func subscribeToStatusChanges(
        config: GarminConfig,
        onStateChange: @escaping () -> Void,
        onFailure: @escaping (GarminBridgeError) -> Void
    ) -> HACancellable? {
        let itemsByServer = Dictionary(grouping: observedStatusItems(config), by: \.serverId)
        let cancellable = GarminCompositeCancellable()

        for (serverId, items) in itemsByServer {
            guard let server = Current.servers.server(forServerIdentifier: serverId),
                  let api = Current.api(for: server) else {
                onFailure(.missingServer)
                continue
            }

            var filter: [String: Any] = [:]
            if server.info.version > .canSubscribeEntitiesChangesWithFilter {
                filter = [
                    "include": [
                        "entities": items.map(\.id),
                    ],
                ]
            }

            let tracker = GarminObservedEntityStateTracker(entityIds: Set(items.map(\.id)))
            cancellable.append(api.connection.caches.states(filter).subscribe { _, states in
                if tracker.shouldRefresh(states: states.all) {
                    onStateChange()
                }
            })
        }

        return cancellable.isEmpty ? nil : cancellable
    }

    private static func observedStatusItems(_ config: GarminConfig) -> [MagicItem] {
        config.statusItems
            .prefix(GarminConfig.maxStatusItems)
            .filter { GarminSupportedDomains.supportsStatus($0) }
    }
}

final class GarminObservedEntityStateTracker {
    private let entityIds: Set<String>
    private var lastSignature: [GarminObservedEntityStateSignature]?

    init(entityIds: Set<String>) {
        self.entityIds = entityIds
    }

    func shouldRefresh(states: [HAEntity]) -> Bool {
        let statesById = Dictionary(uniqueKeysWithValues: states.map { ($0.entityId, $0) })
        let signature = entityIds.sorted().map { entityId in
            GarminObservedEntityStateSignature(entityId: entityId, entity: statesById[entityId])
        }

        guard let lastSignature else {
            self.lastSignature = signature
            return false
        }

        guard signature != lastSignature else {
            return false
        }

        self.lastSignature = signature
        return true
    }
}

private struct GarminObservedEntityStateSignature: Equatable {
    let entityId: String
    let state: String?
    let unitOfMeasurement: String?
    let friendlyName: String?
    let icon: String?
    let deviceClass: String?

    init(entityId: String, entity: HAEntity?) {
        self.entityId = entityId
        self.state = entity?.state
        self.unitOfMeasurement = entity?.attributes.dictionary["unit_of_measurement"] as? String
        self.friendlyName = entity?.attributes.dictionary["friendly_name"] as? String
        self.icon = entity?.attributes.dictionary["icon"] as? String
        self.deviceClass = entity?.attributes.dictionary["device_class"] as? String
    }
}

extension GarminStatusObservationService: ServerObserver {
    func serversDidChange(_ serverManager: ServerManager) {
        let config = configProvider()
        workQueue.async { [weak self] in
            self?.restartObservation(config: config, forceRestart: true)
        }
    }
}

private final class GarminCompositeCancellable: HACancellable {
    private var cancellables: [HACancellable] = []

    var isEmpty: Bool {
        cancellables.isEmpty
    }

    func append(_ cancellable: HACancellable) {
        cancellables.append(cancellable)
    }

    func cancel() {
        let cancellables = cancellables
        self.cancellables.removeAll()
        cancellables.forEach { $0.cancel() }
    }
}

private struct ObservationSignature: Equatable {
    let statusIds: [String]
    let entityIdsByServer: [String: [String]]

    init(config: GarminConfig) {
        let items = config.statusItems
            .prefix(GarminConfig.maxStatusItems)
            .filter { GarminSupportedDomains.supportsStatus($0) }

        statusIds = items.map { GarminConfig.opaqueStatusId(for: $0) }
        entityIdsByServer = Dictionary(grouping: items, by: \.serverId).mapValues { items in
            items.map(\.id).sorted()
        }
    }
}

private struct SnapshotSignature: Equatable {
    let values: [SnapshotValueSignature]

    init(snapshot: GarminStatusSnapshot) {
        values = snapshot.statuses.map {
            SnapshotValueSignature(id: $0.id, label: $0.label, value: $0.value, iconName: $0.iconName)
        }
    }
}

private struct SnapshotValueSignature: Equatable {
    let id: String
    let label: String
    let value: String
    let iconName: String?
}
