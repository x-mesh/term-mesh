import Combine
import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// A navigation request posted before the settings view subscribes must still
/// reach it: on the first open the view is installed after the request.
@MainActor
final class SettingsNavigationRequestsTests: XCTestCase {

    private func post(_ raw: String, to center: NotificationCenter) {
        center.post(
            name: .settingsNavigateToSection,
            object: nil,
            userInfo: [SettingsNavigationUserInfoKey.section: raw]
        )
    }

    func testARequestPostedBeforeSubscribingIsDelivered() async {
        let center = NotificationCenter()
        let requests = SettingsNavigationRequests()
        requests.startListening(center: center)

        post(SettingsSection.worktrees.rawValue, to: center)

        let delivered = expectation(description: "late subscriber receives the request")
        var received: SettingsSection?
        let subscription = requests.$pendingSection.compactMap { $0 }.sink { section in
            received = section
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 2)
        subscription.cancel()
        XCTAssertEqual(received, .worktrees)
    }

    func testAnUnknownSectionIsIgnored() async {
        let center = NotificationCenter()
        let requests = SettingsNavigationRequests()
        requests.startListening(center: center)

        post("no-such-section", to: center)
        post(SettingsSection.agentTeams.rawValue, to: center)

        let delivered = expectation(description: "the valid request arrives")
        let subscription = requests.$pendingSection.compactMap { $0 }.sink { _ in
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 2)
        subscription.cancel()
        XCTAssertEqual(requests.pendingSection, .agentTeams)
    }

    func testListeningTwiceRegistersOnce() async {
        let center = NotificationCenter()
        let requests = SettingsNavigationRequests()
        requests.startListening(center: center)
        requests.startListening(center: center)

        var updates = 0
        let subscription = requests.$pendingSection.dropFirst().sink { _ in updates += 1 }
        post(SettingsSection.worktrees.rawValue, to: center)
        let settled = expectation(description: "main queue drained")
        DispatchQueue.main.async { DispatchQueue.main.async { settled.fulfill() } }
        await fulfillment(of: [settled], timeout: 2)
        subscription.cancel()
        XCTAssertEqual(updates, 1)
    }
}
