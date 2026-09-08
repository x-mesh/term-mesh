import Foundation

/// Which `CliProfile` field a `.profileField` command sets from its typed
/// argument.
///
/// `/model` and `/effort` are the two. Adding a third needs a case here and
/// one more line in `AgentSlashCommands.apply(_:argument:to:)` — no new
/// branch anywhere in `AgentPanelView`, because applying the field is already
/// generic over which one it is.
enum AgentSlashProfileField: Equatable, Hashable {
    case model
    case effort

    /// The key this field takes in the bridge's control frame. The names are
    /// codex `TurnStartParams`' own (`model`, `effort`), which the bridge
    /// forwards verbatim, so this is the wire contract and not a local label.
    var controlFrameKey: String {
        switch self {
        case .model: return "model"
        case .effort: return "effort"
        }
    }
}

/// How a `.profileField` command's argument reaches a specific CLI, since the
/// same field can apply differently per CLI family.
///
/// Confirmed for codex-cli 0.153.4 (`codex app-server generate-json-schema`):
/// `TurnStartParams` carries both `model` and `effort` as per-turn overrides
/// — "Override the … for this turn and subsequent turns" — with no restart.
/// No other CLI here has been checked the same way, so `.restart` is their
/// default, not a verified claim about them.
enum AgentSlashFieldApplication: Equatable, Hashable {
    /// Sent as a parameter on the next turn request; the running
    /// conversation is not restarted and keeps its context. Actually
    /// carrying the parameter needs a bridge change outside this catalog's
    /// reach — see `AgentPanelView`'s deliberately unimplemented
    /// `runNextTurnParameterSlashCommand`.
    case nextTurnParameter
    /// Applied by rewriting the pane's `CliProfile` and hard-restarting it.
    /// The running conversation's context is lost, so callers must confirm
    /// before taking this path.
    case restart
}

/// What running a command does, once its argument is parsed out.
enum AgentSlashCommandKind: Equatable, Hashable {
    /// Prints a locally-produced answer; never touches a CLI process or a
    /// pane's profile.
    case localReport
    /// Sets one `CliProfile` field from the argument — the shape `/model`
    /// and `/effort` share. How the field reaches the CLI is
    /// per-family; see `AgentSlashCommand.applicationsByCLI`.
    case profileField(AgentSlashProfileField)
}

/// A slash command a native agent pane runs itself — `/model`, `/effort`,
/// `/cost`, `/help` — never
/// forwarded to the CLI as turn text.
///
/// `Sources/IME/IMEHistory.swift`'s `SlashCommands.builtinCommands` lists a
/// terminal CLI's *own* commands: fine for a pane where typing is stdin, but a
/// native pane's transport carries plain turn text with no runtime-control
/// channel, so most of that list would just echo back unhandled. This catalog
/// holds only what the app itself can perform.
struct AgentSlashCommand: Equatable, Hashable {
    let name: String
    let desc: String
    let kind: AgentSlashCommandKind
    /// How this command applies per CLI family (`CliProfile.family`), for
    /// `.profileField` commands. `nil` means "every CLI, uniformly" — used by
    /// `.localReport` commands, like `/cost` and `/help`, that never touch a
    /// CLI's turn parameters or profile. A `.profileField` command with no
    /// entry for a given CLI, or a `.localReport` command on any CLI when
    /// this is non-nil, does not support that CLI: it drops out of the
    /// autocomplete popover (`AgentSlashCommands.matches(prefix:for:)`) and
    /// gets a guidance notice instead of silent execution if typed anyway —
    /// see `AgentPanelView.send()`.
    let applicationsByCLI: [String: AgentSlashFieldApplication]?

    func supports(cli: String) -> Bool {
        guard let applicationsByCLI else { return true }
        return applicationsByCLI[cli] != nil
    }

    /// How this command applies for `cli`. `nil` for a `.localReport` command
    /// (the question does not apply) or an unsupported CLI.
    func application(for cli: String) -> AgentSlashFieldApplication? {
        applicationsByCLI?[cli]
    }
}

enum AgentSlashCommands {
    /// `/model` defaults every known CLI to `.restart` — the verified,
    /// already-shipping "Apply to Active Pane (Restart)" path — and only
    /// overrides `codex` to the confirmed restart-free `.nextTurnParameter`.
    /// `/effort` lists only codex: it is the one CLI confirmed to take the
    /// field at all, so an absent entry means unsupported rather than
    /// "restart instead".
    private static let modelApplications: [String: AgentSlashFieldApplication] = {
        var applications = Dictionary(
            uniqueKeysWithValues: AgentRolePreset.knownCLIs.map { ($0, AgentSlashFieldApplication.restart) }
        )
        applications["codex"] = .nextTurnParameter
        return applications
    }()

    static let catalog: [AgentSlashCommand] = [
        .init(
            name: "/model", desc: "Switch this pane's model",
            kind: .profileField(.model), applicationsByCLI: modelApplications
        ),
        .init(
            name: "/effort", desc: "Set this pane's reasoning effort",
            kind: .profileField(.effort), applicationsByCLI: ["codex": .nextTurnParameter]
        ),
        .init(
            name: "/cost", desc: "Show token usage for this agent",
            kind: .localReport, applicationsByCLI: nil
        ),
        .init(
            name: "/help", desc: "List commands this pane can run",
            kind: .localReport, applicationsByCLI: nil
        ),
    ]

    /// Looks up a catalog entry by name, case-insensitively, regardless of
    /// CLI support — a caller that finds a hit still has to check
    /// `supports(cli:)` itself, so it can tell "not an app command" (fall
    /// through to plain send) apart from "an app command, wrong CLI" (tell
    /// the person why nothing happened).
    static func command(named name: String) -> AgentSlashCommand? {
        catalog.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Catalog entries supported by `cli` whose name starts with `prefix`,
    /// for the composer's autocomplete popover. An empty or bare `"/"`
    /// prefix returns every command that CLI supports.
    static func matches(prefix: String, for cli: String) -> [AgentSlashCommand] {
        let supported = catalog.filter { $0.supports(cli: cli) }
        let query = prefix.lowercased()
        guard query != "/", !query.isEmpty else { return supported }
        return supported.filter { $0.name.lowercased().hasPrefix(query) }
    }

    /// Applies a `.profileField` command's argument to a profile in place —
    /// the `.restart` application's own step. One switch case per field.
    /// `false` when the field has no `CliProfile` representation, so the
    /// `.restart` application cannot carry it. `/effort` is that case: codex
    /// takes it as a turn parameter and no other CLI is known to take it at
    /// all, so nothing here writes it into a profile. Returning rather than
    /// silently doing nothing keeps a wrong `applicationsByCLI` entry from
    /// reading as a restart that applied.
    @discardableResult
    static func apply(
        _ field: AgentSlashProfileField, argument: String, to profile: inout CliProfile
    ) -> Bool {
        switch field {
        case .model:
            profile.modelOverride = argument
            return true
        case .effort:
            return false
        }
    }
}

/// A slash-command line split into its name and the text that followed it.
struct ParsedAgentSlashCommand: Equatable {
    let name: String
    let argument: String
}

enum AgentSlashCommandParser {
    /// Splits `"/model opus"` into name `"/model"` and argument `"opus"`.
    /// `nil` for anything not starting with `/`, so a caller can try this
    /// once and fall through to its normal send path without a second check.
    static func parse(_ text: String) -> ParsedAgentSlashCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        guard let spaceIndex = trimmed.firstIndex(where: { $0.isWhitespace }) else {
            return ParsedAgentSlashCommand(name: trimmed, argument: "")
        }
        let name = String(trimmed[..<spaceIndex])
        let argument = trimmed[trimmed.index(after: spaceIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedAgentSlashCommand(name: name, argument: argument)
    }
}
