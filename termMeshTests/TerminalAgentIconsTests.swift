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
        let geminiPanel = UUID()
        let neovimPanel = UUID()
        let agents = TerminalAgentIconMonitor.agents(from: [
            claudePanel.uuidString: "claude",
            codexPanel.uuidString: "codex",
            geminiPanel.uuidString: "gemini",
            neovimPanel.uuidString: "neovim",
            UUID().uuidString: "unknown",
            "not-a-uuid": "claude",
        ])

        XCTAssertEqual(agents, [
            claudePanel: .claude, codexPanel: .codex,
            geminiPanel: .gemini, neovimPanel: .neovim,
        ])
    }

    func testBothLogosLoadAsTabIcons() throws {
        for cli in [TerminalAgentCLI.claude, .codex] {
            let data = try XCTUnwrap(cli.iconPNGData, "\(cli) logo asset is missing")
            let image = try XCTUnwrap(NSImage(data: data), "\(cli) icon is not decodable")
            XCTAssertEqual(image.size.width, image.size.height, "\(cli) icon must be square")
        }
    }

    func testCategoryIconsExistWithoutAddingLauncherAssets() {
        let apps = TerminalAgentCLI.allCases.filter { $0.iconPNGData == nil }
        XCTAssertFalse(apps.isEmpty)
        for app in apps {
            let name = try? XCTUnwrap(app.symbolName)
            XCTAssertNotNil(name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }, "missing symbol for \(app)")
        }
    }

    func testPollingCadenceBoundsIconTransitionLatency() {
        XCTAssertLessThanOrEqual(TerminalAgentIconMonitor.interval * 2, 0.5)
    }

    func testEverySupportedAppUsesExactlyOneIconChannel() {
        for app in TerminalAgentCLI.allCases {
            let hasLogo = app.iconPNGData != nil
            let hasSymbol = app.symbolName != nil
            XCTAssertNotEqual(hasLogo, hasSymbol, "\(app) must use one icon channel")
        }
    }
}
