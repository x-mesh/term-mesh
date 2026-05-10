import XCTest
@testable import PeerProto

final class PeerIdentityTests: XCTestCase {
    func testLoadOrCreateFirstCallCreates() throws {
        let service = testServiceName()
        defer { try? PeerIdentity.deleteStoredIdentity(service: service, account: PeerIdentity.account) }

        let id = try PeerIdentity.loadOrCreate(service: service, account: PeerIdentity.account)

        XCTAssertEqual(id.count, PeerIdentity.byteCount)
        XCTAssertNotEqual(id, Data(count: PeerIdentity.byteCount))
    }

    func testLoadOrCreateIdempotent() throws {
        let service = testServiceName()
        defer { try? PeerIdentity.deleteStoredIdentity(service: service, account: PeerIdentity.account) }

        let first = try PeerIdentity.loadOrCreate(service: service, account: PeerIdentity.account)
        let second = try PeerIdentity.loadOrCreate(service: service, account: PeerIdentity.account)

        XCTAssertEqual(first, second)
    }

    func testRegenerateReplaces() throws {
        let service = testServiceName()
        defer { try? PeerIdentity.deleteStoredIdentity(service: service, account: PeerIdentity.account) }

        let first = try PeerIdentity.loadOrCreate(service: service, account: PeerIdentity.account)
        let regenerated = try PeerIdentity.regenerate(service: service, account: PeerIdentity.account)
        let loaded = try PeerIdentity.loadOrCreate(service: service, account: PeerIdentity.account)

        XCTAssertEqual(regenerated.count, PeerIdentity.byteCount)
        XCTAssertNotEqual(first, regenerated)
        XCTAssertEqual(regenerated, loaded)
    }

    func testPeerSessionOptionsDefaultUsesStablePeerID() {
        let options = PeerSessionOptions()

        XCTAssertEqual(options.peerID.count, PeerIdentity.byteCount)
        XCTAssertNotEqual(options.peerID, Data(count: PeerIdentity.byteCount))
    }

    private func testServiceName() -> String {
        "com.termmesh.peer-identity.tests.\(UUID().uuidString)"
    }
}
