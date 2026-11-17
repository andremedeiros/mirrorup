@testable import MirrorupCapture
import Testing

@Suite("Latest frame buffer")
struct LatestFrameBufferTests {
    @Test func returnsNewerFrameImmediately() async {
        let buffer = LatestFrameBuffer()
        buffer.publish(makeDecodedFrame(sequence: 3))
        let frame = await buffer.next(after: 0)
        #expect(frame?.sequence == 3)
    }

    @Test func waitsForAFrameNewerThanTheGivenSequence() async throws {
        let buffer = LatestFrameBuffer()
        buffer.publish(makeDecodedFrame(sequence: 1))
        let waiter = Task { await buffer.next(after: 1) }
        try await waitUntil("waiter registered") { buffer.waiterCount == 1 }
        buffer.publish(makeDecodedFrame(sequence: 2))
        #expect(await waiter.value?.sequence == 2)
        #expect(buffer.waiterCount == 0)
    }

    @Test func newestFrameWinsAndUnconsumedFramesCountAsDrops() async {
        let buffer = LatestFrameBuffer()
        for sequence in 1...5 { buffer.publish(makeDecodedFrame(sequence: UInt64(sequence))) }
        #expect(buffer.droppedCount == 4)
        #expect(await buffer.next(after: 0)?.sequence == 5, "older frames are never queued")
        buffer.publish(makeDecodedFrame(sequence: 6))
        #expect(buffer.droppedCount == 4, "a consumed frame being replaced is not a drop")
    }

    @Test func latestDoesNotConsume() {
        let buffer = LatestFrameBuffer()
        buffer.publish(makeDecodedFrame(sequence: 1))
        #expect(buffer.latest?.sequence == 1)
        buffer.publish(makeDecodedFrame(sequence: 2))
        #expect(buffer.droppedCount == 1)
    }

    @Test func cancellationRemovesWaiterAndReturnsNil() async throws {
        let buffer = LatestFrameBuffer()
        let waiter = Task { await buffer.next(after: 0) }
        try await waitUntil("waiter registered") { buffer.waiterCount == 1 }
        waiter.cancel()
        #expect(await waiter.value == nil)
        #expect(buffer.waiterCount == 0)
        buffer.publish(makeDecodedFrame(sequence: 1))
        #expect(buffer.droppedCount == 0)
    }

    @Test func alreadyCancelledTaskReturnsNilWithoutWaiting() async {
        let buffer = LatestFrameBuffer()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await buffer.next(after: 0)
        }
        #expect(await task.value == nil)
        #expect(buffer.waiterCount == 0)
    }

    @Test func closeEndsWaitersAndFutureCalls() async throws {
        let buffer = LatestFrameBuffer()
        buffer.publish(makeDecodedFrame(sequence: 1))
        let waiter = Task { await buffer.next(after: 1) }
        try await waitUntil("waiter registered") { buffer.waiterCount == 1 }
        buffer.close()
        #expect(await waiter.value == nil)
        #expect(await buffer.next(after: 0) == nil)
        buffer.publish(makeDecodedFrame(sequence: 2))
        #expect(buffer.latest == nil, "publishing after close is ignored")
    }

    @Test func everyConsumerGetsTheNewestFrame() async throws {
        let buffer = LatestFrameBuffer()
        let consumers = (0..<4).map { _ in Task { await buffer.next(after: 0) } }
        try await waitUntil("all waiters registered") { buffer.waiterCount == 4 }
        buffer.publish(makeDecodedFrame(sequence: 9))
        for consumer in consumers { #expect(await consumer.value?.sequence == 9) }
        #expect(await buffer.next(after: 0)?.sequence == 9, "late consumers see it too")
        #expect(buffer.droppedCount == 0)
    }

    @Test func consumersWaitingOnDifferentSequences() async throws {
        let buffer = LatestFrameBuffer()
        buffer.publish(makeDecodedFrame(sequence: 5))
        let behind = Task { await buffer.next(after: 2) }
        #expect(await behind.value?.sequence == 5)
        let current = Task { await buffer.next(after: 5) }
        try await waitUntil("waiter registered") { buffer.waiterCount == 1 }
        buffer.publish(makeDecodedFrame(sequence: 6))
        #expect(await current.value?.sequence == 6)
    }

    @Test func clearForgetsTheFrameButKeepsWaiters() async throws {
        let buffer = LatestFrameBuffer()
        buffer.publish(makeDecodedFrame(sequence: 1))
        buffer.clear()
        #expect(buffer.latest == nil)
        let waiter = Task { await buffer.next(after: 1) }
        try await waitUntil("waiter registered") { buffer.waiterCount == 1 }
        buffer.publish(makeDecodedFrame(sequence: 2))
        #expect(await waiter.value?.sequence == 2)
        #expect(buffer.droppedCount == 0)
    }
}
