import AppKit
import Foundation
import Bonsplit
import WebKit

extension TerminalController {
    // MARK: - Browser Panel Commands

    func openBrowser(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL? = trimmed.isEmpty ? nil : URL(string: trimmed)
        let shouldFocus = socketCommandAllowsInAppFocusMutations()

        var result = "ERROR: Failed to create browser panel"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let focusedPanelId = tab.focusedPanelId else {
                return
            }

            if let browserPanelId = tab.newBrowserSplit(
                from: focusedPanelId,
                orientation: .horizontal,
                url: url,
                focus: shouldFocus
            )?.id {
                result = "OK \(browserPanelId.uuidString)"
            }
        }
        return result
    }

    func navigateBrowser(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "ERROR: Usage: navigate <panel_id> <url>" }

        let panelArg = parts[0]
        let urlStr = parts[1]

        var result = "ERROR: Panel not found or not a browser"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            browserPanel.navigateSmart(urlStr)
            result = "OK"
        }
        return result
    }

    func browserBack(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: browser_back <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            browserPanel.goBack()
            result = "OK"
        }
        return result
    }

    func browserForward(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: browser_forward <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            browserPanel.goForward()
            result = "OK"
        }
        return result
    }

    func browserReload(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: browser_reload <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            browserPanel.reload()
            result = "OK"
        }
        return result
    }

    func getUrl(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: get_url <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            result = browserPanel.currentURL?.absoluteString ?? ""
        }
        return result
    }

    func focusWebView(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: focus_webview <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            // Programmatic WebView focus should win over stale omnibar focus state, especially
            // after workspace switches where the blank-page omnibar auto-focus can re-trigger.
            browserPanel.endSuppressWebViewFocusForAddressBar()
            browserPanel.clearWebViewFocusSuppression()
            NotificationCenter.default.post(name: .browserDidBlurAddressBar, object: panelId)

            // Prevent omnibar auto-focus from immediately stealing first responder back.
            browserPanel.suppressOmnibarAutofocus(for: 1.5)

            let webView = browserPanel.webView
            guard let window = webView.window else {
                result = "ERROR: WebView is not in a window"
                return
            }
            guard !webView.isHiddenOrHasHiddenAncestor else {
                result = "ERROR: WebView is hidden"
                return
            }

            window.makeFirstResponder(webView)
            if Self.responderChainContains(window.firstResponder, target: webView) {
                // Some focus churn paths (workspace handoff / omnibar blur) can race this call.
                // Reassert on the next runloop if another responder steals focus immediately.
                DispatchQueue.main.async { [weak window, weak webView] in
                    guard let window, let webView else { return }
                    guard webView.window === window else { return }
                    if !Self.responderChainContains(window.firstResponder, target: webView) {
                        window.makeFirstResponder(webView)
                    }
                }
                result = "OK"
            } else {
                result = "ERROR: Focus did not move into web view"
            }
        }
        return result
    }

    func isWebViewFocused(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let panelArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !panelArg.isEmpty else { return "ERROR: Usage: is_webview_focused <panel_id>" }

        var result = "ERROR: Panel not found or not a browser"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let panelId = UUID(uuidString: panelArg),
                  let browserPanel = tab.browserPanel(for: panelId) else {
                return
            }

            let webView = browserPanel.webView
            guard let window = webView.window else {
                result = "false"
                return
            }
            result = Self.responderChainContains(window.firstResponder, target: webView) ? "true" : "false"
        }
        return result
    }

    // MARK: - Bonsplit Pane Commands

    func listPanes() -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var result = ""
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "ERROR: No tab selected"
                return
            }

            let paneIds = tab.bonsplitController.allPaneIds
            let focusedPaneId = tab.bonsplitController.focusedPaneId

            let lines = paneIds.map { paneId in
                let selected = paneId == focusedPaneId ? "*" : " "
                let tabCount = tab.bonsplitController.tabs(inPane: paneId).count
                let ref = v2EnsureHandleRef(kind: .pane, uuid: paneId.id)
                return "\(selected) \(ref): \(paneId) [\(tabCount) tabs]"
            }
            result = lines.isEmpty ? "No panes" : lines.joined(separator: "\n")
        }
        return result
    }

    func listPaneSurfaces(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var result = ""
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                result = "ERROR: No tab selected"
                return
            }

            // Parse --pane=<pane-id|ref> argument (UUID preferred).
            var paneArg: String?
            for part in args.split(separator: " ") {
                if part.hasPrefix("--pane=") {
                    paneArg = String(part.dropFirst(7))
                    break
                }
            }

            let paneIds = tab.bonsplitController.allPaneIds
            var targetPaneId: PaneID? = tab.bonsplitController.focusedPaneId
            if let paneArg {
                if let uuid = UUID(uuidString: paneArg),
                   let paneId = paneIds.first(where: { $0.id == uuid }) {
                    targetPaneId = paneId
                } else if let uuid = v2ResolveHandleRef(paneArg),
                          let paneId = paneIds.first(where: { $0.id == uuid }) {
                    targetPaneId = paneId
                } else {
                    result = "ERROR: Pane not found"
                    return
                }
            }

            guard let paneId = targetPaneId else {
                result = "ERROR: No pane to list tabs from"
                return
            }

            let tabs = tab.bonsplitController.tabs(inPane: paneId)
            let selectedTab = tab.bonsplitController.selectedTab(inPane: paneId)

            let lines = tabs.map { bonsplitTab in
                let selected = bonsplitTab.id == selectedTab?.id ? "*" : " "
                let panelId = tab.panelIdFromSurfaceId(bonsplitTab.id)
                let panelIdStr = panelId?.uuidString ?? "unknown"
                let ref = panelId.map { v2EnsureHandleRef(kind: .surface, uuid: $0) } ?? "surface:?"
                return "\(selected) \(ref): \(bonsplitTab.title) [panel:\(panelIdStr)]"
            }
            result = lines.isEmpty ? "No tabs in pane" : lines.joined(separator: "\n")
        }
        return result
    }

    func focusPane(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let paneArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paneArg.isEmpty else { return "ERROR: Usage: focus_pane <pane_id>" }

        var result = "ERROR: Pane not found"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            let paneIds = tab.bonsplitController.allPaneIds

            // Try UUID first, then fall back to short ref
            if let uuid = UUID(uuidString: paneArg),
               let paneId = paneIds.first(where: { $0.id == uuid }) {
                tab.bonsplitController.focusPane(paneId)
                result = "OK"
            } else if let uuid = v2ResolveHandleRef(paneArg),
                      let paneId = paneIds.first(where: { $0.id == uuid }) {
                tab.bonsplitController.focusPane(paneId)
                result = "OK"
            }
        }
        return result
    }

	    func focusSurfaceByPanel(_ args: String) -> String {
	        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let tabArg = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tabArg.isEmpty else { return "ERROR: Usage: focus_surface_by_panel <panel_id>" }

        var result = "ERROR: Panel not found"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            // Focus by panel UUID (our stable surface handle). This must also move AppKit
            // first responder into the terminal view to ensure typing routes correctly.
            if let panelUUID = UUID(uuidString: tabArg),
               tab.panels[panelUUID] != nil,
               tab.surfaceIdFromPanelId(panelUUID) != nil {
                tabManager.focusSurface(tabId: tab.id, surfaceId: panelUUID)
                result = "OK"
            }
        }
	        return result
	    }
	
	    func dragSurfaceToSplit(_ args: String) -> String {
	        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
	
	        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
	        let parts = trimmed.split(separator: " ").map(String.init)
	        guard parts.count >= 2 else { return "ERROR: Usage: drag_surface_to_split <id|idx> <left|right|up|down>" }
	
	        let surfaceArg = parts[0]
	        let directionArg = parts[1]
	        guard let direction = parseSplitDirection(directionArg) else {
	            return "ERROR: Invalid direction. Use left, right, up, or down."
	        }
	
	        let orientation: SplitOrientation = direction.isHorizontal ? .horizontal : .vertical
	        let insertFirst = (direction == .left || direction == .up)
	
	        var result = "ERROR: Failed to move surface"
	        DispatchQueue.main.sync {
	            guard let tabId = tabManager.selectedTabId,
	                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
	                result = "ERROR: No tab selected"
	                return
	            }
	
	            guard let panelId = resolveSurfaceId(from: surfaceArg, tab: tab),
	                  let bonsplitTabId = tab.surfaceIdFromPanelId(panelId) else {
	                result = "ERROR: Surface not found"
	                return
	            }
	
	            guard let newPaneId = tab.bonsplitController.splitPane(
	                orientation: orientation,
	                movingTab: bonsplitTabId,
	                insertFirst: insertFirst
	            ) else {
	                result = "ERROR: Failed to split pane"
	                return
	            }
	
	            result = "OK \(newPaneId.id.uuidString)"
	        }
	        return result
	    }
	
    func newPane(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        // Parse arguments: --type=terminal|browser --direction=left|right|up|down --url=...
        var panelType: PanelType = .terminal
        var direction: SplitDirection = .right
        var url: URL? = nil
        var invalidDirection = false

        let parts = args.split(separator: " ")
        for part in parts {
            let partStr = String(part)
            if partStr.hasPrefix("--type=") {
                let typeStr = String(partStr.dropFirst(7))
                panelType = typeStr == "browser" ? .browser : .terminal
            } else if partStr.hasPrefix("--direction=") {
                let dirStr = String(partStr.dropFirst(12))
                if let parsed = parseSplitDirection(dirStr) {
                    direction = parsed
                } else {
                    invalidDirection = true
                }
            } else if partStr.hasPrefix("--url=") {
                let urlStr = String(partStr.dropFirst(6))
                url = URL(string: urlStr)
            }
        }

        if invalidDirection {
            return "ERROR: Invalid direction. Use left, right, up, or down."
        }

        let orientation = direction.orientation
        let insertFirst = direction.insertFirst
        let shouldFocus = socketCommandAllowsInAppFocusMutations()

        var result = "ERROR: Failed to create pane"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }),
                  let focusedPanelId = tab.focusedPanelId else {
                return
            }

            let newPanelId: UUID?
            if panelType == .browser {
                newPanelId = tab.newBrowserSplit(
                    from: focusedPanelId,
                    orientation: orientation,
                    insertFirst: insertFirst,
                    url: url,
                    focus: shouldFocus
                )?.id
            } else {
                newPanelId = tab.newTerminalSplit(
                    from: focusedPanelId,
                    orientation: orientation,
                    insertFirst: insertFirst,
                    focus: shouldFocus
                )?.id
            }

            if let id = newPanelId {
                result = "OK \(id.uuidString)"
            }
        }
        return result
    }

}
