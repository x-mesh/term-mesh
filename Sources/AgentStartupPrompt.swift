import Foundation

/// A first-run question an agent CLI asks before it will do anything.
///
/// Claude Code asks whether you trust the folder the first time it is started
/// in one. It is the right question to ask a person opening an unfamiliar
/// repository, and the wrong one to leave sitting in an agent pane: the agent
/// never starts, the task board says `assigned`, and the only way past it is
/// for someone to notice the pane and press Return. That is the same failure
/// as a swallowed Enter, arriving by a different road.
///
/// Answering it here is not deciding the question. term-mesh chose the
/// directory — it is the team's working directory, which the person picked
/// when they made the team — and the CLI is already being launched with
/// permissions bypassed. The trust decision was made upstream; this stops it
/// being asked again of nobody.
///
/// This used to answer only while the CLI's own caret already sat on the
/// affirmative option, so that a person mid-answer was never overruled. Claude
/// Code then changed the prompt: the options lost their numbers, "No, exit"
/// moved to the top, and it is now the default selection. That made the caret
/// useless as a signal of intent — resting on "No" is where every prompt now
/// starts — and the guard silently stopped firing, stranding every new remote
/// Project at the trust screen. So the caret is now something to move rather
/// than something to defer to, and the answer carries the arrow keys needed to
/// reach the affirmative option.
///
/// Still deliberately narrow. It matches one prompt per CLI, requires the two
/// options to be adjacent lines with the caret on one of them, and answers with
/// the key the prompt itself documents. Anything else in the pane is left
/// alone: it stalls visibly rather than being answered wrongly. `AutoReplyPoller`
/// answers at most once per pane, so a CLI that asks twice still reaches a
/// person.
enum AgentStartupPrompt: Equatable, CaseIterable {
    case claudeFolderTrust
    case codexDirectoryTrust

    /// The line that says which key commits the selection.
    private var commitHint: String {
        switch self {
        case .claudeFolderTrust: return "Enter to confirm"
        case .codexDirectoryTrust: return "Press enter to continue"
        }
    }

    /// The option to end up on.
    private var affirmative: String {
        switch self {
        case .claudeFolderTrust: return "Yes, I trust this folder"
        case .codexDirectoryTrust: return "Yes, continue"
        }
    }

    /// The option to move away from. Required so a stray line mentioning the
    /// affirmative text cannot look like a selection list.
    private var negative: String {
        switch self {
        case .claudeFolderTrust: return "No, exit"
        case .codexDirectoryTrust: return "No, quit"
        }
    }

    /// The key that commits the answer, in `sendNamedKey`'s vocabulary.
    var answerKey: String { "return" }

    /// Selection carets used by these TUIs. All are accepted for either prompt:
    /// which glyph a CLI draws is a detail it has already changed once. Plain
    /// `>` is excluded for the same reason `localLeaderPaneLooksReady` excludes
    /// it — ordinary text starts with it too often to read as a selection.
    private static let carets: [Character] = ["❯", "›", "»"]

    /// Whether `text` is this prompt, awaiting its answer.
    func matches(_ text: String) -> Bool {
        answer(in: text) != nil
    }

    /// The keys that answer this prompt in `text`, in send order: the caret
    /// movements needed to reach the affirmative option, then the commit key.
    func answer(in text: String) -> [String]? {
        guard text.contains(commitHint), text.contains(affirmative) else { return nil }
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard let yes = lines.firstIndex(where: { $0.contains(affirmative) }),
              let no = lines.firstIndex(where: { $0.contains(negative) }),
              abs(yes - no) == 1
        else { return nil }

        // The caret has to be on one of the two options. If it is anywhere
        // else the pane is not sitting on this selection list and counting
        // arrow presses from it would be guesswork.
        let isCaretLine: (String) -> Bool = { line in
            guard let first = line.first else { return false }
            return Self.carets.contains(first)
        }
        guard let caret = [yes, no].first(where: { isCaretLine(lines[$0]) }) else { return nil }

        let moves = yes - caret
        let arrow = moves > 0 ? "down" : "up"
        return Array(repeating: arrow, count: abs(moves)) + [answerKey]
    }

    /// The bytes one answer key is on a remote pane.
    ///
    /// A peer pane has no key-event path — the relay carries a byte stream — so
    /// the same answer has to exist in both vocabularies. Keeping the mapping
    /// here means the local and remote paths cannot drift into answering
    /// different options.
    static func remoteBytes(forKey key: String) -> Data? {
        switch key {
        case "down": return Data([0x1B, 0x5B, 0x42])  // ESC [ B
        case "up": return Data([0x1B, 0x5B, 0x41])    // ESC [ A
        case "return": return Data([0x0D])
        default: return nil
        }
    }

    /// The prompt showing in `text`, if any.
    static func detect(in text: String) -> AgentStartupPrompt? {
        allCases.first { $0.matches(text) }
    }

    /// The prompt showing in `text` together with the keys that answer it.
    static func answer(in text: String) -> (prompt: AgentStartupPrompt, keys: [String])? {
        for prompt in allCases {
            if let keys = prompt.answer(in: text) { return (prompt, keys) }
        }
        return nil
    }
}
