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
