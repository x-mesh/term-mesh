import XCTest
import Darwin
@testable import PeerProto

final class UnixSocketTransportWatchdogTests: XCTestCase {
    private final class WeakBox: @unchecked Sendable {
        weak var object: NSObject?
    }

    private static func makeListener(_ path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let max = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { t in
            t.withMemoryRebound(to: CChar.self, capacity: max) { c in
                for (i, b) in Array(path.utf8).enumerated() { c[i] = CChar(bitPattern: b) }
            }
        }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0, Darwin.listen(fd, 4) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return fd
    }

    func testTransportQueueDrainsAutoreleasedObjectsAfterEachWorkItem() {
        let queue = UnixSocketTransport.makeTransportQueue()
        let box = WeakBox()
        let checked = expectation(description: "second work item ran")
        var releasedBeforeNextItem = false
        queue.async {
            let object = NSObject()
            box.object = object
            _ = Unmanaged.passRetained(object).autorelease()
            // Queued before this item returns, so both run in one drain of the queue.
            queue.async {
                releasedBeforeNextItem = box.object == nil
                checked.fulfill()
            }
        }
        wait(for: [checked], timeout: 5)
        XCTAssertTrue(releasedBeforeNextItem)
    }

    func testStalledWriteStillTimesOutAndClosesTheTransport() async throws {
        let path = "/tmp/tm-peer-wd-stall-\(UUID().uuidString.prefix(8)).sock"
        let listenerFd = try Self.makeListener(path)
        defer { Darwin.close(listenerFd); unlink(path) }
        let accepted = Task.detached { () -> Int32 in Darwin.accept(listenerFd, nil, nil) }
        let transport = try await UnixSocketTransport.connect(
            socketPath: path, timeoutSeconds: 2, writeTimeoutSeconds: 0.4
        )
        let started = Date()
        do {
            try await transport.write(Data(repeating: 0x41, count: 16 * 1024 * 1024))
            XCTFail("a write the peer never reads must time out")
        } catch let error as UnixSocketTransportError {
            guard case .underlying(let description) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(description.contains("write timed out"), description)
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.35)
        XCTAssertLessThan(elapsed, 5)
        try await Task.sleep(nanoseconds: 200_000_000)
        do {
            try await transport.write(Data([1]))
            XCTFail("the transport must be closed after a write timeout")
        } catch let error as UnixSocketTransportError {
            guard case .closed = error else { return XCTFail("expected closed, got \(error)") }
        }
        let fd = await accepted.value
        if fd >= 0 { Darwin.close(fd) }
        let pending = await transport.pendingWriteTimeoutsForTesting
        XCTAssertEqual(pending, 0)
    }

    func testManyFastWritesLeaveNoPendingTimeouts() async throws {
        let path = "/tmp/tm-peer-wd-fast-\(UUID().uuidString.prefix(8)).sock"
        let listenerFd = try Self.makeListener(path)
        defer { Darwin.close(listenerFd); unlink(path) }
        let drain = Task.detached {
            let fd = Darwin.accept(listenerFd, nil, nil)
            guard fd >= 0 else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            while Darwin.read(fd, &buf, buf.count) > 0 {}
            Darwin.close(fd)
        }
        defer { drain.cancel() }
        let transport = try await UnixSocketTransport.connect(socketPath: path, timeoutSeconds: 2)
        let payload = Data(repeating: 0x61, count: 40)
        for _ in 0..<2000 { try await transport.write(payload) }
        let pending = await transport.pendingWriteTimeoutsForTesting
        XCTAssertEqual(pending, 0)
        await transport.close()
    }
}
