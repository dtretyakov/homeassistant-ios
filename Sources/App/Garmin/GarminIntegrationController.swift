import Combine
import Foundation
import Shared

protocol GarminIntegrationControlling: AnyObject {
    var connectionState: GarminConnectionState { get }
    var connectionStatePublisher: AnyPublisher<GarminConnectionState, Never> { get }
    func setup()
    func handleConnectIQURL(_ url: URL) -> Bool
    func requestConnectionCheck(force: Bool)
    func sync(
        config: GarminConfig,
        itemInfo: @escaping (MagicItem) -> MagicItem.Info?,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    )
    func disconnect(config: GarminConfig, completion: @escaping (Result<Void, GarminIntegrationError>) -> Void)
}

final class GarminIntegrationController: GarminIntegrationControlling {
    private let client: GarminConnectIQClient
    private let integrationService: GarminIntegrationService
    private let statusSnapshotService: GarminStatusSnapshotService
    private let magicItemProvider: MagicItemProviderProtocol
    private var statusObservationService: GarminStatusObservationService?
    private var cancellables = Set<AnyCancellable>()
    private var isSetup = false

    private let connectionStateSubject: CurrentValueSubject<GarminConnectionState, Never>
    var connectionState: GarminConnectionState { connectionStateSubject.value }
    var connectionStatePublisher: AnyPublisher<GarminConnectionState, Never> {
        connectionStateSubject.eraseToAnyPublisher()
    }

    init(
        client: GarminConnectIQClient = GarminConnectIQSDKClient(),
        magicItemProvider: MagicItemProviderProtocol = Current.magicItemProvider(),
        statusSnapshotService: GarminStatusSnapshotService = GarminStatusSnapshotService()
    ) {
        self.client = client
        self.integrationService = GarminIntegrationService(client: client)
        self.statusSnapshotService = statusSnapshotService
        self.magicItemProvider = magicItemProvider
        self.connectionStateSubject = CurrentValueSubject(client.state)

        client.statePublisher
            .sink { [connectionStateSubject] state in
                connectionStateSubject.send(state)
            }
            .store(in: &cancellables)
    }

    func setup() {
        guard !isSetup else { return }
        isSetup = true

        do {
            try GarminDatabaseSchema.createIfNeeded()
        } catch {
            Current.Log.error("Failed to initialize Garmin database schema, error: \(error.localizedDescription)")
            return
        }

        magicItemProvider.loadInformation { _ in }
        let statusSnapshotProvider: GarminStatusObservationService.SnapshotProvider = { [statusSnapshotService, magicItemProvider] config, completion in
            Task {
                let result = await statusSnapshotService.snapshotWithCacheFallback(
                    config: config,
                    itemInfo: { magicItemProvider.getInfo(for: $0) }
                )
                completion(result)
            }
        }

        integrationService.setup(
            configProvider: { try? GarminConfig.config() },
            itemInfoProvider: { [magicItemProvider] in magicItemProvider.getInfo(for: $0) },
            statusSnapshotProvider: statusSnapshotProvider
        )

        let observationService = GarminStatusObservationService(
            client: client,
            configProvider: { try? GarminConfig.config() },
            snapshotProvider: statusSnapshotProvider
        )
        observationService.start()
        statusObservationService = observationService
    }

    func handleConnectIQURL(_ url: URL) -> Bool {
        client.handleDeviceSelectionResponse(url)
    }

    func requestConnectionCheck(force: Bool) {
        GarminDiagnostics.record(.sync, status: .started, metadata: [
            "connection_state": GarminDiagnostics.connectionState(connectionState),
            "check_type": "garmin_connection_check",
        ])
        integrationService.requestDeviceSelection(force: force)
    }

    func sync(
        config: GarminConfig,
        itemInfo: @escaping (MagicItem) -> MagicItem.Info?,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
        integrationService.sync(config: config, itemInfo: itemInfo, completion: completion)
    }

    func disconnect(config: GarminConfig, completion: @escaping (Result<Void, GarminIntegrationError>) -> Void) {
        integrationService.disconnect(config: config, completion: completion)
    }
}

final class DisabledGarminIntegrationController: GarminIntegrationControlling {
    private let connectionStateSubject: CurrentValueSubject<GarminConnectionState, Never>
    var connectionState: GarminConnectionState { connectionStateSubject.value }
    var connectionStatePublisher: AnyPublisher<GarminConnectionState, Never> {
        connectionStateSubject.eraseToAnyPublisher()
    }

    init(state: GarminConnectionState = .sdkUnavailable) {
        connectionStateSubject = CurrentValueSubject(state)
    }

    func setup() {}

    func handleConnectIQURL(_ url: URL) -> Bool {
        false
    }

    func requestConnectionCheck(force: Bool) {
        GarminDiagnostics.record(.sync, status: .failed, metadata: [
            "connection_state": GarminDiagnostics.connectionState(connectionState),
            "check_type": "garmin_connection_check",
            "error_code": GarminIntegrationError.sdkUnavailable.rawValue,
        ])
    }

    func sync(
        config: GarminConfig,
        itemInfo: @escaping (MagicItem) -> MagicItem.Info?,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
        completion(.failure(.sdkUnavailable))
    }

    func disconnect(config: GarminConfig, completion: @escaping (Result<Void, GarminIntegrationError>) -> Void) {
        completion(.success(()))
    }
}
