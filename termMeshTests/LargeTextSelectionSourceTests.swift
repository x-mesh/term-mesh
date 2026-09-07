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
