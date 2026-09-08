import Foundation

/// Model identifier → context-window token limit, for turning the daemon's
/// usage tick into "how full is the context right now".
///
/// A cache of a value the provider owns, so it is wrong the moment a model
/// ships and nobody edits this file. That is the reason for the shape below:
/// every family is listed explicitly and anything unlisted returns `nil`. A
/// default would quietly answer for models it has never heard of, and the
/// caller cannot tell a real limit from a filled-in one — a percentage
/// computed against a guessed denominator looks exactly like a measured one.
///
/// The authoritative live source is the Models API (`GET /v1/models/{id}`,
/// field `max_input_tokens`). Nothing here can call it: the daemon reads
/// usage out of CLI session logs and holds no API credentials of its own.
enum ModelContextLimits {
    /// Anthropic's current generation — Opus 4.6 and later, Sonnet 4.6 and
    /// later, and the Fable/Mythos tier — all carry a 1M-token context window
    /// as their standard (not opt-in) size.
    private static let oneMillion = 1_000_000

    /// Haiku 4.5 and the generations before the 1M rollout.
    private static let twoHundredThousand = 200_000

    /// Longest prefix wins, so a family entry cannot be shadowed by a shorter
    /// one that happens to match first (`claude-opus-4-6` before
    /// `claude-opus-4`). Keys are the model IDs the CLIs report, which for the
    /// current generation carry no date suffix.
    private static let limitsByModelPrefix: [String: Int] = [
        "claude-fable-5": oneMillion,
        "claude-mythos-5": oneMillion,
        "claude-opus-5": oneMillion,
        "claude-opus-4-8": oneMillion,
        "claude-opus-4-7": oneMillion,
        "claude-opus-4-6": oneMillion,
        "claude-sonnet-5": oneMillion,
        "claude-sonnet-4-6": oneMillion,
        "claude-haiku-4-5": twoHundredThousand,
    ]

    /// The context-window limit for a model identifier, or `nil` when this
    /// table has no entry for it.
    ///
    /// `nil` is a normal answer, not a failure: an older model, a new one
    /// released after this file was last touched, and a non-Anthropic model
    /// all land here. Callers show the raw token count instead of a
    /// percentage — see `AgentPanelView.header`.
    static func contextLimit(forModel model: String) -> Int? {
        guard !model.isEmpty else { return nil }
        return limitsByModelPrefix
            .filter { model.hasPrefix($0.key) }
            .max { $0.key.count < $1.key.count }?
            .value
    }
}
