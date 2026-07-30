import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class AgentStartupPromptTests: XCTestCase {
    private let trustPrompt = """
     Quick safety check: Is this a project you created or one you trust?

     Claude Code'll be able to read, edit, and execute files here.

     ❯ 1. Yes, I trust this folder
       2. No, exit

     Enter to confirm · Esc to cancel
    """

    func test_detects_the_folder_trust_prompt() {
        XCTAssertEqual(AgentStartupPrompt.detect(in: trustPrompt), .claudeFolderTrust)
    }

    func test_leaves_it_alone_when_the_caret_is_on_no() {
        // Someone is answering it themselves; do not overrule them.
        let moved = trustPrompt
            .replacingOccurrences(of: "❯ 1. Yes", with: "  1. Yes")
            .replacingOccurrences(of: "  2. No, exit", with: "❯ 2. No, exit")
        XCTAssertNil(AgentStartupPrompt.detect(in: moved))
    }

    func test_ignores_the_words_without_the_prompt() {
        // The capsule and this conversation both mention trusting a folder.
        XCTAssertNil(AgentStartupPrompt.detect(in: "we should check Yes, I trust this folder handling"))
    }

    func test_ignores_a_working_pane() {
        XCTAssertNil(AgentStartupPrompt.detect(in: "STATUS: DONE\nFILES: none\n"))
    }
}


@MainActor
final class ComposerDraftTests: XCTestCase {
    private func pane(_ composer: String) -> String {
        """
          STATUS: DONE
          FILES: none

        ✻ Worked for 4s

        ────────────────────────────────
        ❯ \(composer)
        ────────────────────────────────
          root@jw-server:~/remote-demo (master) Sonnet 5
        """
    }

    func test_finds_what_a_person_typed_and_did_not_send() {
        XCTAssertEqual(
            AutoReplyPoller.composerDraft(inPaneText: pane("data.txt 내용도 보여줘")),
            "data.txt 내용도 보여줘"
        )
    }

    func test_an_empty_composer_is_not_a_draft() {
        XCTAssertNil(AutoReplyPoller.composerDraft(inPaneText: pane("")))
    }

    func test_takes_the_last_composer_because_the_pane_redraws() {
        let text = "❯ old thought\n────\n❯ current thought"
        XCTAssertEqual(AutoReplyPoller.composerDraft(inPaneText: text), "current thought")
    }

    func test_a_pane_with_no_composer_reports_nothing() {
        XCTAssertNil(AutoReplyPoller.composerDraft(inPaneText: "STATUS: DONE\nFILES: none\n"))
    }
}
