import XCTest
@testable import PeerProto

/// Concurrent writers must never interleave inside a frame.
///
/// `AcceptedUnixConnection.write` suspends when the socket buffer is full,
/// and actor isolation does not hold across a suspension. Before the write
/// slot existed, a second writer could land its bytes in the middle of a
/// half-written frame; the reader then took payload bytes for a length
/// prefix and the whole session died with `frameTooLarge`. That needs a
/// full socket buffer to reproduce, which is why it only ever showed up
/// under a heavy PTY output flood.
final class AcceptedUnixConnectionWriteTests: XCTestCase {
    /// Each frame is `[LE UInt32 length][length bytes, all equal to a
    /// per-writer marker]`, so any interleaving shows up as a frame whose
    /// payload is not uniform — or as a length that decodes to nonsense.
    private func makeFrame(marker: UInt8, length: Int) -> Data {
        var frame = Data()
        withUnsafeBytes(of: UInt32(length).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(Data(repeating: marker, count: length))
        return frame
    }

    func testConcurrentWritesDoNotInterleaveWhenTheSocketBufferFills() async throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let writeFD = fds[0]
        let readFD = fds[1]

        // Small buffers so the writer hits EAGAIN almost immediately —
        // that is the suspension the bug rode in on.
        var bufSize: Int32 = 4096
        _ = setsockopt(writeFD, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(readFD, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))

        let connection = AcceptedUnixConnection(fd: writeFD)

        let writerCount = 6
        let frameLength = 24 * 1024   // several times the socket buffer
        let markers: [UInt8] = (0..<writerCount).map { UInt8(0xA0 + $0) }

        // Reader drains on its own thread; a slow drain is what keeps the
        // buffer full and the writers suspended.
        let expected = writerCount * (4 + frameLength)
        let received = UnsafeMutablePointer<Data>.allocate(capacity: 1)
        received.initialize(to: Data())
        let readerDone = expectation(description: "reader drained the stream")
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 8192)
            while received.pointee.count < expected {
                let n = buffer.withUnsafeMutableBufferPointer { bp in
                    Darwin.read(readFD, bp.baseAddress, bp.count)
                }
                if n <= 0 { break }
                received.pointee.append(contentsOf: buffer.prefix(n))
                usleep(200)
            }
            readerDone.fulfill()
        }

        await withTaskGroup(of: Void.self) { group in
            for marker in markers {
                group.addTask {
                    let frame = self.makeFrame(marker: marker, length: frameLength)
                    try? await connection.write(frame)
                }
            }
        }

        await fulfillment(of: [readerDone], timeout: 30)
        let stream = received.pointee
        received.deinitialize(count: 1)
        received.deallocate()
        await connection.close()
        Darwin.close(readFD)

        XCTAssertEqual(stream.count, expected, "stream is short — a frame was lost")

        // Walk the stream as the client's framing layer would.
        var offset = 0
        var seenMarkers: [UInt8] = []
        while offset + 4 <= stream.count {
            let length = stream.withUnsafeBytes { raw -> UInt32 in
                var value: UInt32 = 0
                withUnsafeMutableBytes(of: &value) { dst in
                    dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + 4)]))
                }
                return UInt32(littleEndian: value)
            }
            XCTAssertEqual(
                Int(length), frameLength,
                "length prefix at offset \(offset) decoded to \(length) — the wire desynced"
            )
            guard Int(length) == frameLength else { return }
            let payload = stream[(offset + 4)..<(offset + 4 + frameLength)]
            guard let marker = payload.first else { return XCTFail("empty payload") }
            XCTAssertTrue(
                payload.allSatisfy { $0 == marker },
                "frame at offset \(offset) mixes bytes from more than one writer"
            )
            seenMarkers.append(marker)
            offset += 4 + frameLength
        }

        XCTAssertEqual(offset, stream.count, "trailing bytes left over — frames did not tile the stream")
        XCTAssertEqual(Set(seenMarkers), Set(markers), "every writer's frame must arrive exactly once")
        XCTAssertEqual(seenMarkers.count, writerCount)
    }

    func testStalledReaderTimesOutInsteadOfRetainingTheFrameForever() async throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let writeFD = fds[0]
        let readFD = fds[1]
        defer { Darwin.close(readFD) }

        var bufSize: Int32 = 4096
        _ = setsockopt(writeFD, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(readFD, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        let connection = AcceptedUnixConnection(
            fd: writeFD, maxPendingWrites: 2, writeTimeoutSeconds: 0.05
        )

        do {
            try await connection.write(Data(repeating: 0xA5, count: 4 * 1024 * 1024))
            XCTFail("a peer that never drains must not hold a frame forever")
        } catch PeerServerError.writeTimedOut {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        await connection.close()
    }

    func testPendingWriterCountIsBoundedUnderBackpressure() async throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let writeFD = fds[0]
        let readFD = fds[1]
        defer { Darwin.close(readFD) }

        var bufSize: Int32 = 4096
        _ = setsockopt(writeFD, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(readFD, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        let connection = AcceptedUnixConnection(
            fd: writeFD, maxPendingWrites: 1, writeTimeoutSeconds: 0.2
        )
        let frame = Data(repeating: 0x5A, count: 4 * 1024 * 1024)
        let first = Task { try await connection.write(frame) }
        try await Task.sleep(nanoseconds: 10_000_000)
        let queued = Task { try await connection.write(frame) }
        try await Task.sleep(nanoseconds: 10_000_000)

        do {
            try await connection.write(frame)
            XCTFail("a third retained frame must exceed the one-waiter bound")
        } catch PeerServerError.writeBackpressureExceeded {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        await connection.close()
        _ = try? await first.value
        _ = try? await queued.value
    }

    func testCloseDuringActiveWriteReleasesEveryQueuedWriter() async throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let writeFD = fds[0]
        let readFD = fds[1]
        defer { Darwin.close(readFD) }

        var bufSize: Int32 = 4096
        _ = setsockopt(writeFD, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(readFD, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        let connection = AcceptedUnixConnection(
            fd: writeFD, maxPendingWrites: 4, writeTimeoutSeconds: 5
        )
        let frame = Data(repeating: 0x7B, count: 4 * 1024 * 1024)
        let writers = (0..<5).map { _ in
            Task { try await connection.write(frame) }
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        await connection.close()
        for writer in writers {
            _ = try? await writer.value
        }
    }
}
