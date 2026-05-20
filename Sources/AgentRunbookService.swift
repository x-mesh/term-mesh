import AppKit
import Foundation

enum AgentRunbookFileState: String, Codable, Equatable, Sendable {
    case missing
    case managed
    case outdated
    case custom

    var displayName: String {
        switch self {
        case .missing: return "Missing"
        case .managed: return "Managed"
        case .outdated: return "Outdated"
        case .custom: return "Custom"
        }
    }
}

struct AgentRunbookLintIssue: Identifiable, Equatable, Sendable {
    let role: String
    let message: String

    var id: String { "\(role):\(message)" }
}

struct AgentRunbookProjectionStatus: Identifiable, Equatable, Sendable {
    let tool: AgentRunbookTool
    let path: String
    let state: AgentRunbookFileState

    var id: String { "\(tool.rawValue):\(path)" }
}

struct AgentRunbookRoleStatus: Identifiable, Equatable, Sendable {
    let role: String
    let sourcePath: String
    let sourceState: AgentRunbookFileState
    let lintIssues: [AgentRunbookLintIssue]
    let projections: [AgentRunbookProjectionStatus]

    var id: String { role }

    func projection(for tool: AgentRunbookTool) -> AgentRunbookProjectionStatus? {
        projections.first { $0.tool == tool }
    }
}

struct AgentRunbookStatus: Equatable, Sendable {
    let projectRoot: String
    let sourceDir: String
    let roles: [AgentRunbookRoleStatus]

    var managedSourceCount: Int {
        roles.filter { $0.sourceState == .managed }.count
    }

    var customSourceCount: Int {
        roles.filter { $0.sourceState == .custom }.count
    }

    var missingSourceCount: Int {
        roles.filter { $0.sourceState == .missing }.count
    }

    var lintIssueCount: Int {
        roles.flatMap(\.lintIssues).count
    }

    var outdatedProjectionCount: Int {
        roles
            .flatMap(\.projections)
            .filter { $0.state == .outdated }
            .count
    }

    func role(_ name: String) -> AgentRunbookRoleStatus? {
        let normalized = AgentRunbookService.normalizeRoleName(name)
        return roles.first { $0.role == normalized }
    }
}

enum AgentRunbookTool: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case opencode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }
}

enum AgentRunbookInstructionMode: Sendable {
    case full
    case digest
}

struct AgentRunbookCommandResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }

    var displayOutput: String {
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return out }
        if !err.isEmpty { return err }
        return "Exit \(exitCode)"
    }
}

struct AgentRunbookWriteResult: Equatable, Sendable {
    let path: String
    let state: String
    let message: String
}

final class AgentRunbookService: @unchecked Sendable {
    static let shared = AgentRunbookService()

    static let managedMarker = "<!-- term-mesh-managed: runbook-installer v1 -->"
    static let effectivePromptMarker = "<!-- term-mesh-effective-runbook v1 -->"
    static let sourceDirName = ".agent-runbooks"

    static let builtInRoleNames = [
        "explorer",
        "architect",
        "planner",
        "executor",
        "frontend",
        "backend",
        "refactorer",
        "reviewer",
        "debugger",
        "tester",
        "security",
        "devops",
        "writer",
        "researcher",
        "data",
        "perf",
        "syseng",
        "api",
        "mobile",
        "infra",
        "ux",
        "ai",
        "watcher",
    ]

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    static func normalizeRoleName(_ name: String) -> String {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out = ""
        for scalar in lower.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                out.unicodeScalars.append(scalar)
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                out.append("-")
            }
        }
        return out.isEmpty ? "agent" : out
    }

    func roles(from presets: [AgentRolePreset] = AgentRolePresetManager.shared.presets) -> [String] {
        let presetRoles = presets.map { Self.normalizeRoleName($0.name) }
        return Array(Set(Self.builtInRoleNames + presetRoles)).sorted()
    }

    @MainActor
    func currentWorkingDirectory() -> String {
        if let keyWindow = NSApp.keyWindow,
           let ctx = AppDelegate.shared?.contextForMainWindow(keyWindow),
           let dir = ctx.tabManager.selectedTab?.currentDirectory {
            return dir
        }
        if let ctx = AppDelegate.shared?.mainWindowContexts.values.first,
           let dir = ctx.tabManager.selectedTab?.currentDirectory {
            return dir
        }
        return fileManager.currentDirectoryPath
    }

    func projectRoot(from workingDirectory: String) -> String {
        let start = URL(fileURLWithPath: workingDirectory).standardizedFileURL
        var cursor = start
        while true {
            if hasProjectMarker(at: cursor.path) {
                return cursor.path
            }
            let next = cursor.deletingLastPathComponent()
            if next.path == cursor.path {
                return start.path
            }
            cursor = next
        }
    }

    @MainActor
    func status(
        workingDirectory: String? = nil,
        roles roleNames: [String]? = nil
    ) -> AgentRunbookStatus {
        let workdir = workingDirectory ?? currentWorkingDirectory()
        let root = projectRoot(from: workdir)
        let roles = (roleNames ?? roles()).map(Self.normalizeRoleName).sorted()
        let sourceDir = URL(fileURLWithPath: root).appendingPathComponent(Self.sourceDirName, isDirectory: true)

        let roleStatuses = roles.map { role in
            let sourcePath = sourcePath(projectRoot: root, role: role)
            let sourceState = fileState(sourcePath)
            let sourceContent = try? String(contentsOfFile: sourcePath, encoding: .utf8)
            let projections = AgentRunbookTool.allCases.map { tool in
                let path = projectionPath(projectRoot: root, tool: tool, role: role)
                let state = projectionState(path: path, tool: tool, role: role, sourceContent: sourceContent)
                return AgentRunbookProjectionStatus(tool: tool, path: path, state: state)
            }
            return AgentRunbookRoleStatus(
                role: role,
                sourcePath: sourcePath,
                sourceState: sourceState,
                lintIssues: lintIssues(role: role, sourceState: sourceState, sourceContent: sourceContent),
                projections: projections
            )
        }

        return AgentRunbookStatus(projectRoot: root, sourceDir: sourceDir.path, roles: roleStatuses)
    }

    func loadRunbookContent(role: String, workingDirectory: String) -> String? {
        let root = projectRoot(from: workingDirectory)
        let path = sourcePath(projectRoot: root, role: Self.normalizeRoleName(role))
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return stripManagedMarker(from: content).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func composeInstructions(
        roleName: String,
        presetInstructions: String,
        customInstructions: String? = nil,
        workingDirectory: String,
        mode: AgentRunbookInstructionMode = .full
    ) -> String {
        let preset = presetInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if preset.contains(Self.effectivePromptMarker) {
            return appendCustomInstructionsIfNeeded(base: preset, customInstructions: customInstructions)
        }

        var parts: [String] = []
        if !preset.isEmpty {
            parts.append(mode == .digest ? presetRoutingDigest(preset) : preset)
        }

        if let runbook = loadRunbookContent(role: roleName, workingDirectory: workingDirectory),
           !runbook.isEmpty {
            switch mode {
            case .full:
                parts.append("""
                \(Self.effectivePromptMarker)
                ## Repo Role Runbook

                \(runbook)
                """)
            case .digest:
                parts.append(runbookDigest(role: roleName, content: runbook, workingDirectory: workingDirectory))
            }
        }

        return appendCustomInstructionsIfNeeded(base: parts.joined(separator: "\n\n"), customInstructions: customInstructions)
    }

    func runbookDigest(role: String, content: String, workingDirectory: String) -> String {
        let normalized = Self.normalizeRoleName(role)
        let root = projectRoot(from: workingDirectory)
        let fullPath = sourcePath(projectRoot: root, role: normalized)
        let when = sectionBullets(content, section: "## When To Use", limit: 2).joined(separator: " | ")
        let must = sectionBullets(content, section: "## Operating Rules", limit: 3).joined(separator: " | ")
        let verify = sectionBullets(content, section: "## Verify", limit: 2).joined(separator: " | ")
        return """
        \(Self.effectivePromptMarker)
        <!-- term-mesh-runbook-digest v1 -->
        ## Repo Role Runbook Digest
        ROLE: \(normalized)
        WHEN: \(when.isEmpty ? "Use for assigned \(normalized) role work." : when)
        MUST: \(must.isEmpty ? "Follow the leader's task instructions and repo constraints." : must)
        VERIFY: \(verify.isEmpty ? "Report a concrete verify command or n/a." : verify)
        OUTPUT: STATUS/FILES/VERIFY/NEXT/FULL_REPORT
        FULL: \(fullPath)
        """
    }

    private func presetRoutingDigest(_ preset: String) -> String {
        let firstLine = preset
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        guard !firstLine.isEmpty else { return "" }
        return """
        ## Role Routing Digest
        SUMMARY: \(String(firstLine.prefix(180)))
        """
    }

    private func sectionBullets(_ content: String, section: String, limit: Int) -> [String] {
        var inSection = false
        var out: [String] = []
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("## ") {
                inSection = line == section
                continue
            }
            if inSection, line.hasPrefix("- ") {
                out.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines))
                if out.count >= limit { break }
            }
        }
        return out
    }

    @MainActor
    func writeRunbookFromPreset(
        _ preset: AgentRolePreset,
        workingDirectory: String? = nil,
        force: Bool = false
    ) -> AgentRunbookWriteResult {
        let workdir = workingDirectory ?? currentWorkingDirectory()
        let root = projectRoot(from: workdir)
        let role = Self.normalizeRoleName(preset.name)
        let path = sourcePath(projectRoot: root, role: role)

        if let existing = try? String(contentsOfFile: path, encoding: .utf8),
           !existing.contains(Self.managedMarker),
           !force {
            return AgentRunbookWriteResult(
                path: path,
                state: "skipped_custom",
                message: "Custom runbook already exists."
            )
        }

        do {
            let url = URL(fileURLWithPath: path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            try sourceRunbookContent(for: preset).write(to: url, atomically: true, encoding: .utf8)
            return AgentRunbookWriteResult(path: path, state: "written", message: "Runbook written.")
        } catch {
            return AgentRunbookWriteResult(path: path, state: "error", message: error.localizedDescription)
        }
    }

    func runTMAgentRunbook(
        arguments: [String],
        workingDirectory: String? = nil
    ) -> AgentRunbookCommandResult {
        let workdir = workingDirectory ?? fileManager.currentDirectoryPath
        let root = projectRoot(from: workdir)
        guard let executable = tmAgentExecutable(projectRoot: root) else {
            // F7 fix: surface a real error instead of silently `/usr/bin/env` PATH
            // lookup. Caller (Settings UI) renders stderr to the user.
            return AgentRunbookCommandResult(
                exitCode: -1,
                stdout: "",
                stderr: "tm-agent binary not found. Looked in app bundle Resources/bin and /opt/homebrew/bin, /usr/local/bin. Install term-mesh via Homebrew or rebuild the daemon."
            )
        }

        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.executableURL = URL(fileURLWithPath: executable.path)
        process.arguments = executable.arguments + ["runbook"] + arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            return AgentRunbookCommandResult(
                exitCode: process.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        } catch {
            return AgentRunbookCommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription)
        }
    }

    @MainActor
    func openRunbookFolder(workingDirectory: String? = nil) {
        let status = status(workingDirectory: workingDirectory)
        try? fileManager.createDirectory(atPath: status.sourceDir, withIntermediateDirectories: true, attributes: nil)
        NSWorkspace.shared.open(URL(fileURLWithPath: status.sourceDir, isDirectory: true))
    }

    private func hasProjectMarker(at path: String) -> Bool {
        let markers = [
            ".git",
            Self.sourceDirName,
            "AGENTS.md",
            ".claude",
            "GhosttyTabs.xcodeproj",
        ]
        return markers.contains { marker in
            fileManager.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(marker).path)
        }
    }

    private func sourcePath(projectRoot: String, role: String) -> String {
        URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(Self.sourceDirName, isDirectory: true)
            .appendingPathComponent("\(Self.normalizeRoleName(role)).md")
            .path
    }

    private func projectionPath(projectRoot: String, tool: AgentRunbookTool, role: String) -> String {
        let root = URL(fileURLWithPath: projectRoot)
        switch tool {
        case .claude:
            return root
                .appendingPathComponent(".claude/skills/term-mesh-\(role)", isDirectory: true)
                .appendingPathComponent("SKILL.md")
                .path
        case .codex:
            return root
                .appendingPathComponent(".codex/skills/term-mesh-\(role)", isDirectory: true)
                .appendingPathComponent("SKILL.md")
                .path
        case .opencode:
            return root
                .appendingPathComponent(".opencode/runbooks", isDirectory: true)
                .appendingPathComponent("\(role).md")
                .path
        }
    }

    private func fileState(_ path: String) -> AgentRunbookFileState {
        guard fileManager.fileExists(atPath: path) else { return .missing }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return .custom }
        return content.contains(Self.managedMarker) ? .managed : .custom
    }

    private func projectionState(
        path: String,
        tool: AgentRunbookTool,
        role: String,
        sourceContent: String?
    ) -> AgentRunbookFileState {
        guard fileManager.fileExists(atPath: path) else { return .missing }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return .custom }
        guard content.contains(Self.managedMarker) else { return .custom }
        guard let sourceContent else { return .managed }
        return content == toolRunbookContent(tool: tool, role: role, sourceContent: sourceContent) ? .managed : .outdated
    }

    private func stripManagedMarker(from content: String) -> String {
        content
            .replacingOccurrences(of: Self.managedMarker, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendCustomInstructionsIfNeeded(base: String, customInstructions: String?) -> String {
        let custom = (customInstructions ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !custom.isEmpty, custom != base.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return base
        }
        if base.isEmpty {
            return """
            ## Team Custom Instructions

            \(custom)
            """
        }
        return """
        \(base)

        ## Team Custom Instructions

        \(custom)
        """
    }

    private func sourceRunbookContent(for preset: AgentRolePreset) -> String {
        let role = Self.normalizeRoleName(preset.name)
        let title = preset.displayName.isEmpty ? role.capitalized : preset.displayName
        let instructions = preset.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        \(Self.managedMarker)
        # \(title) Runbook

        Generated from the term-mesh role preset `\(role)`.

        ## Role

        `\(role)` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

        ## When To Use

        - Use this role when the leader assigns work that matches the role name and repository context.
        - Prefer repo-specific constraints in this file over generic role assumptions.

        ## Operating Rules

        \(instructions.isEmpty ? "- Follow the leader's task instructions and term-mesh reply protocol." : instructions)

        ## Verify

        - Report the narrowest command or manual check that validates the result.
        - Use `n/a` only when the task is analysis-only or no meaningful verification exists.

        ## Standard Reply Header

        ```text
        STATUS: DONE|BLOCKED|NEEDS_REVIEW
        FILES: <changed paths or none>
        VERIFY: <single shell command or n/a>
        NEXT: <leader action or NONE>
        FULL_REPORT: <absolute result path or n/a>
        ```
        """
    }

    private func toolRunbookContent(tool: AgentRunbookTool, role: String, sourceContent: String) -> String {
        switch tool {
        case .claude, .codex:
            return """
            ---
            name: term-mesh-\(role)
            description: "\(yamlEscape("Use when acting as the \(role) agent in a term-mesh team."))"
            ---
            \(sourceContent)
            """
        case .opencode:
            return sourceContent
        }
    }

    private func yamlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func lintIssues(
        role: String,
        sourceState: AgentRunbookFileState,
        sourceContent: String?
    ) -> [AgentRunbookLintIssue] {
        guard sourceState != .missing else { return [] }
        let content = sourceContent ?? ""
        let requiredSections = [
            "## Role",
            "## When To Use",
            "## Operating Rules",
            "## Verify",
            "## Standard Reply Header",
        ]
        var issues: [AgentRunbookLintIssue] = requiredSections.compactMap { section in
            content.contains(section)
                ? nil
                : AgentRunbookLintIssue(role: role, message: "Missing \(section)")
        }
        if !content.contains(Self.managedMarker), content.trimmingCharacters(in: .whitespacesAndNewlines).count < 120 {
            issues.append(AgentRunbookLintIssue(role: role, message: "Custom runbook is very short"))
        }
        return issues
    }

    private struct TMAgentExecutable {
        let path: String
        let arguments: [String]
    }

    /// Resolve the `tm-agent` binary to spawn for runbook installer commands.
    ///
    /// F3 fix: Release builds must NOT search the user's project directory
    /// (`<projectRoot>/daemon/target/{release,debug}/tm-agent`) before the
    /// signed app bundle. A repo planted with a hostile `daemon/target/release/tm-agent`
    /// would otherwise be executed under the term-mesh app's privileges the
    /// moment the user clicks Init / Install / Force Repair in runbook
    /// Settings. The CWD-relative candidates are kept ONLY in DEBUG builds
    /// (where tm-agent commonly lives in cargo's target dir during dev).
    ///
    /// F7 fix: Drop the `/usr/bin/env tm-agent` fallback. When no known
    /// binary is found we surface a real error path — silently doing PATH
    /// lookup lets a writable PATH entry shadow the system binary.
    private func tmAgentExecutable(projectRoot: String) -> TMAgentExecutable? {
        var candidates: [String] = []
#if DEBUG
        candidates.append(URL(fileURLWithPath: projectRoot).appendingPathComponent("daemon/target/release/tm-agent").path)
        candidates.append(URL(fileURLWithPath: projectRoot).appendingPathComponent("daemon/target/debug/tm-agent").path)
#endif
        if let resourcePath = Bundle.main.resourcePath {
            candidates.append(URL(fileURLWithPath: resourcePath).appendingPathComponent("bin/tm-agent").path)
        }
        candidates.append("/opt/homebrew/bin/tm-agent")
        candidates.append("/usr/local/bin/tm-agent")
        if let path = candidates.first(where: { !$0.isEmpty && fileManager.isExecutableFile(atPath: $0) }) {
            return TMAgentExecutable(path: path, arguments: [])
        }
        return nil
    }
}
