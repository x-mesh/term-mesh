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

    /// Only the unknown request is posted, so nothing can overwrite a wrong
    /// value: mapping it to any section, the default included, would show up
    /// as an update here.
    func testAnUnknownSectionIsIgnored() async {
        let center = NotificationCenter()
        let requests = SettingsNavigationRequests()
        requests.startListening(center: center)

        var updates: [SettingsSection?] = []
        let subscription = requests.$pendingSection.dropFirst().sink { updates.append($0) }
        post("no-such-section", to: center)

        // The observer runs on the main queue; let it and anything it
        // schedules drain before reading.
        let settled = expectation(description: "main queue drained")
        DispatchQueue.main.async { DispatchQueue.main.async { settled.fulfill() } }
        await fulfillment(of: [settled], timeout: 2)
        subscription.cancel()

        XCTAssertNil(requests.pendingSection)
        XCTAssertTrue(updates.isEmpty, "an unknown section must not publish anything, got \(updates)")
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
