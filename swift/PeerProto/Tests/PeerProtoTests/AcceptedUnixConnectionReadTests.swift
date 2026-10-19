import XCTest
@testable import PeerProto

final class AcceptedUnixConnectionReadTests: XCTestCase {
    private func waitForRead(_ connection: AcceptedUnixConnection) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !(await connection.hasPendingRead) {
            guard Date() < deadline else {
                XCTFail("reader never suspended")
                throw CancellationError()
            }
            await Task.yield()
        }
    }

    func testCloseResumesBlockedReadAndReleasesConnection() async throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { Darwin.close(fds[1]) }
        var connection: AcceptedUnixConnection? = AcceptedUnixConnection(fd: fds[0])
        weak var retainedConnection = connection
        let ended = expectation(description: "read ended after server close")
        var reader: Task<Void, Never>? = Task { [connection = connection!] in
            defer { ended.fulfill() }
            do {
                let data = try await connection.read()
                XCTAssertTrue(data.isEmpty)
            } catch {
                XCTFail("unexpected read error: \(error)")
            }
        }
        try await waitForRead(connection!)
        await connection!.close()
        connection = nil
        await fulfillment(of: [ended], timeout: 2)
        reader = nil
        let deadline = Date().addingTimeInterval(2)
        while retainedConnection != nil && Date() < deadline { await Task.yield() }
        XCTAssertNil(retainedConnection)
    }

    func testCancellingBlockedReadResumesWithoutClosingPeer() async throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { Darwin.close(fds[1]) }
        let connection = AcceptedUnixConnection(fd: fds[0])
        let ended = expectation(description: "cancelled read ended")
        let reader = Task {
            defer { ended.fulfill() }
            do {
                _ = try await connection.read()
                XCTFail("cancelled read succeeded")
            } catch is CancellationError {
            } catch {
                XCTFail("unexpected read error: \(error)")
            }
        }
        try await waitForRead(connection)
        reader.cancel()
        await fulfillment(of: [ended], timeout: 2)
        await connection.close()
    }

    func testWriteTimeoutAlsoResumesBlockedRead() async throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { Darwin.close(fds[1]) }
        var bufferSize: Int32 = 4096
        XCTAssertEqual(setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &bufferSize,
                                 socklen_t(MemoryLayout<Int32>.size)), 0)
        let connection = AcceptedUnixConnection(fd: fds[0], writeTimeoutSeconds: 0.05)
        let ended = expectation(description: "write timeout released read")
        let reader = Task {
            defer { ended.fulfill() }
            _ = try? await connection.read()
        }
        try await waitForRead(connection)
        do {
            try await connection.write(Data(repeating: 0x41, count: 4 * 1024 * 1024))
            XCTFail("write did not time out")
        } catch PeerServerError.writeTimedOut {
        }
        await fulfillment(of: [ended], timeout: 2)
        await connection.close()
        reader.cancel()
    }
}
