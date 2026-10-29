import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class ProgramStatusReducerTests: XCTestCase {
    private let surfaceA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let surfaceB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    private func status(
        _ state: ProgramStatusState,
        kind: ProgramStatusKind? = nil,
        app: String? = "claude-code"
    ) -> SurfaceProgramStatus {
        SurfaceProgramStatus(state: state, kind: kind, app: app)
    }

    func testBlockedReportKeepsKindAndApp() {
        let report = ProgramStatusReducer.report(
            event: .report, state: .blocked, kind: .permission, app: "claude-code"
        )
        XCTAssertEqual(report, .set(status(.blocked, kind: .permission)))
    }

    func testKindIsDroppedOutsideBlocked() {
        let report = ProgramStatusReducer.report(
            event: .report, state: .working, kind: .question, app: "codex"
        )
        XCTAssertEqual(report, .set(status(.working, app: "codex")))
    }

    func testEmptyAppBecomesNil() {
        let report = ProgramStatusReducer.report(event: .report, state: .idle, kind: nil, app: "  ")
        XCTAssertEqual(report, .set(status(.idle, app: nil)))
    }

    func testClearStateClears() {
        XCTAssertEqual(
            ProgramStatusReducer.report(event: .report, state: .clear, kind: nil, app: "claude-code"),
            .clear
        )
    }

    func testPromptStartIsIgnored() {
        // The shell marks a prompt right after `printf` returns, so treating it
        // as clear would erase a status the instant it was reported.
        XCTAssertNil(ProgramStatusReducer.report(event: .promptStart, state: .idle, kind: nil, app: nil))
    }

    func testRepeatedReportIsNoChange() {
        let current = [surfaceA: status(.working)]
        XCTAssertNil(ProgramStatusReducer.applying(.set(status(.working)), surfaceId: surfaceA, to: current))
    }

    func testChangedReportReplacesOnlyThatSurface() {
        let current = [surfaceA: status(.working), surfaceB: status(.idle, app: "codex")]
        let next = ProgramStatusReducer.applying(
            .set(status(.blocked, kind: .permission)), surfaceId: surfaceA, to: current
        )
        XCTAssertEqual(next?[surfaceA], status(.blocked, kind: .permission))
        XCTAssertEqual(next?[surfaceB], status(.idle, app: "codex"))
    }

    func testClearIsIdempotent() {
        let current = [surfaceA: status(.done), surfaceB: status(.working)]
        let first = ProgramStatusReducer.applying(.clear, surfaceId: surfaceA, to: current)
        XCTAssertEqual(first, [surfaceB: status(.working)])
        // Claude sends `state=clear` three times on exit.
        XCTAssertNil(ProgramStatusReducer.applying(.clear, surfaceId: surfaceA, to: first!))
        XCTAssertNil(ProgramStatusReducer.applying(.clear, surfaceId: surfaceA, to: first!))
    }

    func testDominantFollowsPriorityOrder() {
        let order: [ProgramStatusState] = [.idle, .done, .working, .error, .blocked]
        for (lowerIndex, lower) in order.enumerated() {
            for higher in order[(lowerIndex + 1)...] {
                let statuses = [surfaceA: status(lower), surfaceB: status(higher)]
                XCTAssertEqual(
                    ProgramStatusReducer.dominant(statuses, liveSurfaceIds: [surfaceA, surfaceB])?.state,
                    higher,
                    "\(higher) must outrank \(lower)"
                )
            }
        }
    }

    func testDominantPrefersPermissionAmongBlocked() {
        let statuses = [
            surfaceA: status(.blocked, kind: .question),
            surfaceB: status(.blocked, kind: .permission),
        ]
        XCTAssertEqual(
            ProgramStatusReducer.dominant(statuses, liveSurfaceIds: [surfaceA, surfaceB])?.kind,
            .permission
        )
    }

    func testDominantIgnoresClosedSurfaces() {
        let statuses = [surfaceA: status(.blocked, kind: .permission), surfaceB: status(.idle)]
        XCTAssertEqual(
            ProgramStatusReducer.dominant(statuses, liveSurfaceIds: [surfaceB])?.state,
            .idle
        )
        XCTAssertNil(ProgramStatusReducer.dominant(statuses, liveSurfaceIds: []))
    }

    func testDominantIsStableForEqualStatuses() {
        let statuses = [surfaceA: status(.working), surfaceB: status(.working, app: "codex")]
        let first = ProgramStatusReducer.dominant(statuses, liveSurfaceIds: [surfaceA, surfaceB])
        for _ in 0..<10 {
            XCTAssertEqual(
                ProgramStatusReducer.dominant(statuses, liveSurfaceIds: [surfaceA, surfaceB]),
                first
            )
        }
    }
}
