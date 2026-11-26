import XCTest
import AppKit

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class TerminalAgentIconsTests: XCTestCase {
    func testDaemonAnswerMapsPanelIDsToKnownCLIs() {
        let claudePanel = UUID()
        let codexPanel = UUID()
        let agents = TerminalAgentIconMonitor.agents(from: [
            claudePanel.uuidString: "claude",
            codexPanel.uuidString: "codex",
            UUID().uuidString: "gemini",
            "not-a-uuid": "claude",
        ])

        XCTAssertEqual(agents, [claudePanel: .claude, codexPanel: .codex])
    }

    func testBothLogosLoadAsTabIcons() throws {
        for cli in [TerminalAgentCLI.claude, .codex] {
            let data = try XCTUnwrap(cli.iconPNGData, "\(cli) logo asset is missing")
            let image = try XCTUnwrap(NSImage(data: data), "\(cli) icon is not decodable")
            XCTAssertEqual(image.size.width, image.size.height, "\(cli) icon must be square")
        }
    }
}
