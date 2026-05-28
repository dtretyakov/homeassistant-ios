@testable import HomeAssistant
@testable import Shared
import Testing

struct GarminOutboundMessageQueueTests {
    @Test func delayedFirstCompletionBlocksSecondSend() throws {
        let queue = GarminOutboundMessageQueue()
        queue.enqueue(
            message: GarminOutboundMessage(type: .sectionNotModified, id: "root"),
            isTransient: false,
            completion: { _ in }
        )
        queue.enqueue(
            message: GarminOutboundMessage(type: .actionResult, actionResult: .init(id: "action-1", correlationId: "c1", state: .success)),
            isTransient: false,
            completion: { _ in }
        )

        let first = try #require(queue.startNext())
        #expect(first.message.type == .sectionNotModified)
        #expect(queue.startNext() == nil)

        queue.finishCurrent()
        let second = try #require(queue.startNext())
        #expect(second.message.type == .actionResult)
    }

    @Test func sectionThenValuesPreservesOrder() throws {
        let queue = GarminOutboundMessageQueue()
        queue.enqueue(
            message: GarminOutboundMessage(type: .sectionSnapshot, section: .init(id: "s1", title: "Section", etag: "e1", items: [])),
            isTransient: false,
            completion: { _ in }
        )
        queue.enqueue(
            message: GarminOutboundMessage(
                type: .valuesDelta,
                values: [.init(id: "value-1", value: "20 °C")],
                valuesRevision: 1
            ),
            isTransient: true,
            completion: { _ in }
        )

        let first = try #require(queue.startNext())
        #expect(first.message.type == .sectionSnapshot)
        queue.finishCurrent()
        let second = try #require(queue.startNext())
        #expect(second.message.type == .valuesDelta)
    }

    @Test func pendingTransientValuesCoalesceByItemId() throws {
        let queue = GarminOutboundMessageQueue()
        var completions = 0
        queue.enqueue(
            message: GarminOutboundMessage(
                type: .valuesDelta,
                values: [
                    .init(id: "temperature", value: "20 °C"),
                    .init(id: "humidity", value: "40%"),
                ],
                valuesRevision: 1
            ),
            isTransient: true,
            completion: { _ in completions += 1 }
        )
        queue.enqueue(
            message: GarminOutboundMessage(
                type: .valuesDelta,
                values: [
                    .init(id: "temperature", value: "21 °C"),
                ],
                valuesRevision: 2
            ),
            isTransient: true,
            completion: { _ in completions += 1 }
        )

        let queued = try #require(queue.startNext())

        #expect(queued.message.type == .valuesDelta)
        #expect(queued.message.valuesRevision == 2)
        #expect(queued.message.values == [
            .init(id: "temperature", value: "21 °C"),
            .init(id: "humidity", value: "40%"),
        ])
        queued.complete(.success(()))
        #expect(completions == 2)
    }

    @Test func pendingTransientValuesCoalesceDuplicateIdsWithoutCrashing() throws {
        let queue = GarminOutboundMessageQueue()
        queue.enqueue(
            message: GarminOutboundMessage(
                type: .valuesDelta,
                values: [
                    .init(id: "temperature", value: "19 °C"),
                    .init(id: "temperature", value: "20 °C"),
                ],
                valuesRevision: 1
            ),
            isTransient: true,
            completion: { _ in }
        )
        queue.enqueue(
            message: GarminOutboundMessage(
                type: .valuesDelta,
                values: [
                    .init(id: "temperature", value: "21 °C"),
                ],
                valuesRevision: 2
            ),
            isTransient: true,
            completion: { _ in }
        )

        let queued = try #require(queue.startNext())

        #expect(queued.message.values == [
            .init(id: "temperature", value: "21 °C"),
        ])
        #expect(queued.message.valuesRevision == 2)
    }

    @Test func reliableResultDoesNotOvertakeQueuedValues() throws {
        let queue = GarminOutboundMessageQueue()
        queue.enqueue(
            message: GarminOutboundMessage(type: .sectionNotModified, id: "root"),
            isTransient: false,
            completion: { _ in }
        )
        queue.enqueue(
            message: GarminOutboundMessage(
                type: .valuesDelta,
                values: [.init(id: "temperature", value: "20 °C")],
                valuesRevision: 1
            ),
            isTransient: true,
            completion: { _ in }
        )
        queue.enqueue(
            message: GarminOutboundMessage(type: .actionResult, actionResult: .init(id: "action-1", correlationId: "c1", state: .success)),
            isTransient: false,
            completion: { _ in }
        )
        queue.enqueue(
            message: GarminOutboundMessage(
                type: .valuesDelta,
                values: [.init(id: "temperature", value: "21 °C")],
                valuesRevision: 2
            ),
            isTransient: true,
            completion: { _ in }
        )

        #expect(queue.startNext()?.message.type == .sectionNotModified)
        queue.finishCurrent()
        let firstValues = try #require(queue.startNext())
        #expect(firstValues.message.type == .valuesDelta)
        #expect(firstValues.message.valuesRevision == 1)
        queue.finishCurrent()
        #expect(queue.startNext()?.message.type == .actionResult)
        queue.finishCurrent()
        let secondValues = try #require(queue.startNext())
        #expect(secondValues.message.type == .valuesDelta)
        #expect(secondValues.message.valuesRevision == 2)
    }

    @Test func transientFailureDoesNotBlockLaterReliableSend() throws {
        let queue = GarminOutboundMessageQueue()
        var valuesResult: Result<Void, GarminIntegrationError>?
        queue.enqueue(
            message: GarminOutboundMessage(
                type: .valuesDelta,
                values: [.init(id: "temperature", value: "20 °C")],
                valuesRevision: 1
            ),
            isTransient: true,
            completion: { valuesResult = $0 }
        )
        queue.enqueue(
            message: GarminOutboundMessage(type: .actionResult, actionResult: .init(id: "action-1", correlationId: "c1", state: .success)),
            isTransient: false,
            completion: { _ in }
        )

        let values = try #require(queue.startNext())
        values.complete(.failure(.watchUnavailable))
        queue.finishCurrent()
        let result = try #require(queue.startNext())

        guard case .failure(.watchUnavailable) = valuesResult else {
            Issue.record("Expected transient values completion to receive watchUnavailable failure")
            return
        }
        #expect(result.message.type == .actionResult)
    }
}
