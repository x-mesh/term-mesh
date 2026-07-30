import Foundation
import Combine

/// A pane that hosts an agent directly, with no terminal in between.
///
/// The browser panel already proved the split tree does not care what is in a
/// pane. This is the same move for agents: `TerminalPanel` exists because the
/// thing inside it needed a terminal, and — measured — an agent taking turns on
/// a pipe does not.
@MainActor
final class AgentPanel: ObservableObject, Panel {
    let id: UUID
    var panelType: PanelType { .agent }

    /// The team name and role this pane is, kept so a reply can be attributed
    /// without asking the view what it is showing.
    let agentName: String
    let teamName: String
    let workingDirectory: String
    /// Which CLI is behind this pane, and the colour the team assigned it.
    ///
    /// Five panes side by side are five identical grey headers otherwise. The
    /// team already picks a colour per agent and the pane title already shows
    /// it as an emoji; nothing was carrying either into the view.
    let cli: String
    let color: String

    @Published var title: String
    var displayTitle: String { title }
    var displayIcon: String? { "sparkle" }

    let session = AgentSession()

    private var cancellables = Set<AnyCancellable>()
    private var focusRequest: (() -> Void)?

    init(id: UUID = UUID(), agentName: String, teamName: String,
         workingDirectory: String, cli: String = "claude", color: String = "",
         title: String? = nil) {
        self.id = id
        self.agentName = agentName
        self.teamName = teamName
        self.workingDirectory = workingDirectory
        self.cli = cli
        self.color = color
        self.title = title ?? agentName
        // A panel is an ObservableObject wrapping another one, so its own
        // changes have to be forwarded or the pane never redraws.
        session.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func start(claudePath: String, model: String, instructions: String,
               extraArgs: [String] = []) {
        session.start(AgentSession.claudeLaunch(
            claudePath: claudePath, model: model, instructions: instructions,
            extraArgs: extraArgs, workingDirectory: workingDirectory
        ))
    }

    /// A CLI whose protocol the bridge speaks. Its instructions arrive as the
    /// first turn instead of a system prompt — the bridge has no equivalent of
    /// `--append-system-prompt`, and none of these CLIs agree on one.
    func start(bridgedCli: String, bridgePath: String, model: String,
               cliPath: String = "") {
        session.start(AgentSession.bridgeLaunch(
            cli: bridgedCli, bridgePath: bridgePath, model: model,
            cliPath: cliPath, workingDirectory: workingDirectory
        ))
    }

    func start(remoteClaudeAt target: String, port: Int?, identityFile: String?,
               model: String, instructions: String,
               remoteEnvironment: [String: String] = [:]) {
        session.start(AgentSession.remoteClaudeLaunch(
            sshTarget: target, port: port, identityFile: identityFile,
            model: model, instructions: instructions,
            workingDirectory: workingDirectory,
            remoteEnvironment: remoteEnvironment
        ))
    }

    func start(remoteBridgedCli cli: String, bridgePath: String, model: String,
               target: String, port: Int?, identityFile: String?,
               remoteEnvironment: [String: String] = [:]) {
        session.start(AgentSession.remoteBridgeLaunch(
            cli: cli, bridgePath: bridgePath, model: model,
            sshTarget: target, port: port, identityFile: identityFile,
            workingDirectory: workingDirectory,
            remoteEnvironment: remoteEnvironment
        ))
    }

    // MARK: - Panel

    func close() {
        session.stop()
        cancellables.removeAll()
    }

    func focus() { focusRequest?() }
    func unfocus() {}

    @Published var flashToken = UUID()
    func triggerFlash() { flashToken = UUID() }

    /// The view installs this so `focus()` — which arrives from the socket and
    /// the menu, not from a click — can put the caret in the composer.
    func onFocusRequested(_ handler: @escaping () -> Void) {
        focusRequest = handler
    }
}
