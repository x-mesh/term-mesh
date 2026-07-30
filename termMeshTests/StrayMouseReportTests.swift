import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Recognising a pane whose mouse reports are being run as shell commands.
///
/// The positive case is transcribed from a real pane on jw-server after its
/// agent was killed without being allowed to reset the terminal.
final class StrayMouseReportTests: XCTestCase {
    func testRecognisesAKilledAgentsPane() {
        let pane = """
        root@jw-server:/app/tm-projects/e2e-demo-executor# 35;47;44M35;51;50M
        35: command not found
        47: command not found
        44M35: command not found
        51: command not found
        50M: command not found
        root@jw-server:/app/tm-projects/e2e-demo-executor#
        """
        XCTAssertTrue(AutoReplyPoller.showsStrayMouseReports(inPaneText: pane))
    }

    func testRecognisesTheZshWording() {
        let pane = """
        ~ 35;83;23M35;118;61M35;117;60M
        zsh: command not found: 35
        """
        XCTAssertTrue(AutoReplyPoller.showsStrayMouseReports(inPaneText: pane))
    }

    /// A pane that is merely showing numbers keeps its mouse. Taking mouse
    /// support away from a TUI that is working is the failure this guards.
    func testLeavesOrdinaryOutputAlone() {
        let pane = """
        Timing 1;2;3M 4;5;6M 7;8;9M across three runs.
        All within budget.
        """
        XCTAssertFalse(AutoReplyPoller.showsStrayMouseReports(inPaneText: pane))
    }

    /// A genuine typo is a "command not found" without any reports behind it.
    func testTypoAloneIsNotEnough() {
        let pane = """
        $ gti status
        bash: gti: command not found
        """
        XCTAssertFalse(AutoReplyPoller.showsStrayMouseReports(inPaneText: pane))
    }

    /// A program whose name sits next to a number is not a bare number.
    func testNamedCommandNearANumberIsNotABareNumber() {
        let pane = """
        $ 35;47;44M35;51;50M35;52;50M
        bash: python3.11: command not found
        """
        XCTAssertFalse(AutoReplyPoller.showsStrayMouseReports(inPaneText: pane))
    }

    /// One stray report is noise; a dragged pointer produces a stream.
    func testASingleReportIsBelowThreshold() {
        let pane = """
        $ 35;47;44M
        bash: 35: command not found
        """
        XCTAssertFalse(AutoReplyPoller.showsStrayMouseReports(inPaneText: pane))
    }

    /// Evidence that has scrolled away is history, not a live fault. Left
    /// unbounded it would keep firing, and eventually fire at an agent that had
    /// relaunched in the same pane and legitimately wanted the mouse.
    func testEvidenceScrolledOffScreenIsNotActedOn() {
        let stale = """
        root@jw-server:/app# 35;47;44M35;51;50M
        35: command not found
        47: command not found
        51: command not found
        """
        let since = (1...60).map { "line \($0) of ordinary output" }.joined(separator: "\n")
        let pane = stale + "\n" + since
        XCTAssertTrue(
            AutoReplyPoller.showsStrayMouseReports(inPaneText: pane),
            "the evidence is still in the text"
        )
        XCTAssertFalse(
            AutoReplyPoller.showsStrayMouseReports(
                inPaneText: AutoReplyPoller.screenBottom(of: pane)
            ),
            "but not on screen any more, so it is not a live fault"
        )
    }

    /// The long run-together line from the screenshot: dozens of reports with
    /// no separator, which is what a drag looks like when nothing consumes it.
    func testCountsReportsRunTogetherOnOneLine() {
        let pane = """
        # 35;83;23M35;118;61M35;117;60M35;116;60M35;115;60M35;114;60M35;114;59M
        35: command not found
        """
        XCTAssertTrue(AutoReplyPoller.showsStrayMouseReports(inPaneText: pane))
    }
}
