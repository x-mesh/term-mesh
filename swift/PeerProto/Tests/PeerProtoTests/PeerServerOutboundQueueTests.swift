import XCTest
@testable import PeerProto

private actor OutboundQueueGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitUntilReleased() async {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class OutboundQueueDropRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var total = PeerServerOutboundQueueDrop()

    func record(_ drop: PeerServerOutboundQueueDrop) {
        lock.lock()
        defer { lock.unlock() }
        total.chunks += drop.chunks
        total.bytes += drop.bytes
    }

    func snapshot() -> PeerServerOutboundQueueDrop {
        lock.lock()
        defer { lock.unlock() }
        return total
    }
}

private actor OutboundQueueSendCounter {
    private var count = 0

    func nextSucceeds() -> Bool {
        count += 1
        return count == 1
    }
}

final class PeerServerOutboundQueueTests: XCTestCase {
    private func drain(_ queue: PeerServerOutboundQueue) async -> [PeerServerOutboundQueueEntry] {
        var entries: [PeerServerOutboundQueueEntry] = []
        while let entry = await queue.next() {
            entries.append(entry)
        }
        return entries
    }

    func testFIFOOrderAndOriginalSequencesDrainAfterFinish() async {
        let queue = PeerServerOutboundQueue()
        _ = await queue.enqueue(Data("one".utf8), startSeq: 17)
        _ = await queue.enqueue(Data("two".utf8), startSeq: 20)
        _ = await queue.enqueue(Data("three".utf8), startSeq: 23)
        await queue.finish()

        let entries = await drain(queue)
        XCTAssertEqual(entries.map(\.startSeq), [17, 20, 23])
        XCTAssertEqual(entries.map(\.bytes), [Data("one".utf8), Data("two".utf8), Data("three".utf8)])
    }

    func testOversizePayloadSplitsIntoSequenceContiguousEntries() async {
        let queue = PeerServerOutboundQueue()
        let payload = Data(repeating: 0xA5, count: PeerServerOutboundQueue.maxEntryBytes * 2 + 19)
        _ = await queue.enqueue(payload, startSeq: 91)
        await queue.finish()

        let entries = await drain(queue)
        XCTAssertEqual(entries.map(\.bytes.count), [
            PeerServerOutboundQueue.maxEntryBytes,
            PeerServerOutboundQueue.maxEntryBytes,
            19,
        ])
        XCTAssertEqual(entries.map(\.startSeq), [
            91,
            91 + UInt64(PeerServerOutboundQueue.maxEntryBytes),
            91 + UInt64(PeerServerOutboundQueue.maxEntryBytes * 2),
        ])
        XCTAssertEqual(entries.reduce(into: Data()) { $0.append($1.bytes) }, payload)
    }

    func testOverflowEvictsOldestPendingEntriesAndLeavesAnExactSequenceGap() async {
        let recorder = OutboundQueueDropRecorder()
        let queue = PeerServerOutboundQueue { drop in
            recorder.record(drop)
        }
        let width = 4 * 1024
        let entryCount = PeerServerOutboundQueue.maxPendingItems + 37
        for index in 0..<entryCount {
            _ = await queue.enqueue(Data(repeating: UInt8(index & 0xFF), count: width), startSeq: UInt64(index * width))
        }
        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.pendingItems, PeerServerOutboundQueue.maxPendingItems)
        XCTAssertEqual(snapshot.pendingBytes, PeerServerOutboundQueue.maxPendingItems * width)
        XCTAssertEqual(snapshot.dropped.chunks, 37)
        XCTAssertEqual(snapshot.dropped.bytes, 37 * width)
        let observedDrop = recorder.snapshot()
        XCTAssertEqual(observedDrop, snapshot.dropped)

        await queue.finish()
        let entries = await drain(queue)
        XCTAssertEqual(entries.first?.startSeq, UInt64(snapshot.dropped.bytes))
        XCTAssertEqual(entries.first?.bytes.first, 37)
        XCTAssertEqual(entries.count, PeerServerOutboundQueue.maxPendingItems)
    }

    func testInstallSnapshotDiscardsUnsentPayloadAndKeepsOnlyExactTail() async {
        let queue = PeerServerOutboundQueue()
        _ = await queue.enqueue(Data("obsolete".utf8), startSeq: 7)
        let snapshot = PeerSurfaceResync(ansi: Data("screen".utf8), hostByteSeq: 99)
        let installed = await queue.installSnapshot(snapshot)
        XCTAssertTrue(installed)
        _ = await queue.enqueue(Data("tail".utf8), startSeq: 0)
        await queue.finish()

        guard let first = await queue.next(), case .snapshot(let actual) = first.kind else {
            return XCTFail("expected replacement snapshot")
        }
        XCTAssertEqual(actual, snapshot)
        guard let second = await queue.next(), case .pty(let bytes, let startSeq) = second.kind else {
            return XCTFail("expected post-snapshot tail")
        }
        XCTAssertEqual(bytes, Data("tail".utf8))
        XCTAssertEqual(startSeq, 0)
        let terminalEntry = await queue.next()
        XCTAssertNil(terminalEntry)
    }

    func testProducerContinuesPastItemLimitWhileWriterIsBackpressured() async {
        let queue = PeerServerOutboundQueue()
        let gate = OutboundQueueGate()
        let writer = Task { () -> Int in
            var delivered = 0
            while let _ = await queue.next() {
                delivered += 1
                if delivered == 1 { await gate.waitUntilReleased() }
            }
            return delivered
        }

        let width = 4 * 1024
        let produced = 300
        _ = await queue.enqueue(Data(repeating: 0, count: width), startSeq: 0)
        await gate.waitUntilStarted()
        for index in 1..<produced {
            _ = await queue.enqueue(Data(repeating: UInt8(index & 0xFF), count: width), startSeq: UInt64(index * width))
        }
        let blockedSnapshot = await queue.snapshot()
        XCTAssertEqual(blockedSnapshot.pendingItems, PeerServerOutboundQueue.maxPendingItems)
        XCTAssertEqual(blockedSnapshot.pendingBytes, PeerServerOutboundQueue.maxPendingBytes)
        XCTAssertEqual(blockedSnapshot.dropped.chunks, produced - 1 - PeerServerOutboundQueue.maxPendingItems)

        await queue.finish()
        await gate.release()
        let delivered = await writer.value
        XCTAssertEqual(delivered, PeerServerOutboundQueue.maxPendingItems + 1)
    }

    func testOverflowAdmissionRequiresTransportReconnect() async {
        let queue = PeerServerOutboundQueue()
        let payload = Data(repeating: 0x61, count: PeerServerOutboundQueue.maxEntryBytes)

        for index in 0...PeerServerOutboundQueue.maxPendingItems {
            let admission = await queue.enqueue(
                payload,
                startSeq: UInt64(index * PeerServerOutboundQueue.maxEntryBytes)
            )
            if PeerServerOutboundOverflowPolicy.requiresTransportReconnect(
                for: admission,
                attachmentCount: 1
            ) {
                XCTAssertTrue(PeerServerOutboundOverflowPolicy.requiresTransportReconnect(
                    for: admission,
                    attachmentCount: 1
                ))
                XCTAssertFalse(PeerServerOutboundOverflowPolicy.requiresTransportReconnect(
                    for: admission,
                    attachmentCount: 2
                ))
                return
            }
        }
        XCTFail("bounded outbound queue never reported an overflow")
    }

    func testAbortWakesWriterAndRejectsLaterAdmission() async {
        let queue = PeerServerOutboundQueue()
        let writer = Task { await queue.next() }
        await queue.abort()
        let entry = await writer.value
        XCTAssertNil(entry)
        let admission = await queue.enqueue(Data([1]), startSeq: 0)
        XCTAssertEqual(admission, .aborted)
        await queue.abort()
    }

    func testWriterFailureAbortsPendingEntriesAndTerminates() async {
        let queue = PeerServerOutboundQueue()
        _ = await queue.enqueue(Data(repeating: 0x31, count: 16), startSeq: 0)
        _ = await queue.enqueue(Data(repeating: 0x32, count: 16), startSeq: 16)

        let coalescer = PtyDataCoalescer { _, _ in false }
        let writer = Task { () -> Bool in
            while let entry = await queue.next() {
                guard case .pty(let bytes, let startSeq) = entry.kind,
                      await coalescer.submit(bytes, startSeq: startSeq) else {
                    await queue.abort()
                    return false
                }
            }
            return await coalescer.flushRemaining()
        }

        let succeeded = await writer.value
        XCTAssertFalse(succeeded)
        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.pendingItems, 0)
        XCTAssertEqual(snapshot.pendingBytes, 0)
        let next = await queue.next()
        XCTAssertNil(next)
    }

    func testCoalescerSendsAnIsolatedFirstEntryWithoutWaitingForWindow() async {
        let sent = XCTestExpectation(description: "leading edge sent")
        let coalescer = PtyDataCoalescer(windowMs: 100, maxBytes: 64 * 1024) { payload, seq in
            XCTAssertEqual(payload, Data("echo".utf8))
            XCTAssertEqual(seq, 42)
            sent.fulfill()
            return true
        }
        let accepted = await coalescer.submit(Data("echo".utf8), startSeq: 42)
        XCTAssertTrue(accepted)
        await fulfillment(of: [sent], timeout: 0.02)
        let flushed = await coalescer.flushRemaining()
        XCTAssertTrue(flushed)
    }

    func testCancellingAfterProducerFinishAbortsAndJoinsBlockedWriter() async {
        let queue = PeerServerOutboundQueue()
        let gate = OutboundQueueGate()
        _ = await queue.enqueue(Data([1]), startSeq: 0)

        let pump = Task { () -> Bool in
            await withTaskCancellationHandler(operation: {
                async let writer: Bool = {
                    while let _ = await queue.next() {
                        await gate.waitUntilReleased()
                        if Task.isCancelled { return false }
                    }
                    return true
                }()
                await queue.finish()
                await gate.waitUntilStarted()
                return await writer
            }, onCancel: {
                Task {
                    await queue.abort()
                    await gate.release()
                }
            })
        }

        for _ in 0..<10 { await Task.yield() }
        pump.cancel()
        let completed = await pump.value
        XCTAssertFalse(completed)
        let snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.pendingItems, 0)
        let admission = await queue.enqueue(Data([2]), startSeq: 1)
        XCTAssertEqual(admission, .aborted)
        await queue.abort()
    }

    func testDeferredWindowFlushFailureAbortsIdleQueue() async {
        let queue = PeerServerOutboundQueue()
        let failed = XCTestExpectation(description: "deferred flush failed")
        let sends = OutboundQueueSendCounter()
        let coalescer = PtyDataCoalescer(windowMs: 10, maxBytes: 64 * 1024) { _, _ in
            await sends.nextSucceeds()
        } onFailure: {
            await queue.abort()
            failed.fulfill()
        }

        let firstAccepted = await coalescer.submit(Data([1]), startSeq: 0)
        let secondAccepted = await coalescer.submit(Data([2]), startSeq: 1)
        XCTAssertTrue(firstAccepted)
        XCTAssertTrue(secondAccepted)
        await fulfillment(of: [failed], timeout: 1)
        let terminalEntry = await queue.next()
        let flushed = await coalescer.flushRemaining()
        XCTAssertNil(terminalEntry)
        XCTAssertFalse(flushed)
        await queue.abort()
    }
}
