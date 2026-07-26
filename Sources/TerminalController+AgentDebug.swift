import Foundation

#if DEBUG
extension TerminalController {

    /// Read a natively-held agent's transcript as data.
    ///
    /// The pane path can only be checked by reading its pixels — strip the
    /// ANSI, guess where one message ends, hope a redraw did not eat the line
    /// being looked for. That is the same guessing the completion detector had
    /// to do, and it is why "did this instruction arrive intact?" was never a
    /// question that could be answered, only estimated.
    ///
    /// Here the transcript is a list of values, and each sent turn is the
    /// agent's own receipt. So a test can state what it sent, read what the
    /// agent confirmed, and compare — exactly, including newlines, which the
    /// terminal path destroys on the way in.
    func v2DebugAgentTranscript(params: [String: Any]) -> V2CallResult {
        let wanted = (params["agent"] ?? params["agent_name"]) as? String

        var agents: [[String: Any]] = []
        for context in AppDelegate.shared?.mainWindowContexts.values ?? [:].values {
            for workspace in context.tabManager.tabs {
                for panel in workspace.panels.values.compactMap({ $0 as? AgentPanel }) {
                    guard wanted == nil || panel.agentName == wanted else { continue }
                    agents.append([
                        "agent": panel.agentName,
                        "team": panel.teamName,
                        "panel_id": panel.id.uuidString,
                        "running": panel.session.isRunning,
                        "thinking": panel.session.isThinking,
                        "summary": panel.session.summary ?? "",
                        "entries": panel.session.entries.map(Self.describe),
                    ])
                }
            }
        }
        return .ok(["agents": agents, "count": agents.count])
    }

    private static func describe(_ entry: AgentSession.Entry) -> [String: Any] {
        switch entry {
        case .said(_, let speaker, let text):
            return ["kind": "said",
                    "speaker": speaker == .person ? "person" : "leader",
                    "text": text]
        case .answered(_, let text):
            return ["kind": "answered", "text": text]
        case .thought(_, let body):
            return ["kind": "thought", "text": body ?? ""]
        case .tool(_, let call):
            return ["kind": "tool", "name": call.name, "headline": call.headline,
                    "result": call.result ?? "", "failed": call.failed,
                    "running": call.isRunning]
        case .turnEnded(_, let end):
            return ["kind": "turn_ended", "stop": end.stop, "failed": end.failed,
                    "cost": end.cost ?? 0, "duration": end.duration ?? 0,
                    "tokens_in": end.tokensIn ?? 0, "tokens_out": end.tokensOut ?? 0]
        case .notice(_, let text):
            return ["kind": "notice", "text": text]
        }
    }
}
#endif
