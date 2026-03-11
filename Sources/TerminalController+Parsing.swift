import AppKit
import Foundation
import Bonsplit

extension TerminalController {
    // MARK: - Option Parsing (sidebar metadata commands)

    func tokenizeArgs(_ args: String) -> [String] {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""
        var cursor = trimmed.startIndex

        while cursor < trimmed.endIndex {
            let char = trimmed[cursor]
            if inQuote {
                if char == quoteChar {
                    inQuote = false
                    cursor = trimmed.index(after: cursor)
                    continue
                }
                if char == "\\" {
                    let nextIndex = trimmed.index(after: cursor)
                    if nextIndex < trimmed.endIndex {
                        let next = trimmed[nextIndex]
                        switch next {
                        case "n":
                            current.append("\n")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "r":
                            current.append("\r")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "t":
                            current.append("\t")
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        case "\"", "'", "\\":
                            current.append(next)
                            cursor = trimmed.index(after: nextIndex)
                            continue
                        default:
                            break
                        }
                    }
                }
                current.append(char)
                cursor = trimmed.index(after: cursor)
                continue
            }

            if char == "'" || char == "\"" {
                inQuote = true
                quoteChar = char
                cursor = trimmed.index(after: cursor)
                continue
            }

            if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                cursor = trimmed.index(after: cursor)
                continue
            }

            current.append(char)
            cursor = trimmed.index(after: cursor)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    func parseOptions(_ args: String) -> (positional: [String], options: [String: String]) {
        let tokens = tokenizeArgs(args)
        guard !tokens.isEmpty else { return ([], [:]) }

        var positional: [String] = []
        var options: [String: String] = [:]
        var stopParsingOptions = false
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if stopParsingOptions {
                positional.append(token)
            } else if token == "--" {
                stopParsingOptions = true
            } else if token.hasPrefix("--") {
                if let eqIndex = token.firstIndex(of: "=") {
                    let key = String(token[token.index(token.startIndex, offsetBy: 2)..<eqIndex])
                    let value = String(token[token.index(after: eqIndex)...])
                    options[key] = value
                } else {
                    let key = String(token.dropFirst(2))
                    if i + 1 < tokens.count && !tokens[i + 1].hasPrefix("--") {
                        options[key] = tokens[i + 1]
                        i += 1
                    } else {
                        options[key] = ""
                    }
                }
            } else {
                positional.append(token)
            }
            i += 1
        }
        return (positional, options)
    }

    func parseOptionsNoStop(_ args: String) -> (positional: [String], options: [String: String]) {
        let tokens = tokenizeArgs(args)
        guard !tokens.isEmpty else { return ([], [:]) }

        var positional: [String] = []
        var options: [String: String] = [:]
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if token == "--" {
                i += 1
                continue
            }
            if token.hasPrefix("--") {
                if let eqIndex = token.firstIndex(of: "=") {
                    let key = String(token[token.index(token.startIndex, offsetBy: 2)..<eqIndex])
                    let value = String(token[token.index(after: eqIndex)...])
                    options[key] = value
                } else {
                    let key = String(token.dropFirst(2))
                    if i + 1 < tokens.count && !tokens[i + 1].hasPrefix("--") {
                        options[key] = tokens[i + 1]
                        i += 1
                    } else {
                        options[key] = ""
                    }
                }
            } else {
                positional.append(token)
            }
            i += 1
        }
        return (positional, options)
    }

    func resolveTabForReport(_ args: String) -> Tab? {
        guard let tabManager else { return nil }
        let parsed = parseOptions(args)
        if let tabArg = parsed.options["tab"], !tabArg.isEmpty {
            if let tab = resolveTab(from: tabArg, tabManager: tabManager) {
                return tab
            }
            // The tab may belong to a different window — search all contexts.
            if let uuid = UUID(uuidString: tabArg.trimmingCharacters(in: .whitespacesAndNewlines)),
               let otherManager = AppDelegate.shared?.tabManagerFor(tabId: uuid) {
                return otherManager.tabs.first(where: { $0.id == uuid })
            }
            return nil
        }
        guard let selectedId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == selectedId })
    }

    func setStatus(_ args: String) -> String {
        guard tabManager != nil else { return "ERROR: TabManager not available" }
        let parsed = parseOptionsNoStop(args)
        guard parsed.positional.count >= 2 else {
            return "ERROR: Missing status key or value — usage: set_status <key> <value> [--icon=X] [--color=#hex] [--tab=X]"
        }
        let key = parsed.positional[0]
        let value = parsed.positional[1...].joined(separator: " ")
        let icon = parsed.options["icon"]
        let color = parsed.options["color"]

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let tab = resolveTabForReport(args) else { return }
            guard Self.shouldReplaceStatusEntry(
                current: tab.statusEntries[key],
                key: key,
                value: value,
                icon: icon,
                color: color
            ) else { return }
            tab.statusEntries[key] = SidebarStatusEntry(
                key: key,
                value: value,
                icon: icon,
                color: color,
                timestamp: Date()
            )
        }
        return "OK"
    }

    func clearStatus(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard let key = parsed.positional.first, parsed.positional.count == 1 else {
            return "ERROR: Missing status key — usage: clear_status <key> [--tab=X]"
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let tab = resolveTabForReport(args) else { return }
            tab.statusEntries.removeValue(forKey: key)
        }
        return "OK"
    }

    func listStatus(_ args: String) -> String {
        var result = ""
        DispatchQueue.main.sync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }
            if tab.statusEntries.isEmpty {
                result = "No status entries"
                return
            }
            let lines = tab.statusEntries.values.sorted(by: { $0.key < $1.key }).map { entry in
                var line = "\(entry.key)=\(entry.value)"
                if let icon = entry.icon { line += " icon=\(icon)" }
                if let color = entry.color { line += " color=\(color)" }
                return line
            }
            result = lines.joined(separator: "\n")
        }
        return result
    }

    func appendLog(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard !parsed.positional.isEmpty else {
            return "ERROR: Missing message — usage: log [--level=X] [--source=X] [--tab=X] -- <message>"
        }
        let message = parsed.positional.joined(separator: " ")
        let levelStr = parsed.options["level"] ?? "info"
        guard let level = SidebarLogLevel(rawValue: levelStr) else {
            return "ERROR: Unknown log level '\(levelStr)' — use: info, progress, success, warning, error"
        }
        let source = parsed.options["source"]

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let tab = resolveTabForReport(args) else { return }
            tab.logEntries.append(SidebarLogEntry(message: message, level: level, source: source, timestamp: Date()))
            let configuredLimit = UserDefaults.standard.object(forKey: "sidebarMaxLogEntries") as? Int ?? 50
            let limit = max(1, min(500, configuredLimit))
            if tab.logEntries.count > limit {
                tab.logEntries.removeFirst(tab.logEntries.count - limit)
            }
        }
        return "OK"
    }

    func clearLog(_ args: String) -> String {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let tab = resolveTabForReport(args) else { return }
            tab.logEntries.removeAll()
        }
        return "OK"
    }

    func listLog(_ args: String) -> String {
        let parsed = parseOptions(args)
        var limit: Int?
        if let limitStr = parsed.options["limit"] {
            if limitStr.isEmpty {
                return "ERROR: Missing limit value — usage: list_log [--limit=N] [--tab=X]"
            }
            guard let parsedLimit = Int(limitStr), parsedLimit >= 0 else {
                return "ERROR: Invalid limit '\(limitStr)' — must be >= 0"
            }
            limit = parsedLimit
        }

        var result = ""
        DispatchQueue.main.sync {
            guard let tab = resolveTabForReport(args) else {
                result = parsed.options["tab"] != nil ? "ERROR: Tab not found" : "ERROR: No tab selected"
                return
            }
            if tab.logEntries.isEmpty {
                result = "No log entries"
                return
            }
            let entries: [SidebarLogEntry]
            if let limit {
                entries = Array(tab.logEntries.suffix(limit))
            } else {
                entries = tab.logEntries
            }
            result = entries.map { entry in
                var line = "[\(entry.level.rawValue)] \(entry.message)"
                if let source = entry.source, !source.isEmpty {
                    line = "[\(source)] \(line)"
                }
                return line
            }.joined(separator: "\n")
        }
        return result
    }

    func setProgress(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard let first = parsed.positional.first else {
            return "ERROR: Missing progress value — usage: set_progress <0.0-1.0> [--label=X] [--tab=X]"
        }
        guard let value = Double(first), value.isFinite else {
            return "ERROR: Invalid progress value '\(first)' — must be 0.0 to 1.0"
        }
        let clamped = min(1.0, max(0.0, value))
        let label = parsed.options["label"]

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let tab = resolveTabForReport(args) else { return }
            guard Self.shouldReplaceProgress(current: tab.progress, value: clamped, label: label) else { return }
            tab.progress = SidebarProgressState(value: clamped, label: label)
        }
        return "OK"
    }

    func clearProgress(_ args: String) -> String {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let tab = resolveTabForReport(args) else { return }
            if tab.progress != nil {
                tab.progress = nil
            }
        }
        return "OK"
    }

    func reportGitBranch(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard let branch = parsed.positional.first else {
            return "ERROR: Missing branch name — usage: report_git_branch <branch> [--status=dirty] [--tab=X] [--panel=Y]"
        }
        let isDirty = parsed.options["status"]?.lowercased() == "dirty"
        let dirtyFileCount = parsed.options["files"].flatMap { Int($0) }
        let panelArgRaw = parsed.options["panel"] ?? parsed.options["surface"]

        // Validate panel UUID format off-main
        let panelId: UUID?
        if let raw = panelArgRaw {
            if raw.isEmpty {
                return "ERROR: Missing panel id — usage: report_git_branch <branch> [--status=dirty] [--files=N] [--tab=X] [--panel=Y]"
            }
            guard let uuid = UUID(uuidString: raw) else {
                return "ERROR: Invalid panel id '\(raw)'"
            }
            panelId = uuid
        } else {
            panelId = nil
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let tab = resolveTabForReport(args) else { return }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let surfaceId: UUID
            if let panelId {
                guard validSurfaceIds.contains(panelId) else { return }
                surfaceId = panelId
            } else {
                guard let focused = tab.focusedPanelId else { return }
                surfaceId = focused
            }

            tab.updatePanelGitBranch(panelId: surfaceId, branch: branch, isDirty: isDirty, dirtyFileCount: dirtyFileCount)
        }
        return "OK"
    }

    func clearGitBranch(_ args: String) -> String {
        let parsed = parseOptions(args)
        let panelArgRaw = parsed.options["panel"] ?? parsed.options["surface"]

        let panelId: UUID?
        if let raw = panelArgRaw {
            if raw.isEmpty {
                return "ERROR: Missing panel id — usage: clear_git_branch [--tab=X] [--panel=Y]"
            }
            guard let uuid = UUID(uuidString: raw) else {
                return "ERROR: Invalid panel id '\(raw)'"
            }
            panelId = uuid
        } else {
            panelId = nil
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let tab = resolveTabForReport(args) else { return }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let surfaceId: UUID
            if let panelId {
                guard validSurfaceIds.contains(panelId) else { return }
                surfaceId = panelId
            } else {
                guard let focused = tab.focusedPanelId else { return }
                surfaceId = focused
            }

            tab.clearPanelGitBranch(panelId: surfaceId)
        }
        return "OK"
    }

    func reportPorts(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard !parsed.positional.isEmpty else {
            return "ERROR: Missing ports — usage: report_ports <port1> [port2...] [--tab=X] [--panel=Y]"
        }
        var ports: [Int] = []
        for portStr in parsed.positional {
            guard let port = Int(portStr), port > 0, port <= 65535 else {
                return "ERROR: Invalid port '\(portStr)' — must be 1-65535"
            }
            ports.append(port)
        }
        let normalizedPorts = Array(Set(ports)).sorted()
        let panelArgRaw = parsed.options["panel"] ?? parsed.options["surface"]

        let panelId: UUID?
        if let raw = panelArgRaw {
            if raw.isEmpty {
                return "ERROR: Missing panel id — usage: report_ports <port1> [port2...] [--tab=X] [--panel=Y]"
            }
            guard let uuid = UUID(uuidString: raw) else {
                return "ERROR: Invalid panel id '\(raw)'"
            }
            panelId = uuid
        } else {
            panelId = nil
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let tab = resolveTabForReport(args) else { return }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let surfaceId: UUID
            if let panelId {
                guard validSurfaceIds.contains(panelId) else { return }
                surfaceId = panelId
            } else {
                guard let focused = tab.focusedPanelId else { return }
                surfaceId = focused
            }

            guard Self.shouldReplacePorts(current: tab.surfaceListeningPorts[surfaceId], next: normalizedPorts) else { return }
            tab.surfaceListeningPorts[surfaceId] = normalizedPorts
            tab.recomputeListeningPorts()
        }
        return "OK"
    }

    func reportPwd(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard !parsed.positional.isEmpty else {
            return "ERROR: Missing path — usage: report_pwd <path> [--tab=X] [--panel=Y]"
        }

        let directory = Self.normalizeReportedDirectory(parsed.positional.joined(separator: " "))

        // Shell integration provides explicit UUID handles for cwd updates.
        // Keep this hot path off-main and drop no-op reports before scheduling UI work.
        if let scope = Self.explicitSocketScope(options: parsed.options) {
            guard Self.socketFastPathState.shouldPublishDirectory(
                workspaceId: scope.workspaceId,
                panelId: scope.panelId,
                directory: directory
            ) else {
                return "OK"
            }
            DispatchQueue.main.async {
                guard let tabManager = AppDelegate.shared?.tabManagerFor(tabId: scope.workspaceId) else { return }
                tabManager.updateSurfaceDirectory(tabId: scope.workspaceId, surfaceId: scope.panelId, directory: directory)
            }
            return "OK"
        }

        guard tabManager != nil else { return "ERROR: TabManager not available" }

        let panelArgRaw = parsed.options["panel"] ?? parsed.options["surface"]
        let panelId: UUID?
        if let raw = panelArgRaw {
            if raw.isEmpty {
                return "ERROR: Missing panel id — usage: report_pwd <path> [--tab=X] [--panel=Y]"
            }
            guard let uuid = UUID(uuidString: raw) else {
                return "ERROR: Invalid panel id '\(raw)'"
            }
            panelId = uuid
        } else {
            panelId = nil
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, let tabManager = self.tabManager else { return }
            guard let tab = resolveTabForReport(args) else { return }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            let surfaceId: UUID
            if let panelId {
                guard validSurfaceIds.contains(panelId) else { return }
                surfaceId = panelId
            } else {
                guard let focused = tab.focusedPanelId else { return }
                surfaceId = focused
            }

            tabManager.updateSurfaceDirectory(tabId: tab.id, surfaceId: surfaceId, directory: directory)
        }
        return "OK"
    }

    func clearPorts(_ args: String) -> String {
        let parsed = parseOptions(args)
        let panelArgRaw = parsed.options["panel"] ?? parsed.options["surface"]

        let panelId: UUID?
        if let raw = panelArgRaw {
            if raw.isEmpty {
                return "ERROR: Missing panel id — usage: clear_ports [--tab=X] [--panel=Y]"
            }
            guard let uuid = UUID(uuidString: raw) else {
                return "ERROR: Invalid panel id '\(raw)'"
            }
            panelId = uuid
        } else {
            panelId = nil
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let tab = resolveTabForReport(args) else { return }
            let validSurfaceIds = Set(tab.panels.keys)
            tab.pruneSurfaceMetadata(validSurfaceIds: validSurfaceIds)

            if let panelId {
                guard validSurfaceIds.contains(panelId) else { return }
                if tab.surfaceListeningPorts.removeValue(forKey: panelId) != nil {
                    tab.recomputeListeningPorts()
                }
            } else {
                if !tab.surfaceListeningPorts.isEmpty {
                    tab.surfaceListeningPorts.removeAll()
                    tab.recomputeListeningPorts()
                }
            }
        }
        return "OK"
    }

    func reportTTY(_ args: String) -> String {
        let parsed = parseOptions(args)
        guard let ttyName = parsed.positional.first, !ttyName.isEmpty else {
            return "ERROR: Missing tty name — usage: report_tty <tty_name> [--tab=X] [--panel=Y]"
        }

        // Shell integration always provides explicit UUID handles.
        // Handle that common path off-main to avoid sync-hopping on every report.
        if let scope = Self.explicitSocketScope(options: parsed.options) {
            PortScanner.shared.registerTTY(
                workspaceId: scope.workspaceId,
                panelId: scope.panelId,
                ttyName: ttyName
            )
            return "OK"
        }

        let panelArgRaw = parsed.options["panel"] ?? parsed.options["surface"]
        let panelId: UUID?
        if let raw = panelArgRaw {
            if raw.isEmpty {
                return "ERROR: Missing panel id — usage: report_tty <tty_name> [--tab=X] [--panel=Y]"
            }
            guard let uuid = UUID(uuidString: raw) else {
                return "ERROR: Invalid panel id '\(raw)'"
            }
            panelId = uuid
        } else {
            panelId = nil
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let tab = resolveTabForReport(args) else { return }
            let validSurfaceIds = Set(tab.panels.keys)

            let surfaceId: UUID
            if let panelId {
                guard validSurfaceIds.contains(panelId) else { return }
                surfaceId = panelId
            } else {
                guard let focused = tab.focusedPanelId else { return }
                surfaceId = focused
            }

            guard tab.surfaceTTYNames[surfaceId] != ttyName else { return }
            tab.surfaceTTYNames[surfaceId] = ttyName
            PortScanner.shared.registerTTY(workspaceId: tab.id, panelId: surfaceId, ttyName: ttyName)
        }
        return "OK"
    }

    func portsKick(_ args: String) -> String {
        let parsed = parseOptions(args)

        // Shell integration always provides explicit UUID handles.
        // Handle that common path off-main to keep prompt hooks from blocking UI work.
        if let scope = Self.explicitSocketScope(options: parsed.options) {
            PortScanner.shared.kick(workspaceId: scope.workspaceId, panelId: scope.panelId)
            return "OK"
        }

        let panelArgRaw = parsed.options["panel"] ?? parsed.options["surface"]
        let panelId: UUID?
        if let raw = panelArgRaw {
            if raw.isEmpty {
                return "ERROR: Missing panel id — usage: ports_kick [--tab=X] [--panel=Y]"
            }
            guard let uuid = UUID(uuidString: raw) else {
                return "ERROR: Invalid panel id '\(raw)'"
            }
            panelId = uuid
        } else {
            panelId = nil
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let tab = resolveTabForReport(args) else { return }
            let surfaceId: UUID
            if let panelId {
                surfaceId = panelId
            } else {
                guard let focused = tab.focusedPanelId else { return }
                surfaceId = focused
            }
            PortScanner.shared.kick(workspaceId: tab.id, panelId: surfaceId)
        }
        return "OK"
    }

    func sidebarState(_ args: String) -> String {
        var result = ""
        DispatchQueue.main.sync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }

            var lines: [String] = []
            lines.append("tab=\(tab.id.uuidString)")
            lines.append("cwd=\(tab.currentDirectory)")

            if let focused = tab.focusedPanelId,
               let focusedDir = tab.panelDirectories[focused] {
                lines.append("focused_cwd=\(focusedDir)")
                lines.append("focused_panel=\(focused.uuidString)")
            } else {
                lines.append("focused_cwd=unknown")
                lines.append("focused_panel=unknown")
            }

            if let git = tab.gitBranch {
                lines.append("git_branch=\(git.branch)\(git.isDirty ? " dirty" : " clean")")
            } else {
                lines.append("git_branch=none")
            }

            if tab.listeningPorts.isEmpty {
                lines.append("ports=none")
            } else {
                lines.append("ports=\(tab.listeningPorts.map(String.init).joined(separator: ","))")
            }

            if let progress = tab.progress {
                let label = progress.label ?? ""
                lines.append("progress=\(String(format: "%.2f", progress.value)) \(label)".trimmingCharacters(in: .whitespaces))
            } else {
                lines.append("progress=none")
            }

            lines.append("status_count=\(tab.statusEntries.count)")
            for entry in tab.statusEntries.values.sorted(by: { $0.key < $1.key }) {
                var line = "  \(entry.key)=\(entry.value)"
                if let icon = entry.icon { line += " icon=\(icon)" }
                if let color = entry.color { line += " color=\(color)" }
                lines.append(line)
            }

            lines.append("log_count=\(tab.logEntries.count)")
            for entry in tab.logEntries.suffix(5) {
                lines.append("  [\(entry.level.rawValue)] \(entry.message)")
            }

            result = lines.joined(separator: "\n")
        }
        return result
    }

    func resetSidebar(_ args: String) -> String {
        var result = "OK"
        DispatchQueue.main.sync {
            guard let tab = resolveTabForReport(args) else {
                result = "ERROR: Tab not found"
                return
            }
            tab.statusEntries.removeAll()
            tab.logEntries.removeAll()
            tab.progress = nil
            tab.gitBranch = nil
            tab.panelGitBranches.removeAll()
            tab.surfaceListeningPorts.removeAll()
            tab.listeningPorts.removeAll()
        }
        return result
    }

    func refreshSurfaces() -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var refreshedCount = 0
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            // Force-refresh all terminal panels in current tab
            // (resets cached metrics so the Metal layer drawable resizes correctly)
            for panel in tab.panels.values {
                if let terminalPanel = panel as? TerminalPanel {
                    terminalPanel.surface.forceRefresh()
                    refreshedCount += 1
                }
            }
        }
        return "OK Refreshed \(refreshedCount) surfaces"
    }

    func viewDepth(of view: NSView, maxDepth: Int = 128) -> Int {
        var depth = 0
        var current: NSView? = view
        while let v = current, depth < maxDepth {
            current = v.superview
            depth += 1
        }
        return depth
    }

    func isPortalHosted(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v is WindowTerminalHostView { return true }
            current = v.superview
        }
        return false
    }

    func surfaceHealth(_ tabArg: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        var result = ""
        DispatchQueue.main.sync {
            guard let tab = resolveTab(from: tabArg, tabManager: tabManager) else {
                result = "ERROR: Tab not found"
                return
            }
            let panels = orderedPanels(in: tab)
            let lines = panels.enumerated().map { index, panel -> String in
                let panelId = panel.id.uuidString
                let type = panel.panelType.rawValue
                if let tp = panel as? TerminalPanel {
                    let inWindow = tp.surface.isViewInWindow
                    let portalHosted = isPortalHosted(tp.hostedView)
                    let depth = viewDepth(of: tp.hostedView)
                    return "\(index): \(panelId) type=\(type) in_window=\(inWindow) portal=\(portalHosted) view_depth=\(depth)"
                } else if let bp = panel as? BrowserPanel {
                    let inWindow = bp.webView.window != nil
                    return "\(index): \(panelId) type=\(type) in_window=\(inWindow)"
                } else {
                    return "\(index): \(panelId) type=\(type) in_window=unknown"
                }
            }
            result = lines.isEmpty ? "No surfaces" : lines.joined(separator: "\n")
        }
        return result
    }

    func closeSurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)

        var result = "ERROR: Failed to close surface"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            // Resolve surface ID from argument or use focused
            let surfaceId: UUID?
            if trimmed.isEmpty {
                surfaceId = tab.focusedPanelId
            } else {
                surfaceId = resolveSurfaceId(from: trimmed, tab: tab)
            }

            guard let targetSurfaceId = surfaceId else {
                result = "ERROR: Surface not found"
                return
            }

            // Don't close if it's the only surface
            if tab.panels.count <= 1 {
                result = "ERROR: Cannot close the last surface"
                return
            }

            // Socket commands must be non-interactive: bypass close-confirmation gating.
            tab.closePanel(targetSurfaceId, force: true)
            result = "OK"
        }
        return result
    }

    func newSurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        // Parse arguments: --type=terminal|browser --pane=<pane_id> --url=...
        var panelType: PanelType = .terminal
        var paneArg: String? = nil
        var url: URL? = nil
        let shouldFocus = socketCommandAllowsInAppFocusMutations()

        let parts = args.split(separator: " ")
        for part in parts {
            let partStr = String(part)
            if partStr.hasPrefix("--type=") {
                let typeStr = String(partStr.dropFirst(7))
                panelType = typeStr == "browser" ? .browser : .terminal
            } else if partStr.hasPrefix("--pane=") {
                paneArg = String(partStr.dropFirst(7))
            } else if partStr.hasPrefix("--url=") {
                let urlStr = String(partStr.dropFirst(6))
                url = URL(string: urlStr)
            }
        }

        var result = "ERROR: Failed to create tab"
        DispatchQueue.main.sync {
            guard let tabId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == tabId }) else {
                return
            }

            // Get target pane
            let paneId: PaneID?
            let paneIds = tab.bonsplitController.allPaneIds
            if let paneArg {
                if let uuid = UUID(uuidString: paneArg) {
                    paneId = paneIds.first(where: { $0.id == uuid })
                } else if let uuid = v2ResolveHandleRef(paneArg) {
                    paneId = paneIds.first(where: { $0.id == uuid })
                } else {
                    paneId = nil
                }
            } else {
                paneId = tab.bonsplitController.focusedPaneId
            }

            guard let targetPaneId = paneId else {
                result = "ERROR: Pane not found"
                return
            }

            let newPanelId: UUID?
            if panelType == .browser {
                newPanelId = tab.newBrowserSurface(inPane: targetPaneId, url: url, focus: shouldFocus)?.id
            } else {
                newPanelId = tab.newTerminalSurface(inPane: targetPaneId, focus: shouldFocus)?.id
            }

            if let id = newPanelId {
                result = "OK \(id.uuidString)"
            }
        }
        return result
    }

    func workspaceTag(_ args: String) -> String {
        let parsed = parseOptions(args)
        let tabOption = parsed.options["tab"]

        guard let tab = (tabOption != nil ? resolveTabForReport("--tab=\(tabOption!)") : resolveTabForReport("")) else {
            return "ERROR: No active tab"
        }

        if parsed.positional.first == "--clear" || parsed.positional.first == "clear" {
            tab.tag = nil
            return "OK cleared"
        }

        let tagText = parsed.positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if tagText.isEmpty {
            return tab.tag ?? "(none)"
        }

        tab.tag = tagText
        return "OK \(tagText)"
    }
}
