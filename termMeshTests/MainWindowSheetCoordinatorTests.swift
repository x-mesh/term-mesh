import XCTest
import Foundation

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

@MainActor
final class MainWindowSheetCoordinatorTests: XCTestCase {
    func testSameSheetKindDoesNotRebuildInProgressForm() {
        let coordinator = MainWindowSheetCoordinator()
        coordinator.present(.teamCreation(mode: "new"))

        coordinator.present(.teamCreation(mode: "resume"))

        XCTAssertEqual(coordinator.activeSheet, .teamCreation(mode: "new"))
    }

    func testDifferentSheetKindUsesCleanDismissThenPresentation() async {
        let coordinator = MainWindowSheetCoordinator()
        coordinator.present(.teamCreation(mode: "new"))

        coordinator.present(.projectCreation)
        XCTAssertNil(coordinator.activeSheet)

        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        XCTAssertEqual(coordinator.activeSheet, .projectCreation)
    }

    func testNewerRequestSupersedesQueuedReplacement() async {
        let coordinator = MainWindowSheetCoordinator()
        coordinator.present(.teamCreation(mode: "new"))
        coordinator.present(.projectCreation)

        coordinator.present(.watchConfig(teamName: "latest", workingDirectory: "/tmp"))
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        XCTAssertEqual(
            coordinator.activeSheet,
            .watchConfig(teamName: "latest", workingDirectory: "/tmp")
        )
    }

    func testDismissCancelsQueuedReplacement() async {
        let coordinator = MainWindowSheetCoordinator()
        coordinator.present(.teamCreation(mode: "new"))
        coordinator.present(.projectCreation)

        coordinator.dismiss()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        XCTAssertNil(coordinator.activeSheet)
    }

    func testExplicitWindowIDWinsWithoutConsultingGlobalWindowState() {
        let windowID = UUID()
        let notification = Notification(
            name: .projectCreationRequested,
            object: nil,
            userInfo: [
                MainWindowPresentationRouter.windowIDUserInfoKey: windowID.uuidString,
            ]
        )

        XCTAssertEqual(
            MainWindowPresentationRouter.targetWindowID(from: notification),
            windowID
        )
    }
}
