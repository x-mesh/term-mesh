import Darwin
import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class ControlSocketFramingP1Tests: XCTestCase {
    func testAcceptedSocketSuppressesSIGPIPE() throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer {
            if sockets[0] >= 0 { close(sockets[0]) }
            if sockets[1] >= 0 { close(sockets[1]) }
        }

        XCTAssertTrue(TerminalController.suppressSocketSIGPIPE(sockets[0]))
        var enabled: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(
            getsockopt(sockets[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, &length),
            0
        )
        XCTAssertEqual(enabled, 1)
    }

    func testSplitUTF8ScalarAt4095ByteReadBoundaryIsHandledExactlyOnce() {
        let request = String(repeating: "a", count: 4_094) + "한"
        let wire = Data((request + "\n").utf8)
        XCTAssertEqual(wire.count, 4_098)

        var pending = Data()
        var handled: [String] = []
        handled += TerminalController.appendControlSocketChunk(
            wire.subdata(in: 0..<4_095),
            to: &pending
        ) ?? []
        handled += TerminalController.appendControlSocketChunk(
            wire.subdata(in: 4_095..<wire.count),
            to: &pending
        ) ?? []

        XCTAssertEqual(handled, [request])
        XCTAssertTrue(pending.isEmpty)
    }

    func testMultipleFramesInOneChunkAreHandledSeparately() {
        var pending = Data()
        let frames = TerminalController.appendControlSocketChunk(
            Data("first\n둘째\nthird\n".utf8),
            to: &pending
        )

        XCTAssertEqual(frames, ["first", "둘째", "third"])
        XCTAssertTrue(pending.isEmpty)
    }

    func testFrameExactlyAtPendingLimitIsAcceptedWhenNewlineArrives() {
        var pending = Data(repeating: 0x61, count: 8)

        let frames = TerminalController.appendControlSocketChunk(
            Data([0x0A]),
            to: &pending,
            maxPendingBytes: 8
        )

        XCTAssertEqual(frames, ["aaaaaaaa"])
        XCTAssertTrue(pending.isEmpty)
    }

    func testFrameOneByteOverPendingLimitIsRejectedEvenWithNewline() {
        var pending = Data(repeating: 0x61, count: 8)

        let frames = TerminalController.appendControlSocketChunk(
            Data([0x61, 0x0A]),
            to: &pending,
            maxPendingBytes: 8
        )

        XCTAssertNil(frames)
    }

    func testCompletedFrameIsRemovedBeforeUnterminatedSuffixLimitIsChecked() {
        var pending = Data(repeating: 0x61, count: 8)

        let frames = TerminalController.appendControlSocketChunk(
            Data([0x0A, 0x62]),
            to: &pending,
            maxPendingBytes: 8
        )

        XCTAssertEqual(frames, ["aaaaaaaa"])
        XCTAssertEqual(pending, Data([0x62]))
    }

    func testReadRetriesEINTRWithoutDiscardingTheChunk() {
        var buffer = [UInt8](repeating: 0, count: 16)
        var callCount = 0
        let expected = Data("partial\n".utf8)

        let bytesRead = TerminalController.readControlSocketBytes(
            42,
            into: &buffer
        ) { socket, pointer, count in
            callCount += 1
            XCTAssertEqual(socket, 42)
            if callCount == 1 {
                errno = EINTR
                return -1
            }
            XCTAssertGreaterThanOrEqual(count, expected.count)
            expected.copyBytes(to: pointer!.assumingMemoryBound(to: UInt8.self), count: expected.count)
            return expected.count
        }

        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(bytesRead, expected.count)
        XCTAssertEqual(Data(buffer.prefix(bytesRead)), expected)

    /// Several complete frames in one read may exceed the limit in total.
    ///
    /// The limit exists to stop a writer that never sends a newline, not to
    /// cap how much a well-behaved client may batch into one syscall. The two
    /// were conflated while the bound was applied to the accumulated buffer,
    /// and valid work was dropped for arriving together.
    func testBatchedFramesExceedingTheLimitInTotalAreStillDelivered() {
        var pending = Data()
        let batch = (0..<8).map { String(repeating: "\($0)", count: 32) }
        let frames = TerminalController.appendControlSocketChunk(
            Data((batch.joined(separator: "\n") + "\n").utf8),
            to: &pending,
            maxPendingBytes: 64
        )

        XCTAssertEqual(frames, batch)
        XCTAssertTrue(pending.isEmpty)
    }

    /// The flood the limit is actually for: no newline, ever.
    func testUnterminatedRemainderPastTheLimitPoisonsTheConnection() {
        var pending = Data()
        XCTAssertNil(
            TerminalController.appendControlSocketChunk(
                Data(String(repeating: "x", count: 65).utf8),
                to: &pending,
                maxPendingBytes: 64
            )
        )
    }
    }

    func testWriteAllRetriesEINTRAndCompletesAfterShortWrite() {
        let expected = Data("{\"ok\":true}\n".utf8)
        var recorded = Data()
        var callCount = 0

        let succeeded = TerminalController.writeAllSocketBytes(expected) { pointer, count in
            callCount += 1
            if callCount == 1 {
                errno = EINTR
                return -1
            }

            let accepted = callCount == 2 ? min(4, count) : count
            recorded.append(
                pointer.assumingMemoryBound(to: UInt8.self),
                count: accepted
            )
            return accepted
        }

        XCTAssertTrue(succeeded)
        XCTAssertEqual(callCount, 3)
        XCTAssertEqual(recorded, expected)
    }
}
