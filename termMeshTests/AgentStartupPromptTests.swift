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

    private let codexTrustPrompt = """
    Do you trust the contents of this directory?
    › 1. Yes, continue
      2. No, quit
    Press enter to continue
    """

    func test_detects_the_folder_trust_prompt() {
        XCTAssertEqual(AgentStartupPrompt.detect(in: trustPrompt), .claudeFolderTrust)
    }

    func test_detects_the_codex_directory_trust_prompt() {
        XCTAssertEqual(
            AgentStartupPrompt.detect(in: codexTrustPrompt), .codexDirectoryTrust
        )
    }

    /// The prompt Claude Code actually shows now: no numbers, "No, exit" first
    /// and selected by default. The old caret-must-be-on-yes rule never fired
    /// against this, which stranded every new remote Project at this screen.
    private let currentTrustPrompt = """
    Accessing workspace:

    /Users/jinwoo/work/tm-projects/aic

    Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project, or work from your team). If not, take a moment to review what's in this folder first.

    Claude Code'll be able to read, edit, and execute files here.

    Security guide

    ❯ No, exit
      Yes, I trust this folder

    Enter to confirm · Esc to cancel
    """

    func test_detects_the_current_prompt_with_no_selected_by_default() {
        XCTAssertEqual(AgentStartupPrompt.detect(in: currentTrustPrompt), .claudeFolderTrust)
    }

    func test_moves_the_caret_onto_yes_before_committing() {
        XCTAssertEqual(
            AgentStartupPrompt.answer(in: currentTrustPrompt)?.keys,
            ["down", "return"],
            "committing without moving first answers No, which quits the CLI"
        )
    }

    func test_commits_directly_when_the_caret_already_sits_on_yes() {
        XCTAssertEqual(AgentStartupPrompt.answer(in: trustPrompt)?.keys, ["return"])

        let moved = currentTrustPrompt
            .replacingOccurrences(of: "❯ No, exit", with: "  No, exit")
            .replacingOccurrences(of: "  Yes, I trust this folder", with: "❯ Yes, I trust this folder")
        XCTAssertEqual(AgentStartupPrompt.answer(in: moved)?.keys, ["return"])
    }

    func test_moves_up_when_the_affirmative_is_above_the_caret() {
        let moved = codexTrustPrompt
            .replacingOccurrences(of: "› 1. Yes", with: "  1. Yes")
            .replacingOccurrences(of: "  2. No, quit", with: "› 2. No, quit")
        XCTAssertEqual(AgentStartupPrompt.answer(in: moved)?.keys, ["up", "return"])
    }

    func test_ignores_a_list_whose_options_are_not_adjacent() {
        // Two separated lines are not one selection list, and counting arrow
        // presses across the gap would be guesswork.
        let split = currentTrustPrompt
            .replacingOccurrences(
                of: "❯ No, exit\n  Yes, I trust this folder",
                with: "❯ No, exit\n\n  Yes, I trust this folder"
            )
        XCTAssertNil(AgentStartupPrompt.answer(in: split)?.keys)
    }

    func test_ignores_the_prompt_when_no_caret_is_on_either_option() {
        let caretless = currentTrustPrompt.replacingOccurrences(of: "❯ No, exit", with: "  No, exit")
        XCTAssertNil(AgentStartupPrompt.detect(in: caretless))
    }

    /// A peer pane has no key-event path, only a byte stream, so the same
    /// answer has to exist in both vocabularies or the local and remote paths
    /// answer different rows.
    func test_every_answer_key_has_remote_bytes() {
        XCTAssertEqual(AgentStartupPrompt.remoteBytes(forKey: "down"), Data([0x1B, 0x5B, 0x42]))
        XCTAssertEqual(AgentStartupPrompt.remoteBytes(forKey: "up"), Data([0x1B, 0x5B, 0x41]))
        XCTAssertEqual(AgentStartupPrompt.remoteBytes(forKey: "return"), Data([0x0D]))
        XCTAssertNil(AgentStartupPrompt.remoteBytes(forKey: "escape"))

        for prompt in AgentStartupPrompt.allCases {
            let text = prompt == .claudeFolderTrust ? currentTrustPrompt : codexTrustPrompt
            let keys = AgentStartupPrompt.answer(in: text)?.keys ?? []
            XCTAssertFalse(keys.isEmpty, "\(prompt) produced no answer")
            for key in keys {
                XCTAssertNotNil(
                    AgentStartupPrompt.remoteBytes(forKey: key),
                    "\(prompt) answers with \(key), which no remote byte sequence covers"
                )
            }
        }
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
