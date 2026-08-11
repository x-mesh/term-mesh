import Foundation

#if DEBUG
extension TerminalController {

    func v2DebugAgentRenderStats(params: [String: Any]) -> V2CallResult {
        let wanted = (params["agent"] ?? params["agent_name"]) as? String
        var agents: [[String: Any]] = []
        for context in AppDelegate.shared?.mainWindowContexts.values ?? [:].values {
            for workspace in context.tabManager.tabs {
                for panel in workspace.panels.values.compactMap({ $0 as? AgentPanel }) {
                    guard wanted == nil || panel.agentName == wanted else { continue }
                    let metrics = panel.session.renderMetricsForDebug()
                    agents.append([
                        "agent": panel.agentName,
                        "team": panel.teamName,
                        "panel_id": panel.id.uuidString,
                        "batches": metrics.batches,
                        "lines": metrics.lines,
                        "bytes": metrics.bytes,
                        "revisions": metrics.revisions,
                        "auto_scrolls": metrics.autoScrolls,
                        "entries": metrics.entries,
                        "rendered_rows": metrics.renderedRows,
                        "apply_total_ms": metrics.applyTotalMs,
                        "apply_max_ms": metrics.applyMaxMs,
                        "bottom_y": metrics.bottomY,
                        "viewport_height": metrics.viewportHeight,
                        "following": metrics.following,
                        "follow_drops": metrics.followDrops,
                    ])
                }
            }
        }
        return .ok(["agents": agents, "count": agents.count])
    }

    func v2DebugTerminalRendererStates() -> V2CallResult {
        var surfaces: [[String: Any]] = []
        for context in AppDelegate.shared?.mainWindowContexts.values ?? [:].values {
            for workspace in context.tabManager.tabs {
                for panel in workspace.panels.values.compactMap({ $0 as? TerminalPanel }) {
                    let state = panel.surface.debugRendererVisibilityState()
                    surfaces.append([
                        "workspace_id": workspace.id.uuidString,
                        "panel_id": panel.id.uuidString,
                        "requested": state.requested,
                        "realized": state.realized,
                        "unrealize_pending": state.unrealizePending,
                        "unrealize_schedule_count": state.unrealizeScheduleCount,
                        "in_window": panel.hostedView.window != nil,
                        "hidden": panel.hostedView.isHidden,
                    ])
                }
            }
        }
        return .ok([
            "surfaces": surfaces,
            "count": surfaces.count,
            "realized_count": surfaces.lazy.filter { $0["realized"] as? Bool == true }.count,
            "requested_count": surfaces.lazy.filter { $0["requested"] as? Bool == true }.count,
        ])
    }

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
                        // What the rest of the app believes, beside what is
                        // actually true. These disagreed for most of an
                        // afternoon and comparing them is how that ended.
                        "runtime_state": TeamOrchestrator.shared.agentRuntimeStateForTesting(
                            teamName: panel.teamName, agentName: panel.agentName),
                        "in_flight": TeamOrchestrator.shared.isNativeTurnInFlight(
                            teamName: panel.teamName, agentName: panel.agentName),
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
            var described: [String: Any] = [
                "kind": "tool", "name": call.name, "headline": call.headline,
                "result": call.result ?? "", "failed": call.failed,
                "running": call.isRunning]
            // A diff can be right in the model and stale on screen, and only a
            // screenshot tells those apart. Reporting what the model holds is
            // what makes the screenshot worth taking.
            if let change = call.change {
                described["change"] = [
                    "path": change.path, "added": change.added,
                    "removed": change.removed, "lines": change.lines.count,
                    "elided": change.elided, "everywhere": change.everywhere]
            }
            return described
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
