import XCTest

/// Dragging inside a selectable SwiftUI `Text` puts AppKit into its
/// mouse-tracking loop, and TextKit 2 answers every mouse-moved event by
/// enumerating the document from the start. The cost is therefore per-move and
/// proportional to the whole text, however little of it is on screen.
///
/// Issue #321 was that loop over the Live Activity list: it pinned the main
/// thread at 100% until the app was killed. The fix removed
/// `.textSelection(.enabled)` from that one view, and the same pattern stayed
/// everywhere else — including the two views holding far more text than the
/// activity list ever did. A hang report on 0.228.0 (2026-09-07, 1.04s with
/// 0.999s of main-thread CPU) showed the identical stack, down to
/// `NSBigMutableString`.
///
/// Selection is fine on the short strings this app makes selectable elsewhere:
/// an error message, a SHA, a path. It is not fine on a whole document, and
/// these are the documents.
final class LargeTextSelectionSourceTests: XCTestCase {
    /// File → the expression whose text is a whole document, not a label.
    ///
    /// Named individually rather than matched by a pattern: the point is not
    /// that selection is banned, it is that these specific texts are too large
    /// to drag across. A new large view has to be added here deliberately.
    private static let unselectableDocuments: [(file: String, render: String, why: String)] = [
        (
            "ReviewBoardPanelView.swift",
            "Text(patch.text)",
            "a patch, capped at ReviewBoardEvidence.displayByteLimit (256KB) — the "
                + "largest text this app shows in one view"
        ),
        (
            "BugReport.swift",
            "Text(bundle)",
            "the whole diagnostics bundle; Copy and Save already hand it over"
        ),
        (
            "Panels/AgentPanelView.swift",
            ".frame(width: transcriptWidth, alignment: .leading)",
            "one selection scope over every mounted transcript row (Sentry TERM-MESH-3N, "
                + "a 4 s synchronous layout); rows gate themselves with transcriptSelectable"
        ),
        (
            "Panels/AgentPanelView.swift",
            "Text(result)",
            "a tool result of any length; displayExcerpt caps what is laid out and "
                + "transcriptSelectable caps selection"
        ),
        (
            "Panels/AgentPanelView.swift",
            "Text(shown).font",
            "a code block, which inherits the selection cap from MarkdownText and is truncated by `shown`"
        ),
        (
            "Panels/AgentPanelView.swift",
            "Text(text.replacingOccurrences",
            "one diff line, repeated per line of a diff; \"copy diff\" covers it"
        ),
    ]

    func testTheLargestTextViewsAreNotSelectable() throws {
        let sources = findProjectRoot().appendingPathComponent("Sources")

        var offenders: [String] = []
        for document in Self.unselectableDocuments {
            let url = sources.appendingPathComponent(document.file)
            let source = try String(contentsOf: url, encoding: .utf8)
            let lines = source.components(separatedBy: "\n")

            let renderIndex = lines.firstIndex { $0.contains(document.render) }
            guard let renderIndex else {
                offenders.append(
                    "\(document.file): \(document.render) is gone — if the view was "
                        + "rewritten, update this test to name what replaced it"
                )
                continue
            }

            // `.textSelection` rides the same view as the modifiers under it,
            // so a reintroduction lands within a few lines of the render.
            let window = lines[renderIndex...].prefix(8)
            if window.contains(where: { $0.contains("textSelection(.enabled)") }) {
                offenders.append(
                    "\(document.file):\(renderIndex + 1) makes \(document.render) selectable "
                        + "— \(document.why)"
                )
            }
        }

        XCTAssertEqual(
            offenders, [],
            """
            Drag-selecting one of these re-enumerates the whole document on every
            mouse-moved event and wedges the main thread (issue #321). Give the view a
            Copy button instead of selection.
            """
        )
    }

    /// Selection in the agent transcript has one door: `TranscriptSelectable`, which
    /// applies the 20-leaf budget and the byte cap. A direct `.textSelection(.enabled)`
    /// anywhere else in the file makes a source outside both limits — a transcript
    /// footer did exactly that — so the call is allowed only inside that type.
    func testAgentTranscriptSelectionIsOnlyEnabledInsideTranscriptSelectable() throws {
        let source = try String(
            contentsOf: findProjectRoot().appendingPathComponent("Sources/Panels/AgentPanelView.swift"),
            encoding: .utf8
        )
        let lines = source.components(separatedBy: "\n")

        let start = try XCTUnwrap(
            lines.firstIndex { $0.hasPrefix("private struct TranscriptSelectable") },
            "TranscriptSelectable is gone — update this test to name what replaced it"
        )
        let end = try XCTUnwrap(lines[start...].firstIndex { $0 == "}" })
        let allowed = start...end

        var offenders: [String] = []
        var insideAllowed = 0
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//"), line.contains(".textSelection(.enabled)") else { continue }
            if allowed.contains(index) { insideAllowed += 1 } else {
                offenders.append("AgentPanelView.swift:\(index + 1): \(line)")
            }
        }
        XCTAssertEqual(
            offenders, [],
            "enable selection only through transcriptSelectable (20-leaf budget, 4KB cap)"
        )
        XCTAssertEqual(insideAllowed, 1, "TranscriptSelectable must be the one place that enables it")

        let guarded = lines[allowed]
        XCTAssertTrue(
            guarded.contains { $0.contains("TranscriptSelection.isSelectable(text, recentRow: recentRow)") },
            "TranscriptSelectable must apply both the byte cap and the recent-row limit"
        )
    }

    /// The replacement for dragging. Without it the patch pane has no way at
    /// all to get its text out, which would be a worse pane than before.
    func testThePatchPaneOffersCopyInsteadOfSelection() throws {
        let source = try String(
            contentsOf: findProjectRoot()
                .appendingPathComponent("Sources/ReviewBoardPanelView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("reviewBoard.review.copyPatch"),
            "the patch pane must keep a Copy control now that it is not selectable"
        )
        XCTAssertTrue(
            source.contains("setString(patch.text, forType: .string)"),
            "Copy must put the patch itself on the pasteboard"
        )
    }

    private func findProjectRoot() -> URL {
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<10 {
            let marker = dir.appendingPathComponent("GhosttyTabs.xcodeproj")
            if FileManager.default.fileExists(atPath: marker.path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
