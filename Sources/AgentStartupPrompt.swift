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
/// Deliberately narrow. It matches one prompt, only while the CLI's own cursor
/// is on the affirmative option, and answers with the key that option
/// documents. An unrecognised prompt is left alone: the pane stalls exactly as
/// it does today, which is a visible failure rather than a wrong answer.
enum AgentStartupPrompt: Equatable, CaseIterable {
    case claudeFolderTrust

    /// The key that commits the answer, in `sendNamedKey`'s vocabulary.
    var answerKey: String { "return" }

    /// Whether `text` is this prompt, awaiting its answer.
    func matches(_ text: String) -> Bool {
        switch self {
        case .claudeFolderTrust:
            // All three: the question, its affirmative option under the CLI's
            // own selection caret, and the line saying Return is what commits
            // it. The caret matters — if someone has moved the selection to
            // "No, exit", they are answering it themselves.
            guard text.contains("Enter to confirm") else { return false }
            guard text.contains("Yes, I trust this folder") else { return false }
            return text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .contains { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return trimmed.hasPrefix("❯") && trimmed.contains("Yes, I trust this folder")
                }
        }
    }

    /// The prompt showing in `text`, if any.
    static func detect(in text: String) -> AgentStartupPrompt? {
        allCases.first { $0.matches(text) }
    }
}
