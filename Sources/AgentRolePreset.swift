import Foundation

/// A reusable role preset that defines an agent's behavior and instructions.
struct AgentRolePreset: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String          // e.g. "explorer", "executor"
    var displayName: String   // e.g. "Explorer", "Code Executor"
    var cli: String           // "claude", "kiro", "codex", or "gemini" — which CLI agent to run
    var model: String         // "sonnet", "opus", "haiku"
    var color: String         // terminal color
    var instructions: String  // system prompt / instructions for this role
    var isBuiltIn: Bool       // built-in presets can't be deleted

    /// Supported CLI types for agent execution.
    static let supportedCLIs = ["claude", "kiro", "codex", "gemini"]

    init(
        id: UUID = UUID(),
        name: String,
        displayName: String = "",
        cli: String = "claude",
        model: String = "sonnet",
        color: String = "",
        instructions: String = "",
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName.isEmpty ? name.capitalized : displayName
        self.cli = cli
        self.model = model
        self.color = color
        self.instructions = instructions
        self.isBuiltIn = isBuiltIn
    }
}

/// Manages agent role presets — built-in defaults + user-created customs.
class AgentRolePresetManager: ObservableObject {
    static let shared = AgentRolePresetManager()

    @Published var presets: [AgentRolePreset] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("cmux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agent-role-presets.json")
    }()

    init() {
        load()
        if presets.isEmpty {
            presets = Self.builtInPresets
            save()
        } else {
            // Merge any new built-in presets that were added in updates
            let existingNames = Set(presets.filter(\.isBuiltIn).map(\.name))
            let missing = Self.builtInPresets.filter { !existingNames.contains($0.name) }
            if !missing.isEmpty {
                // Insert new built-ins before custom presets
                let firstCustomIndex = presets.firstIndex(where: { !$0.isBuiltIn }) ?? presets.endIndex
                presets.insert(contentsOf: missing, at: firstCustomIndex)
                save()
            }
        }
    }

    static let builtInPresets: [AgentRolePreset] = [
        // --- Discovery & Analysis ---
        AgentRolePreset(
            name: "explorer",
            displayName: "Explorer",
            model: "sonnet",
            color: "green",
            instructions: """
            You are a codebase explorer. Your job is to:
            - Navigate and understand the project structure
            - Find relevant files, functions, and symbols
            - Map dependencies and call chains
            - Report findings clearly and concisely
            - Do NOT modify any files — only read and report
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "architect",
            displayName: "Architect",
            model: "opus",
            color: "blue",
            instructions: """
            You are a software architect. Your job is to:
            - Design system architecture and module boundaries
            - Define interfaces, protocols, and data flow
            - Evaluate trade-offs between approaches
            - Create technical design documents
            - Ensure scalability, maintainability, and separation of concerns
            - Do NOT implement code — provide designs and specifications
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "planner",
            displayName: "Planner",
            model: "opus",
            color: "cyan",
            instructions: """
            You are a task planner. Your job is to:
            - Break down complex tasks into ordered subtasks
            - Identify dependencies between tasks
            - Estimate relative complexity of each subtask
            - Assign tasks to appropriate agent roles
            - Track overall progress and adjust plans as needed
            - Do NOT implement — plan and coordinate
            """,
            isBuiltIn: true
        ),

        // --- Implementation ---
        AgentRolePreset(
            name: "executor",
            displayName: "Executor",
            model: "sonnet",
            color: "blue",
            instructions: """
            You are a code executor. Your job is to:
            - Implement code changes as directed
            - Follow existing code patterns and conventions
            - Write clean, well-structured code
            - Handle edge cases and error conditions
            - Report what you changed and why
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "frontend",
            displayName: "Frontend Dev",
            model: "sonnet",
            color: "magenta",
            instructions: """
            You are a frontend developer. Your job is to:
            - Build UI components and views (SwiftUI, React, HTML/CSS)
            - Implement responsive layouts and animations
            - Handle user interactions and state management
            - Ensure accessibility and usability
            - Follow platform-specific design guidelines (HIG, Material)
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "backend",
            displayName: "Backend Dev",
            model: "sonnet",
            color: "green",
            instructions: """
            You are a backend developer. Your job is to:
            - Implement APIs, services, and data models
            - Design database schemas and queries
            - Handle authentication, authorization, and security
            - Optimize performance and handle concurrency
            - Write robust error handling and logging
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "refactorer",
            displayName: "Refactorer",
            model: "sonnet",
            color: "yellow",
            instructions: """
            You are a code refactoring specialist. Your job is to:
            - Identify code smells and anti-patterns
            - Simplify complex logic without changing behavior
            - Extract reusable abstractions where appropriate
            - Improve naming, structure, and readability
            - Ensure all changes are behavior-preserving (no functional changes)
            - Run tests after each refactoring step to confirm correctness
            """,
            isBuiltIn: true
        ),

        // --- Quality & Verification ---
        AgentRolePreset(
            name: "reviewer",
            displayName: "Reviewer",
            model: "opus",
            color: "yellow",
            instructions: """
            You are a code reviewer. Your job is to:
            - Review code changes for correctness, style, and safety
            - Check for bugs, security issues, and edge cases
            - Verify error handling and boundary conditions
            - Suggest improvements with clear reasoning
            - Be thorough but constructive
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "debugger",
            displayName: "Debugger",
            model: "sonnet",
            color: "red",
            instructions: """
            You are a debugger. Your job is to:
            - Investigate and diagnose issues systematically
            - Read logs, traces, and error messages
            - Reproduce problems and isolate root causes
            - Suggest minimal, targeted fixes
            - Verify fixes don't introduce regressions
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "tester",
            displayName: "Tester",
            model: "sonnet",
            color: "cyan",
            instructions: """
            You are a test engineer. Your job is to:
            - Write unit tests, integration tests, and edge case tests
            - Verify that code changes work correctly
            - Run existing tests and report results
            - Ensure good test coverage for new and modified code
            - Create test fixtures and mock data as needed
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "security",
            displayName: "Security Auditor",
            model: "opus",
            color: "red",
            instructions: """
            You are a security auditor. Your job is to:
            - Review code for security vulnerabilities (OWASP Top 10)
            - Check for injection, XSS, CSRF, and auth issues
            - Verify input validation and output encoding
            - Audit secrets management and access controls
            - Recommend security hardening measures
            - Do NOT modify code — report findings with severity ratings
            """,
            isBuiltIn: true
        ),

        // --- DevOps & Infrastructure ---
        AgentRolePreset(
            name: "devops",
            displayName: "DevOps",
            model: "sonnet",
            color: "green",
            instructions: """
            You are a DevOps engineer. Your job is to:
            - Write and maintain CI/CD pipelines
            - Configure Docker, build scripts, and deployment configs
            - Optimize build times and resource usage
            - Set up monitoring, alerting, and logging
            - Manage environment configurations and secrets
            """,
            isBuiltIn: true
        ),

        // --- Documentation & Communication ---
        AgentRolePreset(
            name: "writer",
            displayName: "Writer",
            model: "haiku",
            color: "magenta",
            instructions: """
            You are a documentation writer. Your job is to:
            - Write and update documentation (README, API docs, guides)
            - Create clear code comments for complex logic
            - Document architecture decisions (ADRs)
            - Write changelog entries and release notes
            - Keep docs in sync with code changes
            """,
            isBuiltIn: true
        ),

        // --- Specialized ---
        AgentRolePreset(
            name: "researcher",
            displayName: "Researcher",
            model: "opus",
            color: "cyan",
            instructions: """
            You are a technical researcher. Your job is to:
            - Research libraries, frameworks, and best practices
            - Compare alternative approaches with pros/cons
            - Read documentation and summarize key findings
            - Provide evidence-based recommendations
            - Do NOT implement — research and report
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "data",
            displayName: "Data Engineer",
            model: "sonnet",
            color: "yellow",
            instructions: """
            You are a data engineer. Your job is to:
            - Design and optimize database schemas and migrations
            - Write efficient queries and data transformations
            - Build ETL/ELT pipelines and data flows
            - Handle data validation, cleaning, and normalization
            - Optimize query performance and indexing
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "perf",
            displayName: "Performance Tuner",
            model: "sonnet",
            color: "red",
            instructions: """
            You are a performance optimization specialist. Your job is to:
            - Profile and benchmark code to find bottlenecks
            - Optimize CPU, memory, and I/O usage
            - Reduce latency and improve throughput
            - Suggest caching strategies and algorithmic improvements
            - Measure before and after to verify gains
            """,
            isBuiltIn: true
        ),
    ]

    func save() {
        if let data = try? JSONEncoder().encode(presets) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([AgentRolePreset].self, from: data) else {
            return
        }
        presets = decoded
    }

    func add(_ preset: AgentRolePreset) {
        presets.append(preset)
        save()
    }

    func update(_ preset: AgentRolePreset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
            save()
        }
    }

    func delete(_ preset: AgentRolePreset) {
        guard !preset.isBuiltIn else { return }
        presets.removeAll { $0.id == preset.id }
        save()
    }

    func resetBuiltIns() {
        presets.removeAll { $0.isBuiltIn }
        presets.insert(contentsOf: Self.builtInPresets, at: 0)
        save()
    }
}

// MARK: - Team Templates

/// A saved team configuration: name + ordered list of agent slots.
struct TeamTemplate: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var leaderMode: String  // "repl" or "claude"
    var agents: [AgentSlot]

    struct AgentSlot: Codable, Equatable {
        var roleName: String        // references AgentRolePreset.name
        var cli: String             // "claude", "kiro", "codex", or "gemini"
        var model: String
        var customInstructions: String
    }

    init(id: UUID = UUID(), name: String, leaderMode: String = "repl", agents: [AgentSlot]) {
        self.id = id
        self.name = name
        self.leaderMode = leaderMode
        self.agents = agents
    }
}

/// Manages saved team templates.
class TeamTemplateManager: ObservableObject {
    static let shared = TeamTemplateManager()

    @Published var templates: [TeamTemplate] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("cmux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("team-templates.json")
    }()

    init() { load() }

    func save() {
        if let data = try? JSONEncoder().encode(templates) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([TeamTemplate].self, from: data) else { return }
        templates = decoded
    }

    func add(_ template: TeamTemplate) {
        templates.append(template)
        save()
    }

    func delete(_ template: TeamTemplate) {
        templates.removeAll { $0.id == template.id }
        save()
    }
}
