import AppKit
import Foundation
import Carbon.HIToolbox
import Bonsplit
import WebKit

extension TerminalController {
    // MARK: - V2 Debug / Test-only Methods

#if DEBUG
    func v2DebugShortcutSet(params: [String: Any]) -> V2CallResult {
        guard let name = v2String(params, "name"),
              let combo = v2String(params, "combo") else {
            return .err(code: "invalid_params", message: "Missing name/combo", data: nil)
        }
        let resp = setShortcut("\(name) \(combo)")
        return resp == "OK"
            ? .ok([:])
            : .err(code: "internal_error", message: resp, data: nil)
    }

    func v2DebugShortcutSimulate(params: [String: Any]) -> V2CallResult {
        guard let combo = v2String(params, "combo") else {
            return .err(code: "invalid_params", message: "Missing combo", data: nil)
        }
        let resp = simulateShortcut(combo)
        return resp == "OK"
            ? .ok([:])
            : .err(code: "internal_error", message: resp, data: nil)
    }

    func v2DebugType(params: [String: Any]) -> V2CallResult {
        guard let text = params["text"] as? String else {
            return .err(code: "invalid_params", message: "Missing text", data: nil)
        }

        var result: V2CallResult = .err(code: "internal_error", message: "No window", data: nil)
        DispatchQueue.main.sync {
            guard let window = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible })
                ?? NSApp.windows.first else {
                result = .err(code: "not_found", message: "No window", data: nil)
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            guard let fr = window.firstResponder else {
                result = .err(code: "not_found", message: "No first responder", data: nil)
                return
            }
            if let client = fr as? NSTextInputClient {
                client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                result = .ok([:])
                return
            }
            (fr as? NSResponder)?.insertText(text)
            result = .ok([:])
        }
        return result
    }

    func v2DebugActivateApp() -> V2CallResult {
        let resp = activateApp()
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    func v2DebugToggleCommandPalette(params: [String: Any]) -> V2CallResult {
        let requestedWindowId = v2UUID(params, "window_id")
        var result: V2CallResult = .ok([:])
        DispatchQueue.main.sync {
            let targetWindow: NSWindow?
            if let requestedWindowId {
                guard let window = AppDelegate.shared?.mainWindow(for: requestedWindowId) else {
                    result = .err(
                        code: "not_found",
                        message: "Window not found",
                        data: ["window_id": requestedWindowId.uuidString, "window_ref": v2Ref(kind: .window, uuid: requestedWindowId)]
                    )
                    return
                }
                targetWindow = window
            } else {
                targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
            }
            NotificationCenter.default.post(name: .commandPaletteToggleRequested, object: targetWindow)
        }
        return result
    }

    func v2DebugOpenCommandPaletteRenameTabInput(params: [String: Any]) -> V2CallResult {
        let requestedWindowId = v2UUID(params, "window_id")
        var result: V2CallResult = .ok([:])
        DispatchQueue.main.sync {
            let targetWindow: NSWindow?
            if let requestedWindowId {
                guard let window = AppDelegate.shared?.mainWindow(for: requestedWindowId) else {
                    result = .err(
                        code: "not_found",
                        message: "Window not found",
                        data: [
                            "window_id": requestedWindowId.uuidString,
                            "window_ref": v2Ref(kind: .window, uuid: requestedWindowId)
                        ]
                    )
                    return
                }
                targetWindow = window
            } else {
                targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
            }
            NotificationCenter.default.post(name: .commandPaletteRenameTabRequested, object: targetWindow)
        }
        return result
    }

    func v2DebugCommandPaletteVisible(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        var visible = false
        DispatchQueue.main.sync {
            visible = AppDelegate.shared?.isCommandPaletteVisible(windowId: windowId) ?? false
        }
        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "visible": visible
        ])
    }

    func v2DebugCommandPaletteSelection(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        var visible = false
        var selectedIndex = 0
        DispatchQueue.main.sync {
            visible = AppDelegate.shared?.isCommandPaletteVisible(windowId: windowId) ?? false
            selectedIndex = AppDelegate.shared?.commandPaletteSelectionIndex(windowId: windowId) ?? 0
        }
        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "visible": visible,
            "selected_index": max(0, selectedIndex)
        ])
    }

    func v2DebugCommandPaletteResults(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        let requestedLimit = params["limit"] as? Int
        let limit = max(1, min(100, requestedLimit ?? 20))

        var visible = false
        var selectedIndex = 0
        var snapshot = CommandPaletteDebugSnapshot.empty

        DispatchQueue.main.sync {
            visible = AppDelegate.shared?.isCommandPaletteVisible(windowId: windowId) ?? false
            selectedIndex = AppDelegate.shared?.commandPaletteSelectionIndex(windowId: windowId) ?? 0
            snapshot = AppDelegate.shared?.commandPaletteSnapshot(windowId: windowId) ?? .empty
        }

        let rows = Array(snapshot.results.prefix(limit)).map { row in
            [
                "command_id": row.commandId,
                "title": row.title,
                "shortcut_hint": v2OrNull(row.shortcutHint),
                "trailing_label": v2OrNull(row.trailingLabel),
                "score": row.score
            ] as [String: Any]
        }

        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "visible": visible,
            "selected_index": max(0, selectedIndex),
            "query": snapshot.query,
            "mode": snapshot.mode,
            "results": rows
        ])
    }

    func v2DebugCommandPaletteRenameInputInteraction(params: [String: Any]) -> V2CallResult {
        let requestedWindowId = v2UUID(params, "window_id")
        var result: V2CallResult = .ok([:])
        DispatchQueue.main.sync {
            let targetWindow: NSWindow?
            if let requestedWindowId {
                guard let window = AppDelegate.shared?.mainWindow(for: requestedWindowId) else {
                    result = .err(
                        code: "not_found",
                        message: "Window not found",
                        data: [
                            "window_id": requestedWindowId.uuidString,
                            "window_ref": v2Ref(kind: .window, uuid: requestedWindowId)
                        ]
                    )
                    return
                }
                targetWindow = window
            } else {
                targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
            }
            NotificationCenter.default.post(name: .commandPaletteRenameInputInteractionRequested, object: targetWindow)
        }
        return result
    }

    func v2DebugCommandPaletteRenameInputDeleteBackward(params: [String: Any]) -> V2CallResult {
        let requestedWindowId = v2UUID(params, "window_id")
        var result: V2CallResult = .ok([:])
        DispatchQueue.main.sync {
            let targetWindow: NSWindow?
            if let requestedWindowId {
                guard let window = AppDelegate.shared?.mainWindow(for: requestedWindowId) else {
                    result = .err(
                        code: "not_found",
                        message: "Window not found",
                        data: [
                            "window_id": requestedWindowId.uuidString,
                            "window_ref": v2Ref(kind: .window, uuid: requestedWindowId)
                        ]
                    )
                    return
                }
                targetWindow = window
            } else {
                targetWindow = NSApp.keyWindow ?? NSApp.mainWindow
            }
            NotificationCenter.default.post(name: .commandPaletteRenameInputDeleteBackwardRequested, object: targetWindow)
        }
        return result
    }

    func v2DebugCommandPaletteRenameInputSelection(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }

        var result: V2CallResult = .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "focused": false,
            "selection_location": 0,
            "selection_length": 0,
            "text_length": 0
        ])

        DispatchQueue.main.sync {
            guard let window = AppDelegate.shared?.mainWindow(for: windowId) else {
                result = .err(
                    code: "not_found",
                    message: "Window not found",
                    data: ["window_id": windowId.uuidString, "window_ref": v2Ref(kind: .window, uuid: windowId)]
                )
                return
            }
            guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else {
                return
            }
            let selectedRange = editor.selectedRange()
            let textLength = (editor.string as NSString).length
            result = .ok([
                "window_id": windowId.uuidString,
                "window_ref": v2Ref(kind: .window, uuid: windowId),
                "focused": true,
                "selection_location": max(0, selectedRange.location),
                "selection_length": max(0, selectedRange.length),
                "text_length": max(0, textLength)
            ])
        }

        return result
    }

    func v2DebugCommandPaletteRenameInputSelectAll(params: [String: Any]) -> V2CallResult {
        if let rawEnabled = params["enabled"] {
            guard let enabled = rawEnabled as? Bool else {
                return .err(
                    code: "invalid_params",
                    message: "enabled must be a bool",
                    data: ["enabled": rawEnabled]
                )
            }
            DispatchQueue.main.sync {
                UserDefaults.standard.set(
                    enabled,
                    forKey: CommandPaletteRenameSelectionSettings.selectAllOnFocusKey
                )
            }
        }

        var enabled = CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus
        DispatchQueue.main.sync {
            enabled = CommandPaletteRenameSelectionSettings.selectAllOnFocusEnabled()
        }

        return .ok([
            "enabled": enabled
        ])
    }

    func v2DebugSidebarVisible(params: [String: Any]) -> V2CallResult {
        guard let windowId = v2UUID(params, "window_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid window_id", data: nil)
        }
        var visibility: Bool?
        DispatchQueue.main.sync {
            visibility = AppDelegate.shared?.sidebarVisibility(windowId: windowId)
        }
        guard let visible = visibility else {
            return .err(
                code: "not_found",
                message: "Window not found",
                data: ["window_id": windowId.uuidString, "window_ref": v2Ref(kind: .window, uuid: windowId)]
            )
        }
        return .ok([
            "window_id": windowId.uuidString,
            "window_ref": v2Ref(kind: .window, uuid: windowId),
            "visible": visible
        ])
    }

    func v2DebugIsTerminalFocused(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2String(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        let resp = isTerminalFocused(surfaceId)
        if resp.hasPrefix("ERROR") {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        return .ok(["focused": resp.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"])
    }

    func v2DebugReadTerminalText(params: [String: Any]) -> V2CallResult {
        let surfaceArg = v2String(params, "surface_id") ?? ""
        let resp = readTerminalText(surfaceArg)
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let b64 = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        return .ok(["base64": b64])
    }

    func v2DebugRenderStats(params: [String: Any]) -> V2CallResult {
        let surfaceArg = v2String(params, "surface_id") ?? ""
        let resp = renderStats(surfaceArg)
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let jsonStr = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return .err(code: "internal_error", message: "render_stats JSON decode failed", data: ["payload": String(jsonStr.prefix(200))])
        }
        return .ok(["stats": obj])
    }

    func v2DebugLayout() -> V2CallResult {
        let resp = layoutDebug()
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let jsonStr = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return .err(code: "internal_error", message: "layout_debug JSON decode failed", data: ["payload": String(jsonStr.prefix(200))])
        }
        return .ok(["layout": obj])
    }

    func v2DebugBonsplitUnderflowCount() -> V2CallResult {
        let resp = bonsplitUnderflowCount()
        guard resp.hasPrefix("OK ") else { return .err(code: "internal_error", message: resp, data: nil) }
        let n = Int(resp.split(separator: " ").last ?? "0") ?? 0
        return .ok(["count": n])
    }

    func v2DebugResetBonsplitUnderflowCount() -> V2CallResult {
        let resp = resetBonsplitUnderflowCount()
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    func v2DebugEmptyPanelCount() -> V2CallResult {
        let resp = emptyPanelCount()
        guard resp.hasPrefix("OK ") else { return .err(code: "internal_error", message: resp, data: nil) }
        let n = Int(resp.split(separator: " ").last ?? "0") ?? 0
        return .ok(["count": n])
    }

    func v2DebugResetEmptyPanelCount() -> V2CallResult {
        let resp = resetEmptyPanelCount()
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    func v2DebugFocusNotification(params: [String: Any]) -> V2CallResult {
        guard let wsId = v2String(params, "workspace_id") else {
            return .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
        }
        let surfaceId = v2String(params, "surface_id")
        let args = surfaceId != nil ? "\(wsId) \(surfaceId!)" : wsId
        let resp = focusFromNotification(args)
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    func v2DebugFlashCount(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2String(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        let resp = flashCount(surfaceId)
        guard resp.hasPrefix("OK ") else { return .err(code: "internal_error", message: resp, data: nil) }
        let n = Int(resp.split(separator: " ").last ?? "0") ?? 0
        return .ok(["count": n])
    }

    func v2DebugResetFlashCounts() -> V2CallResult {
        let resp = resetFlashCounts()
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    func v2DebugPanelSnapshot(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2String(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        let label = v2String(params, "label") ?? ""
        let args = label.isEmpty ? surfaceId : "\(surfaceId) \(label)"
        let resp = panelSnapshot(args)
        guard resp.hasPrefix("OK ") else { return .err(code: "internal_error", message: resp, data: nil) }
        let payload = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = payload.split(separator: " ", maxSplits: 4).map(String.init)
        guard parts.count == 5 else {
            return .err(code: "internal_error", message: "panel_snapshot parse failed", data: ["payload": payload])
        }
        return .ok([
            "surface_id": parts[0],
            "changed_pixels": Int(parts[1]) ?? -1,
            "width": Int(parts[2]) ?? 0,
            "height": Int(parts[3]) ?? 0,
            "path": parts[4]
        ])
    }

    func v2DebugPanelSnapshotReset(params: [String: Any]) -> V2CallResult {
        guard let surfaceId = v2String(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing surface_id", data: nil)
        }
        let resp = panelSnapshotReset(surfaceId)
        return resp == "OK" ? .ok([:]) : .err(code: "internal_error", message: resp, data: nil)
    }

    func v2DebugScreenshot(params: [String: Any]) -> V2CallResult {
        let label = v2String(params, "label") ?? ""
        let resp = captureScreenshot(label)
        guard resp.hasPrefix("OK ") else {
            return .err(code: "internal_error", message: resp, data: nil)
        }
        let payload = String(resp.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = payload.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return .err(code: "internal_error", message: "screenshot parse failed", data: ["payload": payload])
        }
        return .ok([
            "screenshot_id": parts[0],
            "path": parts[1]
        ])
    }
#endif

    struct ReadScreenOptions {
        let surfaceArg: String
        let includeScrollback: Bool
        let lineLimit: Int?
    }

    struct ReadScreenParseError: Error {
        let message: String
    }

    func parseReadScreenArgs(_ args: String) -> Result<ReadScreenOptions, ReadScreenParseError> {
        let tokens = args
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        var surfaceArg: String?
        var includeScrollback = false
        var lineLimit: Int?
        var idx = 0

        while idx < tokens.count {
            let token = tokens[idx]
            switch token {
            case "--scrollback":
                includeScrollback = true
                idx += 1
            case "--lines":
                guard idx + 1 < tokens.count, let parsed = Int(tokens[idx + 1]), parsed > 0 else {
                    return .failure(ReadScreenParseError(message: "ERROR: --lines must be greater than 0"))
                }
                lineLimit = parsed
                includeScrollback = true
                idx += 2
            default:
                guard surfaceArg == nil else {
                    return .failure(ReadScreenParseError(message: "ERROR: Usage: read_screen [id|idx] [--scrollback] [--lines <n>]"))
                }
                surfaceArg = token
                idx += 1
            }
        }

        return .success(
            ReadScreenOptions(
                surfaceArg: surfaceArg ?? "",
                includeScrollback: includeScrollback,
                lineLimit: lineLimit
            )
        )
    }

    func tailTerminalLines(_ text: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return text }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    func readTerminalTextBase64(surfaceArg: String, includeScrollback: Bool = false, lineLimit: Int? = nil) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmedSurfaceArg = surfaceArg.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = "ERROR: No tab selected"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            let panelId: UUID?
            if trimmedSurfaceArg.isEmpty {
                panelId = tab.focusedPanelId
            } else {
                panelId = resolveSurfaceId(from: trimmedSurfaceArg, tab: tab)
            }

            guard let panelId,
                  let terminalPanel = tab.terminalPanel(for: panelId) else {
                result = "ERROR: Terminal surface not found"
                return
            }

            result = readTerminalTextBase64(
                terminalPanel: terminalPanel,
                includeScrollback: includeScrollback,
                lineLimit: lineLimit
            )
        }
        return result
    }

    func readScreenText(_ args: String) -> String {
        let options: ReadScreenOptions
        switch parseReadScreenArgs(args) {
        case .success(let parsed):
            options = parsed
        case .failure(let error):
            return error.message
        }

        let response = readTerminalTextBase64(
            surfaceArg: options.surfaceArg,
            includeScrollback: options.includeScrollback,
            lineLimit: options.lineLimit
        )
        guard response.hasPrefix("OK ") else { return response }

        let payload = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload.isEmpty {
            return ""
        }

        guard let data = Data(base64Encoded: payload) else {
            return "ERROR: Failed to decode terminal text"
        }
        return String(decoding: data, as: UTF8.self)
    }

    func helpText() -> String {
        var text = """
        Hierarchy: Workspace (sidebar tab) > Pane (split region) > Surface (nested tab) > Panel (terminal/browser)

        Available commands:
          ping                        - Check if server is running
          auth <password>             - Authenticate this connection (required in password mode)
          list_workspaces             - List all workspaces with IDs
          new_workspace               - Create a new workspace
          select_workspace <id|ref>   - Select workspace by ID or ref (e.g. workspace:1)
          current_workspace           - Get current workspace ID
          close_workspace <id|ref>    - Close workspace by ID or ref (e.g. workspace:1)

        Split & surface commands:
          new_split <direction> [panel]   - Split panel (left/right/up/down)
          drag_surface_to_split <id|idx> <direction> - Move surface into a new split (drag-to-edge)
          new_pane [--type=terminal|browser] [--direction=left|right|up|down] [--url=...]
          new_surface [--type=terminal|browser] [--pane=<pane-id|ref>] [--url=...]
          list_surfaces [workspace]       - List surfaces for workspace (current if omitted)
          list_panes                      - List all panes with IDs
          list_pane_surfaces [--pane=<pane-id|ref>] - List surfaces in pane
          focus_surface <id|ref>          - Focus surface by ID or ref (e.g. surface:1)
          focus_pane <pane-id|ref>        - Focus a pane by ID or ref (e.g. pane:1)
          focus_surface_by_panel <panel_id> - Focus surface by panel ID
          close_surface [id|ref]          - Close surface (collapse split)
          refresh_surfaces                - Force refresh all terminals
          surface_health [workspace]      - Check view health of all surfaces

        Input commands:
          send <text>                     - Send text to current terminal
          send_key <key>                  - Send special key (ctrl-c, ctrl-d, enter, tab, escape)
          send_surface <id|idx> <text>    - Send text to a specific terminal
          send_key_surface <id|idx> <key> - Send special key to a specific terminal
          read_screen [id|idx] [--scrollback] [--lines N] - Read terminal text (plain text)

        Notification commands:
          notify <title>|<subtitle>|<body>   - Notify focused panel
          notify_surface <id|idx> <payload>  - Notify a specific surface
          notify_target <workspace_id> <surface_id> <payload> - Notify by workspace+surface
          list_notifications              - List all notifications
          clear_notifications             - Clear all notifications
          set_app_focus <active|inactive|clear> - Override app focus state
          simulate_app_active             - Trigger app active handler
          set_status <key> <value> [--icon=X] [--color=#hex] [--tab=X] - Set a status entry
          clear_status <key> [--tab=X] - Remove a status entry
          list_status [--tab=X]   - List all status entries
          log [--level=X] [--source=X] [--tab=X] -- <message> - Append a log entry
          clear_log [--tab=X]     - Clear log entries
          list_log [--limit=N] [--tab=X] - List log entries
          set_progress <0.0-1.0> [--label=X] [--tab=X] - Set progress bar
          clear_progress [--tab=X] - Clear progress bar
          report_git_branch <branch> [--status=dirty] [--files=N] [--tab=X] [--panel=Y] - Report git branch
          clear_git_branch [--tab=X] [--panel=Y] - Clear git branch
          report_ports <port1> [port2...] [--tab=X] [--panel=Y] - Report listening ports
          report_tty <tty_name> [--tab=X] [--panel=Y] - Register TTY for batched port scanning
          ports_kick [--tab=X] [--panel=Y] - Request batched port scan for panel
          report_pwd <path> [--tab=X] [--panel=Y] - Report current working directory
          clear_ports [--tab=X] [--panel=Y] - Clear listening ports
          sidebar_state [--tab=X] - Dump sidebar metadata
          reset_sidebar [--tab=X] - Clear sidebar metadata

        Browser commands:
          open_browser [url]              - Create browser panel with optional URL
          navigate <panel_id> <url>       - Navigate browser to URL
          browser_back <panel_id>         - Go back in browser history
          browser_forward <panel_id>      - Go forward in browser history
          browser_reload <panel_id>       - Reload browser page
          get_url <panel_id>              - Get current URL of browser panel
          focus_webview <panel_id>        - Move keyboard focus into the WKWebView (for tests)
          is_webview_focused <panel_id>   - Return true/false if WKWebView is first responder

          help                            - Show this help
        """
#if DEBUG
        text += """

          focus_notification <workspace|idx> [surface|idx] - Focus via notification flow
          flash_count <id|idx>            - Read flash count for a panel
          reset_flash_counts              - Reset flash counters
          screenshot [label]              - Capture window screenshot
          set_shortcut <name> <combo|clear> - Set a keyboard shortcut (test-only)
          simulate_shortcut <combo>       - Simulate a keyDown shortcut (test-only)
          simulate_type <text>            - Insert text into the current first responder (test-only)
          simulate_file_drop <id|idx> <path[|path...]> - Simulate dropping file path(s) on terminal (test-only)
          seed_drag_pasteboard_fileurl    - Seed NSDrag pasteboard with public.file-url (test-only)
          seed_drag_pasteboard_tabtransfer - Seed NSDrag pasteboard with tab transfer type (test-only)
          seed_drag_pasteboard_sidebar_reorder - Seed NSDrag pasteboard with sidebar reorder type (test-only)
          seed_drag_pasteboard_types <types> - Seed NSDrag pasteboard with comma/space-separated types (fileurl, tabtransfer, sidebarreorder, or raw UTI)
          clear_drag_pasteboard           - Clear NSDrag pasteboard (test-only)
          drop_hit_test <x 0-1> <y 0-1> - Hit-test file-drop overlay at normalised coords (test-only)
          drag_hit_chain <x 0-1> <y 0-1> - Return hit-view chain at normalised coords (test-only)
          overlay_hit_gate <event|none> - Return true/false if file-drop overlay would capture hit-testing for event type (test-only)
          overlay_drop_gate [external|local] - Return true/false if file-drop overlay would capture drag destination routing (test-only)
          portal_hit_gate <event|none> - Return true/false if terminal portal should pass hit-testing to SwiftUI drag targets (test-only)
          sidebar_overlay_gate [active|inactive] - Return true/false if sidebar outside-drop overlay would capture (test-only)
          terminal_drop_overlay_probe [deferred|direct] - Trigger focused terminal drop-overlay show path and report animation counts (test-only)
          activate_app                    - Bring app + main window to front (test-only)
          is_terminal_focused <id|idx>    - Return true/false if terminal surface is first responder (test-only)
          read_terminal_text [id|idx]     - Read visible terminal text (base64, test-only)
          render_stats [id|idx]           - Read terminal render stats (draw counters, test-only)
          layout_debug                    - Dump bonsplit layout + selected panel bounds (test-only)
          bonsplit_underflow_count        - Count bonsplit arranged-subview underflow events (test-only)
          reset_bonsplit_underflow_count  - Reset bonsplit underflow counter (test-only)
          empty_panel_count               - Count EmptyPanelView appearances (test-only)
          reset_empty_panel_count         - Reset EmptyPanelView appearance count (test-only)
        """
#endif
        return text
    }

#if DEBUG
    func debugShortcutName(for action: KeyboardShortcutSettings.Action) -> String {
        let snakeCase = action.rawValue.replacingOccurrences(
            of: "([a-z0-9])([A-Z])",
            with: "$1_$2",
            options: .regularExpression
        )
        return snakeCase.lowercased()
    }

    func debugShortcutAction(named rawName: String) -> KeyboardShortcutSettings.Action? {
        let normalized = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")

        for action in KeyboardShortcutSettings.Action.allCases {
            let snakeCaseName = debugShortcutName(for: action)
            if normalized == snakeCaseName || normalized == snakeCaseName.replacingOccurrences(of: "_", with: "") {
                return action
            }
        }
        return nil
    }

    func debugShortcutSupportedNames() -> String {
        KeyboardShortcutSettings.Action.allCases
            .map(debugShortcutName(for:))
            .sorted()
            .joined(separator: ", ")
    }

    func setShortcut(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return "ERROR: Usage: set_shortcut <name> <combo|clear>"
        }

        let name = parts[0]
        let combo = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

        guard let action = debugShortcutAction(named: name) else {
            return "ERROR: Unknown shortcut name. Supported: \(debugShortcutSupportedNames())"
        }

        if combo.lowercased() == "clear" || combo.lowercased() == "default" || combo.lowercased() == "reset" {
            UserDefaults.standard.removeObject(forKey: action.defaultsKey)
            return "OK"
        }

        guard let parsed = parseShortcutCombo(combo) else {
            return "ERROR: Invalid combo. Example: cmd+ctrl+h"
        }

        let shortcut = StoredShortcut(
            key: parsed.storedKey,
            command: parsed.modifierFlags.contains(.command),
            shift: parsed.modifierFlags.contains(.shift),
            option: parsed.modifierFlags.contains(.option),
            control: parsed.modifierFlags.contains(.control)
        )
        guard let data = try? JSONEncoder().encode(shortcut) else {
            return "ERROR: Failed to encode shortcut"
        }
        UserDefaults.standard.set(data, forKey: action.defaultsKey)
        return "OK"
    }

	    func simulateShortcut(_ args: String) -> String {
	        let combo = args.trimmingCharacters(in: .whitespacesAndNewlines)
	        guard !combo.isEmpty else {
	            return "ERROR: Usage: simulate_shortcut <combo>"
	        }
	        guard let parsed = parseShortcutCombo(combo) else {
	            return "ERROR: Invalid combo. Example: cmd+ctrl+h"
	        }

	        // Stamp at socket-handler arrival so event.timestamp includes any wait
	        // before the main-thread event dispatch.
	        let requestTimestamp = ProcessInfo.processInfo.systemUptime
	
	        var result = "ERROR: Failed to create event"
	        DispatchQueue.main.sync {
	            // Prefer the current active-tab-manager window so shortcut simulation stays
	            // scoped to the intended window even when NSApp.keyWindow is stale.
	            let targetWindow: NSWindow? = {
	                if let activeTabManager = self.tabManager,
	                   let windowId = AppDelegate.shared?.windowId(for: activeTabManager),
	                   let window = AppDelegate.shared?.mainWindow(for: windowId) {
	                    return window
	                }
	                return NSApp.keyWindow
	                    ?? NSApp.mainWindow
	                    ?? NSApp.windows.first(where: { $0.isVisible })
	                    ?? NSApp.windows.first
	            }()
	            if let targetWindow {
	                NSApp.activate(ignoringOtherApps: true)
	                targetWindow.makeKeyAndOrderFront(nil)
	            }
	            let windowNumber = targetWindow?.windowNumber ?? 0
	            guard let keyDownEvent = NSEvent.keyEvent(
	                with: .keyDown,
	                location: .zero,
	                modifierFlags: parsed.modifierFlags,
	                timestamp: requestTimestamp,
	                windowNumber: windowNumber,
	                context: nil,
	                characters: parsed.characters,
	                charactersIgnoringModifiers: parsed.charactersIgnoringModifiers,
	                isARepeat: false,
	                keyCode: parsed.keyCode
	            ) else {
	                result = "ERROR: NSEvent.keyEvent returned nil"
	                return
	            }
	            let keyUpEvent = NSEvent.keyEvent(
	                with: .keyUp,
	                location: .zero,
	                modifierFlags: parsed.modifierFlags,
	                timestamp: requestTimestamp + 0.0001,
	                windowNumber: windowNumber,
	                context: nil,
	                characters: parsed.characters,
	                charactersIgnoringModifiers: parsed.charactersIgnoringModifiers,
	                isARepeat: false,
	                keyCode: parsed.keyCode
	            )
	            // Socket-driven shortcut simulation should reuse the exact same matching logic as the
	            // app-level shortcut monitor (so tests are hermetic), while still falling back to the
	            // normal responder chain for plain typing.
	            if let delegate = AppDelegate.shared, delegate.debugHandleCustomShortcut(event: keyDownEvent) {
	                result = "OK"
	                return
	            }
	            NSApp.sendEvent(keyDownEvent)
	            if let keyUpEvent {
	                NSApp.sendEvent(keyUpEvent)
	            }
	            result = "OK"
	        }
	        return result
	    }

    func activateApp() -> String {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.unhide(nil)
            let hasMainTerminalWindow = NSApp.windows.contains { window in
                guard let raw = window.identifier?.rawValue else { return false }
                return raw == "term-mesh.main" || raw.hasPrefix("term-mesh.main.")
            }

            if !hasMainTerminalWindow {
                AppDelegate.shared?.openNewMainWindow(nil)
            }

            if let window = NSApp.mainWindow
                ?? NSApp.keyWindow
                ?? NSApp.windows.first(where: { win in
                    guard let raw = win.identifier?.rawValue else { return false }
                    return raw == "term-mesh.main" || raw.hasPrefix("term-mesh.main.")
                })
                ?? NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return "OK"
    }

    func simulateType(_ args: String) -> String {
        let raw = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return "ERROR: Usage: simulate_type <text>"
        }

        // Socket commands are line-based; allow callers to express control chars with backslash escapes.
        let text = unescapeSocketText(raw)

	        var result = "ERROR: No window"
	        DispatchQueue.main.sync {
	            // Like simulate_shortcut, prefer a visible window so debug automation doesn't
	            // fail during key window transitions.
	            guard let window = NSApp.keyWindow
	                ?? NSApp.mainWindow
	                ?? NSApp.windows.first(where: { $0.isVisible })
	                ?? NSApp.windows.first else { return }
	            NSApp.activate(ignoringOtherApps: true)
	            window.makeKeyAndOrderFront(nil)
	            guard let fr = window.firstResponder else {
	                result = "ERROR: No first responder"
	                return
	            }

            if let client = fr as? NSTextInputClient {
                client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                result = "OK"
                return
            }

            // Fall back to the responder chain insertText action.
            (fr as? NSResponder)?.insertText(text)
            result = "OK"
        }
        return result
    }


    /// Return the hit-test chain at normalized (0-1) coordinates in the main window's
    /// content area. Used by regression tests to detect root-level drag destinations
    /// shadowing pane-local Bonsplit drop targets.
    func dragHitChain(_ args: String) -> String {
        let parts = args.split(separator: " ").map(String.init)
        guard parts.count == 2,
              let nx = Double(parts[0]), let ny = Double(parts[1]),
              (0...1).contains(nx), (0...1).contains(ny) else {
            return "ERROR: Usage: drag_hit_chain <x 0-1> <y 0-1>"
        }

        var result = "ERROR: No window"
        DispatchQueue.main.sync {
            guard let window = NSApp.mainWindow
                ?? NSApp.keyWindow
                ?? NSApp.windows.first(where: { win in
                    guard let raw = win.identifier?.rawValue else { return false }
                    return raw == "term-mesh.main" || raw.hasPrefix("term-mesh.main.")
                }),
                  let contentView = window.contentView,
                  let themeFrame = contentView.superview else { return }

            let pointInTheme = NSPoint(
                x: contentView.frame.minX + (contentView.bounds.width * nx),
                y: contentView.frame.maxY - (contentView.bounds.height * ny)
            )

            let overlay = objc_getAssociatedObject(window, &fileDropOverlayKey) as? NSView
            if let overlay { overlay.isHidden = true }
            defer { overlay?.isHidden = false }

            guard let hit = themeFrame.hitTest(pointInTheme) else {
                result = "none"
                return
            }

            var chain: [String] = []
            var current: NSView? = hit
            var depth = 0
            while let view = current, depth < 8 {
                chain.append(debugDragHitViewDescriptor(view))
                current = view.superview
                depth += 1
            }
            result = chain.joined(separator: "->")
        }
        return result
    }

    func debugDragHitViewDescriptor(_ view: NSView) -> String {
        let className = String(describing: type(of: view))
        let pointer = String(describing: Unmanaged.passUnretained(view).toOpaque())
        let types = view.registeredDraggedTypes
        let renderedTypes: String
        if types.isEmpty {
            renderedTypes = "-"
        } else {
            let raw = types.map(\.rawValue)
            renderedTypes = raw.count <= 4
                ? raw.joined(separator: ",")
                : raw.prefix(4).joined(separator: ",") + ",+\(raw.count - 4)"
        }
        return "\(className)@\(pointer){dragTypes=\(renderedTypes)}"
    }

    func unescapeSocketText(_ input: String) -> String {
        var out = ""
        var escaping = false
        for ch in input {
            if escaping {
                switch ch {
                case "n":
                    out.append("\n")
                case "r":
                    out.append("\r")
                case "t":
                    out.append("\t")
                case "\\":
                    out.append("\\")
                default:
                    out.append("\\")
                    out.append(ch)
                }
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        if escaping {
            out.append("\\")
        }
        return out
    }

    static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var r = start
        var hops = 0
        while let cur = r, hops < 64 {
            if cur === target { return true }
            r = cur.nextResponder
            hops += 1
        }
        return false
    }

    func isTerminalFocused(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: is_terminal_focused <panel_id|idx>" }

        var result = "false"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "false"
                return
            }

            guard let panelId = resolveSurfaceId(from: panelArg, tab: tab),
                  let terminalPanel = tab.terminalPanel(for: panelId) else {
                result = "false"
                return
            }
            result = terminalPanel.hostedView.isSurfaceViewFirstResponder() ? "true" : "false"
        }
        return result
    }

    func readTerminalText(_ args: String) -> String {
        readTerminalTextBase64(surfaceArg: args)
    }

    struct RenderStatsResponse: Codable {
        let panelId: String
        let drawCount: Int
        let lastDrawTime: Double
        let metalDrawableCount: Int
        let metalLastDrawableTime: Double
        let presentCount: Int
        let lastPresentTime: Double
        let layerClass: String
        let layerContentsKey: String
        let inWindow: Bool
        let windowIsKey: Bool
        let windowOcclusionVisible: Bool
        let appIsActive: Bool
        let isActive: Bool
        let desiredFocus: Bool
        let isFirstResponder: Bool
    }

    func renderStats(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)

        var result = "ERROR: No tab selected"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            let panelId: UUID?
            if panelArg.isEmpty {
                panelId = tab.focusedPanelId
            } else {
                panelId = resolveSurfaceId(from: panelArg, tab: tab)
            }

            guard let panelId,
                  let terminalPanel = tab.terminalPanel(for: panelId) else {
                result = "ERROR: Terminal surface not found"
                return
            }

            let stats = terminalPanel.hostedView.debugRenderStats()
            let payload = RenderStatsResponse(
                panelId: panelId.uuidString,
                drawCount: stats.drawCount,
                lastDrawTime: stats.lastDrawTime,
                metalDrawableCount: stats.metalDrawableCount,
                metalLastDrawableTime: stats.metalLastDrawableTime,
                presentCount: stats.presentCount,
                lastPresentTime: stats.lastPresentTime,
                layerClass: stats.layerClass,
                layerContentsKey: stats.layerContentsKey,
                inWindow: stats.inWindow,
                windowIsKey: stats.windowIsKey,
                windowOcclusionVisible: stats.windowOcclusionVisible,
                appIsActive: stats.appIsActive,
                isActive: stats.isActive,
                desiredFocus: stats.desiredFocus,
                isFirstResponder: stats.isFirstResponder
            )

            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(payload),
                  let json = String(data: data, encoding: .utf8) else {
                result = "ERROR: Failed to encode render_stats"
                return
            }

            result = "OK \(json)"
        }

        return result
    }

    struct ParsedShortcutCombo {
        let storedKey: String
        let keyCode: UInt16
        let modifierFlags: NSEvent.ModifierFlags
        let characters: String
        let charactersIgnoringModifiers: String
    }

    func parseShortcutCombo(_ combo: String) -> ParsedShortcutCombo? {
        let raw = combo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let parts = raw
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        var flags: NSEvent.ModifierFlags = []
        var keyToken: String?

        for part in parts {
            let lower = part.lowercased()
            switch lower {
            case "cmd", "command", "super":
                flags.insert(.command)
            case "ctrl", "control":
                flags.insert(.control)
            case "opt", "option", "alt":
                flags.insert(.option)
            case "shift":
                flags.insert(.shift)
            default:
                // Treat as the key component.
                if keyToken == nil {
                    keyToken = part
                } else {
                    // Multiple non-modifier tokens is ambiguous.
                    return nil
                }
            }
        }

        guard var keyToken else { return nil }
        keyToken = keyToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyToken.isEmpty else { return nil }

        // Normalize a few named keys.
        let storedKey: String
        let keyCode: UInt16
        let charactersIgnoringModifiers: String

        switch keyToken.lowercased() {
        case "esc", "escape":
            storedKey = "\u{1b}"
            keyCode = UInt16(kVK_Escape)
            charactersIgnoringModifiers = storedKey
        case "left":
            storedKey = "←"
            keyCode = 123
            charactersIgnoringModifiers = storedKey
        case "right":
            storedKey = "→"
            keyCode = 124
            charactersIgnoringModifiers = storedKey
        case "down":
            storedKey = "↓"
            keyCode = 125
            charactersIgnoringModifiers = storedKey
        case "up":
            storedKey = "↑"
            keyCode = 126
            charactersIgnoringModifiers = storedKey
        case "enter", "return":
            storedKey = "\r"
            keyCode = UInt16(kVK_Return)
            charactersIgnoringModifiers = storedKey
        case "backspace", "delete", "del":
            storedKey = "\u{7f}"
            keyCode = UInt16(kVK_Delete)
            charactersIgnoringModifiers = storedKey
        default:
            let key = keyToken.lowercased()
            guard let code = keyCodeForShortcutKey(key) else { return nil }
            storedKey = key
            keyCode = code

            // Replicate a common system behavior: Ctrl+letter yields a control character in
            // charactersIgnoringModifiers (e.g. Ctrl+H => backspace). This is important for
            // testing keyCode fallback matching.
            if flags.contains(.control),
               key.count == 1,
               let scalar = key.unicodeScalars.first,
               scalar.isASCII,
               scalar.value >= 97, scalar.value <= 122 { // a-z
                let upper = scalar.value - 32
                let controlValue = upper - 64 // 'A' => 1
                charactersIgnoringModifiers = String(UnicodeScalar(controlValue)!)
            } else {
                charactersIgnoringModifiers = storedKey
            }
        }

        // For our shortcut matcher, characters aren't important beyond exercising edge cases.
        let chars = charactersIgnoringModifiers

        return ParsedShortcutCombo(
            storedKey: storedKey,
            keyCode: keyCode,
            modifierFlags: flags,
            characters: chars,
            charactersIgnoringModifiers: charactersIgnoringModifiers
        )
    }

    func keyCodeForShortcutKey(_ key: String) -> UInt16? {
        // Matches macOS ANSI key codes for common printable keys and a few named specials.
        switch key {
        case "a": return 0   // kVK_ANSI_A
        case "s": return 1   // kVK_ANSI_S
        case "d": return 2   // kVK_ANSI_D
        case "f": return 3   // kVK_ANSI_F
        case "h": return 4   // kVK_ANSI_H
        case "g": return 5   // kVK_ANSI_G
        case "z": return 6   // kVK_ANSI_Z
        case "x": return 7   // kVK_ANSI_X
        case "c": return 8   // kVK_ANSI_C
        case "v": return 9   // kVK_ANSI_V
        case "b": return 11  // kVK_ANSI_B
        case "q": return 12  // kVK_ANSI_Q
        case "w": return 13  // kVK_ANSI_W
        case "e": return 14  // kVK_ANSI_E
        case "r": return 15  // kVK_ANSI_R
        case "y": return 16  // kVK_ANSI_Y
        case "t": return 17  // kVK_ANSI_T
        case "1": return 18  // kVK_ANSI_1
        case "2": return 19  // kVK_ANSI_2
        case "3": return 20  // kVK_ANSI_3
        case "4": return 21  // kVK_ANSI_4
        case "6": return 22  // kVK_ANSI_6
        case "5": return 23  // kVK_ANSI_5
        case "=": return 24  // kVK_ANSI_Equal
        case "9": return 25  // kVK_ANSI_9
        case "7": return 26  // kVK_ANSI_7
        case "-": return 27  // kVK_ANSI_Minus
        case "8": return 28  // kVK_ANSI_8
        case "0": return 29  // kVK_ANSI_0
        case "]": return 30  // kVK_ANSI_RightBracket
        case "o": return 31  // kVK_ANSI_O
        case "u": return 32  // kVK_ANSI_U
        case "[": return 33  // kVK_ANSI_LeftBracket
        case "i": return 34  // kVK_ANSI_I
        case "p": return 35  // kVK_ANSI_P
        case "l": return 37  // kVK_ANSI_L
        case "j": return 38  // kVK_ANSI_J
        case "'": return 39  // kVK_ANSI_Quote
        case "k": return 40  // kVK_ANSI_K
        case ";": return 41  // kVK_ANSI_Semicolon
        case "\\": return 42 // kVK_ANSI_Backslash
        case ",": return 43  // kVK_ANSI_Comma
        case "/": return 44  // kVK_ANSI_Slash
        case "n": return 45  // kVK_ANSI_N
        case "m": return 46  // kVK_ANSI_M
        case ".": return 47  // kVK_ANSI_Period
        case "`": return 50  // kVK_ANSI_Grave
        default:
            return nil
        }
    }
#endif

    #if !DEBUG
    static func responderChainContains(_ start: NSResponder?, target: NSResponder) -> Bool {
        var responder = start
        var hops = 0
        while let current = responder, hops < 64 {
            if current === target { return true }
            responder = current.nextResponder
            hops += 1
        }
        return false
    }
    #endif

    func listWindows() -> String {
        let summaries = v2MainSync { AppDelegate.shared?.listMainWindowSummaries() } ?? []
        guard !summaries.isEmpty else { return "No windows" }

        let lines = summaries.enumerated().map { idx, item in
            let selected = item.isKeyWindow ? "*" : " "
            let selectedWs = item.selectedWorkspaceId?.uuidString ?? "none"
            return "\(selected) \(idx): \(item.windowId.uuidString) selected_workspace=\(selectedWs) workspaces=\(item.workspaceCount)"
        }
        return lines.joined(separator: "\n")
    }

    func currentWindow() -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        guard let windowId = v2ResolveWindowId(tabManager: tabManager) else { return "ERROR: No active window" }
        return windowId.uuidString
    }

    func focusWindow(_ arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let windowId = UUID(uuidString: trimmed) else { return "ERROR: Invalid window id" }

        let ok = v2MainSync { AppDelegate.shared?.focusMainWindow(windowId: windowId) ?? false }
        guard ok else { return "ERROR: Window not found" }

        if let tm = v2MainSync({ AppDelegate.shared?.tabManagerFor(windowId: windowId) }) {
            setActiveTabManager(tm)
        }
        return "OK"
    }

    func newWindow() -> String {
        guard let windowId = v2MainSync({ AppDelegate.shared?.createMainWindow() }) else {
            return "ERROR: Failed to create window"
        }
        if socketCommandAllowsInAppFocusMutations(),
           let tm = v2MainSync({ AppDelegate.shared?.tabManagerFor(windowId: windowId) }) {
            setActiveTabManager(tm)
        }
        return "OK \(windowId.uuidString)"
    }

    func closeWindow(_ arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let windowId = UUID(uuidString: trimmed) else { return "ERROR: Invalid window id" }
        let ok = v2MainSync { AppDelegate.shared?.closeMainWindow(windowId: windowId) ?? false }
        return ok ? "OK" : "ERROR: Window not found"
    }

    func moveWorkspaceToWindow(_ args: String) -> String {
        let parts = args.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return "ERROR: Usage move_workspace_to_window <workspace_id> <window_id>" }
        guard let wsId = UUID(uuidString: parts[0]) else { return "ERROR: Invalid workspace id" }
        guard let windowId = UUID(uuidString: parts[1]) else { return "ERROR: Invalid window id" }

        var ok = false
        let focus = socketCommandAllowsInAppFocusMutations()
        v2MainSync {
            guard let srcTM = AppDelegate.shared?.tabManagerFor(tabId: wsId),
                  let dstTM = AppDelegate.shared?.tabManagerFor(windowId: windowId),
                  let ws = srcTM.detachWorkspace(tabId: wsId) else {
                ok = false
                return
            }
            dstTM.attachWorkspace(ws, select: focus)
            if focus {
                _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
                setActiveTabManager(dstTM)
            }
            ok = true
        }

        return ok ? "OK" : "ERROR: Move failed"
    }

    func listWorkspaces() -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var result: String = ""
        DispatchQueue.main.sync {
            let tabs = tabManager.tabs.map { tab in
                let selected = tab.id == tabManager.selectedTabId ? "*" : " "
                let ref = v2EnsureHandleRef(kind: .workspace, uuid: tab.id)
                return "\(selected) \(ref): \(tab.id.uuidString) \(tab.title)"
            }
            result = tabs.joined(separator: "\n")
        }
        return result.isEmpty ? "No workspaces" : result
    }

    func newWorkspace() -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var newTabId: UUID?
        let focus = socketCommandAllowsInAppFocusMutations()
        #if DEBUG
        let startedAt = ProcessInfo.processInfo.systemUptime
        #endif
        DispatchQueue.main.sync {
            let workspace = tabManager.addTab(select: focus)
            newTabId = workspace.id
        }
        #if DEBUG
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0
        dlog(
            "socket.new_workspace focus=\(focus ? 1 : 0) ms=\(String(format: "%.2f", elapsedMs)) main=\(Thread.isMainThread ? 1 : 0)"
        )
        #endif
        return "OK \(newTabId?.uuidString ?? "unknown")"
    }

    func newSplit(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        guard !parts.isEmpty else {
            return "ERROR: Invalid direction. Use left, right, up, or down."
        }

        let directionArg = parts[0]
        let panelArg = parts.count > 1 ? parts[1] : ""

        guard let direction = parseSplitDirection(directionArg) else {
            return "ERROR: Invalid direction. Use left, right, up, or down."
        }

        var result = "ERROR: Failed to create split"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            // If panel arg provided, resolve it; otherwise use focused panel
            let surfaceId: UUID?
            if !panelArg.isEmpty {
                surfaceId = resolveSurfaceId(from: panelArg, tab: tab)
                if surfaceId == nil {
                    result = "ERROR: Panel not found"
                    return
                }
            } else {
                surfaceId = tab.focusedPanelId
            }

            guard let targetSurface = surfaceId else {
                result = "ERROR: No surface to split"
                return
            }

            if let newPanelId = tabManager.newSplit(
                tabId: tabId,
                surfaceId: targetSurface,
                direction: direction,
                focus: socketCommandAllowsInAppFocusMutations()
            ) {
                result = "OK \(newPanelId.uuidString)"
            }
        }
        return result
    }

    func listSurfaces(_ tabArg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        var result = ""
        DispatchQueue.main.sync {
            guard let tab = resolveTab(from: tabArg, tabManager: tabManager) else {
                result = "ERROR: Tab not found"
                return
            }
            let panels = orderedPanels(in: tab)
            let focusedId = tab.focusedPanelId
            let lines = panels.map { panel in
                let selected = panel.id == focusedId ? "*" : " "
                let ref = v2EnsureHandleRef(kind: .surface, uuid: panel.id)
                return "\(selected) \(ref): \(panel.id.uuidString)"
            }
            result = lines.isEmpty ? "No surfaces" : lines.joined(separator: "\n")
        }
        return result
    }

    func focusSurface(_ arg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Missing panel id or index" }

        var success = false
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            if let uuid = UUID(uuidString: trimmed),
               tab.panels[uuid] != nil {
                guard tab.surfaceIdFromPanelId(uuid) != nil else { return }
                tabManager.focusSurface(tabId: tab.id, surfaceId: uuid)
                success = true
                return
            }

            if let uuid = v2ResolveHandleRef(trimmed),
               tab.panels[uuid] != nil {
                guard tab.surfaceIdFromPanelId(uuid) != nil else { return }
                tabManager.focusSurface(tabId: tab.id, surfaceId: uuid)
                success = true
            }
        }

        return success ? "OK" : "ERROR: Panel not found"
    }

    func notifyCurrent(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var result = "OK"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId else {
                result = "ERROR: No tab selected"
                return
            }
            let surfaceId = tabManager.focusedSurfaceId(for: tabId)
            let (title, subtitle, body) = parseNotificationPayload(args)
            notifications.addNotification(
                tabId: tabId,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
        }
        return result
    }

    func notifySurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Missing surface id or index" }

        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let surfaceArg = parts[0]
        let payload = parts.count > 1 ? parts[1] : ""

        var result = "OK"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "ERROR: No tab selected"
                return
            }
            guard let surfaceId = resolveSurfaceId(from: surfaceArg, tab: tab) else {
                result = "ERROR: Surface not found"
                return
            }
            let (title, subtitle, body) = parseNotificationPayload(payload)
            notifications.addNotification(
                tabId: tabId,
                surfaceId: surfaceId,
                title: title,
                subtitle: subtitle,
                body: body
            )
        }
        return result
    }

    func notifyTarget(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Usage: notify_target <workspace_id> <surface_id> <title>|<subtitle>|<body>" }

        let parts = trimmed.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return "ERROR: Usage: notify_target <workspace_id> <surface_id> <title>|<subtitle>|<body>" }

        let tabArg = parts[0]
        let panelArg = parts[1]
        let payload = parts.count > 2 ? parts[2] : ""

        var result = "OK"
        DispatchQueue.main.sync {
            guard let tab = resolveTab(from: tabArg, tabManager: tabManager) else {
                result = "ERROR: Tab not found"
                return
            }
            guard let panelId = UUID(uuidString: panelArg),
                  tab.panels[panelId] != nil else {
                result = "ERROR: Panel not found"
                return
            }
            let (title, subtitle, body) = parseNotificationPayload(payload)
            notifications.addNotification(
                tabId: tab.id,
                surfaceId: panelId,
                title: title,
                subtitle: subtitle,
                body: body
            )
        }
        return result
    }

    func listNotifications() -> String {
        var result = ""
        DispatchQueue.main.sync {
            let lines = notifications.notifications.enumerated().map { index, notification in
                let surfaceText = notification.surfaceId?.uuidString ?? "none"
                let readText = notification.isRead ? "read" : "unread"
                return "\(index):\(notification.id.uuidString)|\(notification.tabId.uuidString)|\(surfaceText)|\(readText)|\(notification.title)|\(notification.subtitle)|\(notification.body)"
            }
            result = lines.joined(separator: "\n")
        }
        return result.isEmpty ? "No notifications" : result
    }

    func clearNotifications() -> String {
        DispatchQueue.main.async {
            self.notifications.clearAll()
        }
        return "OK"
    }

    func setAppFocusOverride(_ arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "active", "1", "true":
            AppFocusState.overrideIsFocused = true
            return "OK"
        case "inactive", "0", "false":
            AppFocusState.overrideIsFocused = false
            return "OK"
        case "clear", "none", "":
            AppFocusState.overrideIsFocused = nil
            return "OK"
        default:
            return "ERROR: Expected active, inactive, or clear"
        }
    }

    func simulateAppDidBecomeActive() -> String {
        DispatchQueue.main.async {
            AppDelegate.shared?.applicationDidBecomeActive(
                Notification(name: NSApplication.didBecomeActiveNotification)
            )
        }
        return "OK"
    }

#if DEBUG
    func focusFromNotification(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        let tabArg = parts.first ?? ""
        let surfaceArg = parts.count > 1 ? parts[1] : ""

        var result = "OK"
        DispatchQueue.main.sync {
            guard let tab = resolveTab(from: tabArg, tabManager: tabManager) else {
                result = "ERROR: Tab not found"
                return
            }
            let surfaceId = surfaceArg.isEmpty ? nil : resolveSurfaceId(from: surfaceArg, tab: tab)
            if !surfaceArg.isEmpty && surfaceId == nil {
                result = "ERROR: Surface not found"
                return
            }
            tabManager.focusTabFromNotification(tab.id, surfaceId: surfaceId)
        }
        return result
    }

    func flashCount(_ args: String) -> String {
        guard let tabManager else { return "ERROR: TabManager not available" }
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "ERROR: Missing surface id or index" }

        var result = "ERROR: Surface not found"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "ERROR: No tab selected"
                return
            }
            guard let surfaceId = resolveSurfaceId(from: trimmed, tab: tab) else {
                result = "ERROR: Surface not found"
                return
            }
            let count = GhosttySurfaceScrollView.flashCount(for: surfaceId)
            result = "OK \(count)"
        }
        return result
    }

    func resetFlashCounts() -> String {
        DispatchQueue.main.async {
            GhosttySurfaceScrollView.resetFlashCounts()
        }
        return "OK"
    }

#endif

    func parseSplitDirection(_ value: String) -> SplitDirection? {
        switch value.lowercased() {
        case "left", "l":
            return .left
        case "right", "r":
            return .right
        case "up", "u":
            return .up
        case "down", "d":
            return .down
        default:
            return nil
        }
    }

    func resolveTab(from arg: String, tabManager: TabManager) -> Tab? {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard let selected = tabManager.selectedTabId else { return nil }
            return tabManager.tabs.first(where: { $0.id == selected })
        }

        if let uuid = UUID(uuidString: trimmed) {
            return tabManager.tabs.first(where: { $0.id == uuid })
        }

        if let uuid = v2ResolveHandleRef(trimmed) {
            return tabManager.tabs.first(where: { $0.id == uuid })
        }

        return nil
    }

    func orderedPanels(in tab: Workspace) -> [any Panel] {
        // Use bonsplit's tab ordering as the source of truth. This avoids relying on
        // Dictionary iteration order, and prevents indexing into panels that aren't
        // actually present in bonsplit anymore.
        let orderedTabIds = tab.bonsplitController.allTabIds
        var result: [any Panel] = []
        var seen = Set<UUID>()

        for tabId in orderedTabIds {
            guard let panelId = tab.panelIdFromSurfaceId(tabId),
                  let panel = tab.panels[panelId] else { continue }
            result.append(panel)
            seen.insert(panelId)
        }

        // Defensive: include any orphaned panels in a stable order at the end.
        let orphans = tab.panels.values
            .filter { !seen.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        result.append(contentsOf: orphans)

        return result
    }

    func resolveTerminalPanel(from arg: String, tabManager: TabManager) -> TerminalPanel? {
        guard let tabId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
            return nil
        }

        if let uuid = UUID(uuidString: arg) {
            return tab.terminalPanel(for: uuid)
        }

        if let uuid = v2ResolveHandleRef(arg) {
            return tab.terminalPanel(for: uuid)
        }

        return nil
    }

    func resolveTerminalSurface(from arg: String, tabManager: TabManager, waitUpTo timeout: TimeInterval = 0.6) -> ghostty_surface_t? {
        guard let terminalPanel = resolveTerminalPanel(from: arg, tabManager: tabManager) else { return nil }
        return waitForTerminalSurface(terminalPanel, waitUpTo: timeout)
    }

    func waitForTerminalSurface(_ terminalPanel: TerminalPanel, waitUpTo timeout: TimeInterval = 0.6) -> ghostty_surface_t? {
        if let surface = terminalPanel.surface.surface { return surface }

        // This can be transient during bonsplit tree restructuring when the SwiftUI
        // view is temporarily detached and then reattached (surface creation is
        // gated on view/window/bounds). Pump the runloop briefly to allow pending
        // attach retries to execute.
        let deadline = Date().addingTimeInterval(timeout)
        while terminalPanel.surface.surface == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        return terminalPanel.surface.surface
    }

    func resolveSurface(from arg: String, tabManager: TabManager) -> ghostty_surface_t? {
        // Backwards compatibility: resolve a terminal surface by panel UUID or a stable index.
        // Use a slightly longer wait to reduce flakiness during bonsplit/layout restructures.
        return resolveTerminalSurface(from: arg, tabManager: tabManager, waitUpTo: 2.0)
    }

    func resolveSurfaceId(from arg: String, tab: Workspace) -> UUID? {
        if let uuid = UUID(uuidString: arg), tab.panels[uuid] != nil {
            return uuid
        }

        if let uuid = v2ResolveHandleRef(arg), tab.panels[uuid] != nil {
            return uuid
        }

        return nil
    }

    func parseNotificationPayload(_ args: String) -> (String, String, String) {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("Notification", "", "") }
        let parts = trimmed.split(separator: "|", maxSplits: 2).map(String.init)
        let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle = parts.count > 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let body = parts.count > 2
            ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            : (parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
        return (title.isEmpty ? "Notification" : title, subtitle, body)
    }

    func closeWorkspace(_ tabId: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let uuid: UUID
        if let directUUID = UUID(uuidString: tabId) {
            uuid = directUUID
        } else if let refUUID = v2ResolveHandleRef(tabId) {
            uuid = refUUID
        } else {
            return "ERROR: Invalid tab ID or ref"
        }

        var success = false
        DispatchQueue.main.sync {
            if let tab = tabManager.tabs.first(where: { $0.id == uuid }) {
                tabManager.closeTab(tab)
                success = true
            }
        }
        return success ? "OK" : "ERROR: Tab not found"
    }

    func selectWorkspace(_ arg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var success = false
        DispatchQueue.main.sync {
            // Try as UUID first
            if let uuid = UUID(uuidString: arg) {
                if let tab = tabManager.tabs.first(where: { $0.id == uuid }) {
                    tabManager.selectTab(tab)
                    success = true
                }
            }
            // Try as short ref (e.g. workspace:1)
            else if let uuid = v2ResolveHandleRef(arg),
                    let tab = tabManager.tabs.first(where: { $0.id == uuid }) {
                tabManager.selectTab(tab)
                success = true
            }
        }
        return success ? "OK" : "ERROR: Tab not found"
    }

    func currentWorkspace() -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var result: String = ""
        DispatchQueue.main.sync {
            if let id = tabManager.selectedTabId {
                result = id.uuidString
            }
        }
        return result.isEmpty ? "ERROR: No tab selected" : result
    }


}
