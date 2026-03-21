import Foundation

// MARK: - Settings

enum IMEInputBarSettings {
    static let defaultFontSize: Double = 12
    static let defaultHeight: Double = 90

    static var fontSize: CGFloat {
        let val = UserDefaults.standard.double(forKey: "imeBarFontSize")
        return val > 0 ? CGFloat(val) : CGFloat(defaultFontSize)
    }

    static var height: CGFloat {
        let val = UserDefaults.standard.double(forKey: "imeBarHeight")
        return val > 0 ? CGFloat(val) : CGFloat(defaultHeight)
    }
}

// MARK: - History persistence

enum IMEHistory {
    static let key = "imeInputBarHistory"
    static let maxEntries = 30

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func save(_ entries: [String]) {
        UserDefaults.standard.set(Array(entries.prefix(maxEntries)), forKey: key)
    }

    /// Merged history: IME own entries → Claude prompt history → shell history (deduplicated).
    /// All sources are always included so the user can access any previous input regardless
    /// of what is currently running in the terminal.
    static func loadMerged() -> [String] {
        let imeEntries = load()
        let claudeEntries = ClaudeHistory.load()
        let shellEntries = ShellHistory.load()
        var seen = Set<String>()
        var merged: [String] = []
        for entry in imeEntries + claudeEntries + shellEntries {
            if !seen.contains(entry) {
                seen.insert(entry)
                merged.append(entry)
            }
        }
        return Array(merged.prefix(200))
    }
}

// MARK: - Claude Code history reader

enum ClaudeHistory {
    /// Reads `~/.claude/history.jsonl` and returns prompt display strings,
    /// most recent first. Entries are capped to avoid memory bloat.
    static func load() -> [String] {
        let historyPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/history.jsonl")
        guard let data = try? Data(contentsOf: historyPath),
              let content = String(data: data, encoding: .utf8) else { return [] }

        let lines = content.components(separatedBy: .newlines)
        var entries: [String] = []
        entries.reserveCapacity(min(lines.count, 300))

        // Parse in reverse (most recent last in file → most recent first in result)
        for line in lines.reversed() {
            guard !line.isEmpty else { continue }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let display = obj["display"] as? String else { continue }

            let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip empty, slash commands, and very short entries
            if trimmed.isEmpty || trimmed.hasPrefix("/") || trimmed.count < 2 { continue }
            // Cap individual entry length
            let capped = trimmed.count > 1000 ? String(trimmed.prefix(1000)) : trimmed
            entries.append(capped)
            if entries.count >= 300 { break }
        }
        return entries
    }
}

// MARK: - Shell history reader

enum ShellHistory {
    /// Reads shell history (~/.zsh_history or ~/.bash_history), most recent first.
    static func load() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Try zsh first, then bash
        let candidates = [
            home.appendingPathComponent(".zsh_history"),
            home.appendingPathComponent(".bash_history"),
        ]
        guard let historyURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: historyURL),
              let content = String(data: data, encoding: .utf8) else { return [] }

        let isZsh = historyURL.lastPathComponent == ".zsh_history"
        let lines = content.components(separatedBy: .newlines)
        var entries: [String] = []
        entries.reserveCapacity(min(lines.count, 300))

        // Parse in reverse (most recent at the end of file)
        for line in lines.reversed() {
            guard !line.isEmpty else { continue }
            let command: String
            if isZsh, line.hasPrefix(": ") {
                // Extended zsh format: ": timestamp:0;command"
                if let semicolonIdx = line.firstIndex(of: ";") {
                    command = String(line[line.index(after: semicolonIdx)...])
                } else {
                    continue
                }
            } else {
                command = line
            }
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.count < 2 { continue }
            // Skip duplicates within shell history
            if entries.contains(trimmed) { continue }
            let capped = trimmed.count > 1000 ? String(trimmed.prefix(1000)) : trimmed
            entries.append(capped)
            if entries.count >= 300 { break }
        }
        return entries
    }
}

// MARK: - Claude Code slash commands

struct SlashCommand: Equatable, Hashable {
    let name: String
    let desc: String
}

enum SlashCommands {
    /// Built-in Claude Code slash commands with descriptions
    static let builtinCommands: [SlashCommand] = [
        .init(name: "/add-dir", desc: "Add a directory to context"),
        .init(name: "/agents", desc: "View agent status"),
        .init(name: "/btw", desc: "Send a non-blocking message"),
        .init(name: "/chrome", desc: "Control Chrome browser"),
        .init(name: "/clear", desc: "Clear conversation history"),
        .init(name: "/color", desc: "Change terminal color scheme"),
        .init(name: "/compact", desc: "Compact conversation to save context"),
        .init(name: "/config", desc: "Open or edit config"),
        .init(name: "/context", desc: "Manage context files"),
        .init(name: "/copy", desc: "Copy last response to clipboard"),
        .init(name: "/cost", desc: "Show token usage and cost"),
        .init(name: "/desktop", desc: "Control desktop automation"),
        .init(name: "/diff", desc: "Show pending file changes"),
        .init(name: "/doctor", desc: "Check Claude Code health"),
        .init(name: "/effort", desc: "Set thinking effort level"),
        .init(name: "/exit", desc: "Exit Claude Code"),
        .init(name: "/export", desc: "Export conversation"),
        .init(name: "/extra-usage", desc: "Manage extra usage allowance"),
        .init(name: "/fast", desc: "Toggle fast mode (Haiku)"),
        .init(name: "/feedback", desc: "Send feedback to Anthropic"),
        .init(name: "/branch", desc: "Create or switch git branch"),
        .init(name: "/help", desc: "Show available commands"),
        .init(name: "/hooks", desc: "Manage hooks"),
        .init(name: "/ide", desc: "Open file in IDE"),
        .init(name: "/init", desc: "Initialize CLAUDE.md for project"),
        .init(name: "/insights", desc: "View conversation insights"),
        .init(name: "/install-github-app", desc: "Install GitHub App"),
        .init(name: "/install-slack-app", desc: "Install Slack App"),
        .init(name: "/keybindings", desc: "View or edit keybindings"),
        .init(name: "/login", desc: "Log in to Anthropic"),
        .init(name: "/logout", desc: "Log out"),
        .init(name: "/mcp", desc: "Manage MCP servers"),
        .init(name: "/memory", desc: "Edit CLAUDE.md memory"),
        .init(name: "/mobile", desc: "Mobile development tools"),
        .init(name: "/model", desc: "Switch AI model"),
        .init(name: "/passes", desc: "Manage passes"),
        .init(name: "/permissions", desc: "Manage tool permissions"),
        .init(name: "/plan", desc: "Enter plan mode"),
        .init(name: "/plugin", desc: "Manage plugins"),
        .init(name: "/pr-comments", desc: "View PR comments"),
        .init(name: "/privacy-settings", desc: "Manage privacy settings"),
        .init(name: "/release-notes", desc: "View release notes"),
        .init(name: "/reload-plugins", desc: "Reload all plugins"),
        .init(name: "/remote-control", desc: "Remote control settings"),
        .init(name: "/remote-env", desc: "Manage remote environment"),
        .init(name: "/rename", desc: "Rename conversation"),
        .init(name: "/resume", desc: "Resume a previous conversation"),
        .init(name: "/review", desc: "Review code changes"),
        .init(name: "/rewind", desc: "Undo last action"),
        .init(name: "/sandbox", desc: "Manage sandbox settings"),
        .init(name: "/security-review", desc: "Run security review"),
        .init(name: "/skills", desc: "List available skills"),
        .init(name: "/stats", desc: "Show session statistics"),
        .init(name: "/status", desc: "Show current status"),
        .init(name: "/statusline", desc: "Configure status line"),
        .init(name: "/stickers", desc: "View stickers"),
        .init(name: "/tasks", desc: "Manage tasks"),
        .init(name: "/terminal-setup", desc: "Set up terminal integration"),
        .init(name: "/theme", desc: "Change UI theme"),
        .init(name: "/upgrade", desc: "Upgrade Claude Code"),
        .init(name: "/usage", desc: "Show usage statistics"),
        .init(name: "/vim", desc: "Toggle vim mode"),
        .init(name: "/voice", desc: "Toggle voice input"),
        // Common aliases
        .init(name: "/quit", desc: "Exit (alias)"),
        .init(name: "/reset", desc: "Reset conversation (alias)"),
        .init(name: "/new", desc: "New conversation (alias)"),
        .init(name: "/settings", desc: "Open settings (alias)"),
        .init(name: "/bug", desc: "Report a bug (alias)"),
        .init(name: "/continue", desc: "Continue previous session (alias)"),
        .init(name: "/checkpoint", desc: "Create a checkpoint (alias)"),
        .init(name: "/allowed-tools", desc: "Manage allowed tools (alias)"),
        // Bundled skills
        .init(name: "/batch", desc: "Run batch operations"),
        .init(name: "/claude-api", desc: "Build with Claude API"),
        .init(name: "/debug", desc: "Debug an issue"),
        .init(name: "/loop", desc: "Run recurring task"),
        .init(name: "/simplify", desc: "Simplify code"),
    ]

    /// Loads built-in commands merged with custom commands from .claude/commands/ directories.
    /// - Parameter workingDirectory: Terminal's current working directory; used to find the project root.
    static func loadAll(workingDirectory: String? = nil) -> [SlashCommand] {
        var commands = builtinCommands
        // Project-local commands: walk up from the terminal CWD to find .claude/commands/
        let projectDir = findProjectCommandsDir(from: workingDirectory)
            ?? findProjectCommandsDir(from: GhosttyConfig.load().workingDirectory)
            ?? findProjectCommandsDir(from: FileManager.default.currentDirectoryPath)
        if let projectDir {
            commands += scanCommandDir(projectDir)
        }
        // User global commands
        let userDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/commands").path
        commands += scanCommandDir(userDir)
        // Dedupe by name and sort
        var seen = Set<String>()
        var unique: [SlashCommand] = []
        for cmd in commands {
            if !seen.contains(cmd.name) {
                seen.insert(cmd.name)
                unique.append(cmd)
            }
        }
        return unique.sorted { $0.name < $1.name }
    }

    /// Walk up from `startDir` looking for `.claude/commands/`.
    private static func findProjectCommandsDir(from startDir: String?) -> String? {
        guard let start = startDir, !start.isEmpty else { return nil }
        var dir = start
        let fm = FileManager.default
        for _ in 0..<10 {
            let candidate = (dir as NSString).appendingPathComponent(".claude/commands")
            if fm.fileExists(atPath: candidate) {
                return candidate
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    private static func scanCommandDir(_ path: String) -> [SlashCommand] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return files.compactMap { file -> SlashCommand? in
            guard file.hasSuffix(".md") else { return nil }
            let name = "/" + file.replacingOccurrences(of: ".md", with: "")
            return SlashCommand(name: name, desc: "Custom command")
        }
    }
}
