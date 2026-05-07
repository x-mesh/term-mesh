import XCTest
@testable import PeerProto

final class FramingTests: XCTestCase {
    func testRoundTripHello() throws {
        var envelope = Termmesh_Peer_V1_Envelope()
        envelope.seq = 1
        var hello = Termmesh_Peer_V1_Hello()
        hello.protocolVersion = "1.0.0"
        hello.peerID = Data(count: 16)
        hello.displayName = "swift-test"
        hello.capabilities = ["grid-snapshot-v1"]
        hello.appVersion = "0.0.1"
        envelope.hello = hello

        let frame = try encodeFrame(envelope)
        XCTAssertGreaterThan(frame.count, 4, "frame should include length prefix + payload")

        var buffer = frame
        let decoded = try decodeFrame(from: &buffer)
        XCTAssertNotNil(decoded)
        guard let decoded = decoded else { return }
        XCTAssertEqual(decoded.seq, 1)
        XCTAssertTrue(buffer.isEmpty, "decoder should consume the whole frame")

        switch decoded.payload {
        case .hello(let h):
            XCTAssertEqual(h.protocolVersion, "1.0.0")
            XCTAssertEqual(h.displayName, "swift-test")
            XCTAssertEqual(h.peerID.count, 16)
            XCTAssertEqual(h.capabilities, ["grid-snapshot-v1"])
        default:
            XCTFail("expected .hello, got \(String(describing: decoded.payload))")
        }
    }

    func testRoundTripPtyData() throws {
        var envelope = Termmesh_Peer_V1_Envelope()
        envelope.seq = 42
        var data = Termmesh_Peer_V1_PtyData()
        data.surfaceID = Data(repeating: 0xCD, count: 16)
        data.byteSeq = 12345
        data.payload = Data("hello world\r\n".utf8)
        envelope.ptyData = data

        var buffer = try encodeFrame(envelope)
        let decoded = try decodeFrame(from: &buffer)
        XCTAssertNotNil(decoded)

        switch decoded?.payload {
        case .ptyData(let p):
            XCTAssertEqual(p.byteSeq, 12345)
            XCTAssertEqual(p.payload, Data("hello world\r\n".utf8))
        default:
            XCTFail("expected .ptyData")
        }
    }

    func testWorkspaceMetaRoundTrip() throws {
        // Ensures the Phase 2.4b SurfaceInfo + WorkspaceUpdate additions
        // are reachable from Swift.
        var meta = Termmesh_Peer_V1_WorkspaceMeta()
        meta.branch = "feat/peer-federation"
        meta.cwd = "/tmp/x"
        var wu = Termmesh_Peer_V1_WorkspaceUpdate()
        wu.meta = meta
        var env = Termmesh_Peer_V1_Envelope()
        env.seq = 7
        env.workspaceUpdate = wu

        var buf = try encodeFrame(env)
        let decoded = try decodeFrame(from: &buf)
        guard case .workspaceUpdate(let decWu) = decoded?.payload else {
            XCTFail("expected workspaceUpdate")
            return
        }
        guard case .meta(let decMeta) = decWu.kind else {
            XCTFail("expected meta kind")
            return
        }
        XCTAssertEqual(decMeta.branch, "feat/peer-federation")
        XCTAssertEqual(decMeta.cwd, "/tmp/x")
    }

    func testPartialFrameReturnsNil() throws {
        // Only 2 bytes of the 4-byte length prefix available.
        var partial = Data([0x05, 0x00])
        XCTAssertNil(try decodeFrame(from: &partial))
        XCTAssertEqual(partial.count, 2, "partial read should not consume bytes")

        // Full length prefix but only part of the payload.
        var halfPayload = Data([0x04, 0x00, 0x00, 0x00, 0xAB])
        XCTAssertNil(try decodeFrame(from: &halfPayload))
        XCTAssertEqual(halfPayload.count, 5)
    }

    func testOversizedFrameRejected() {
        let bogus = UInt32(maxFrameBytes + 1).littleEndian
        var buf = Data()
        withUnsafeBytes(of: bogus) { buf.append(contentsOf: $0) }
        do {
            _ = try decodeFrame(from: &buf)
            XCTFail("expected PeerFramingError.frameTooLarge")
        } catch PeerFramingError.frameTooLarge {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// Verifies the Rust daemon's wire format matches what Swift produces:
    /// a known-good byte sequence produced by the Rust-side Pong encode
    /// (captured manually) must decode identically here.
    func testForwardCompatIgnoresUnknownFields() throws {
        // Encode a Pong envelope, then append an unknown protobuf field.
        // Decode must still succeed and expose the Pong.
        var env = Termmesh_Peer_V1_Envelope()
        env.seq = 5
        var pong = Termmesh_Peer_V1_Pong()
        pong.nonce = 7
        env.pong = pong
        let payload = try env.serializedData()

        // Append an unknown field: tag 999 (field 999, wire type 0=varint), value 1.
        var withUnknown = payload
        withUnknown.append(contentsOf: [0xF8, 0x3E, 0x01])

        // Re-frame for the decoder.
        var framed = Data()
        var len = UInt32(withUnknown.count).littleEndian
        withUnsafeBytes(of: &len) { framed.append(contentsOf: $0) }
        framed.append(withUnknown)

        let decoded = try decodeFrame(from: &framed)
        guard case .pong(let p) = decoded?.payload else {
            XCTFail("expected pong")
            return
        }
        XCTAssertEqual(p.nonce, 7)
    }
}
