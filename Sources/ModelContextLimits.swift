import Foundation

/// Model identifier → context-window token limit, for computing "how full is
/// the context right now" as a percentage from the daemon's usage tick.
///
/// This is a maintenance liability by nature — a new model needs a new entry
/// here — so every value is kept in one place with its source noted. An
/// unknown model returns `nil` rather than a guessed value: showing a wrong
/// percentage is worse than showing none.
enum ModelContextLimits {
    /// Standard context window, in tokens, published by Anthropic for the
    /// Claude 3.x/4.x model families (docs.anthropic.com/en/docs/about-claude/models,
    /// as of this codebase's knowledge cutoff). Excludes the opt-in 1M-token
    /// beta context window some Sonnet 4.x deployments can enable — that beta
    /// is not something this table can detect from the model string alone,
    /// so the conservative standard limit is used.
    private static let claudeStandardContextWindow = 200_000

    /// Look up the context-window limit for a model identifier. Matches by
    /// prefix the same way `daemon/term-meshd/src/tokens.rs`'s
    /// `model_pricing` does, since both read the same `model` strings emitted
    /// by the Claude/Codex CLIs. Returns `nil` for anything not explicitly
    /// known — never an approximation.
    static func contextLimit(forModel model: String) -> Int? {
        guard model.hasPrefix("claude-") else { return nil }
        return claudeStandardContextWindow
    }
}
