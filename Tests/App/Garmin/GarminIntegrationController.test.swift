import Combine
import Foundation
@testable import HomeAssistant
@testable import Shared
import Testing

@Suite(.serialized)
struct GarminIntegrationControllerTests {
    @Test func publishesClientConnectionState() {
        let client = ControllerGarminClient()
        let controller = GarminIntegrationController(client: client)
        var publishedStates: [GarminConnectionState] = []

        let cancellable = controller.connectionStatePublisher.sink { state in
            publishedStates.append(state)
        }
        client.state = .waitingForWatch(deviceName: "Venu 2")

        #expect(controller.connectionState == .waitingForWatch(deviceName: "Venu 2"))
        #expect(publishedStates.contains(.waitingForWatch(deviceName: "Venu 2")))
        withExtendedLifetime(cancellable) {}
    }

    @Test func routesConnectIQCallbackToOwnedClient() {
        let client = ControllerGarminClient()
        let controller = GarminIntegrationController(client: client)
        let url = URL(string: "homeassistant-garmin-ciq://device-select-resp")!

        let handled = controller.handleConnectIQURL(url)

        #expect(handled)
        #expect(client.handledDeviceSelectionURLs == [url])
    }

    @Test func connectionCheckRequestsForcedDeviceSelection() {
        let client = ControllerGarminClient()
        let controller = GarminIntegrationController(client: client)

        controller.requestConnectionCheck(force: true)

        #expect(client.requestedDeviceSelectionForces == [true])
    }
}

private final class ControllerGarminClient: GarminConnectIQClient {
    var state: GarminConnectionState = .notConfigured {
        didSet {
            guard state != oldValue else { return }
            stateSubject.send(state)
        }
    }
    var statePublisher: AnyPublisher<GarminConnectionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }
    private let stateSubject = CurrentValueSubject<GarminConnectionState, Never>(.notConfigured)
    var requestedDeviceSelectionForces: [Bool] = []
    var handledDeviceSelectionURLs: [URL] = []

    func setup(commandHandler: @escaping (GarminInboundMessage) -> Void) {}

    func sendActionResult(
        _ result: GarminCommandResult,
        completion: @escaping (Result<Void, GarminIntegrationError>) -> Void
    ) {
        completion(.success(()))
    }

    func disconnect() {
        state = .notConfigured
    }

    func requestDeviceSelection(force: Bool) {
        requestedDeviceSelectionForces.append(force)
        state = .selectingDevice
    }

    func handleDeviceSelectionResponse(_ url: URL) -> Bool {
        handledDeviceSelectionURLs.append(url)
        return GarminFeature.canHandleConnectIQURL(url)
    }
}
