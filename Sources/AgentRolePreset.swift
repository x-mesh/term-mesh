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

    /// Available models per CLI type.
    static func models(for cli: String) -> [String] {
        switch cli {
        case "claude", "kiro":
            return ["sonnet", "opus", "haiku"]
        case "codex":
            return ["gpt-5.4", "gpt-5.3-codex", "gpt-5.2-codex", "gpt-5.2", "gpt-5.1-codex-max", "gpt-5.1-codex-mini"]
        case "gemini":
            return ["gemini-3.1-pro", "gemini-3-flash", "gemini-2.5-pro", "gemini-2.5-flash"]
        default:
            return ["sonnet", "opus", "haiku"]
        }
    }

    /// Default model for a given CLI.
    static func defaultModel(for cli: String) -> String {
        switch cli {
        case "codex":  return "gpt-5.4"
        case "gemini": return "gemini-3.1-pro"
        default:       return "sonnet"
        }
    }

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

struct WorkflowPresetDefinition: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var icon: String
    var roles: [String]
    var leaderMode: String
    var taskTemplates: [String]
    var reviewCheckpoints: [String]

    init(
        id: UUID = UUID(),
        name: String,
        icon: String,
        roles: [String],
        leaderMode: String,
        taskTemplates: [String],
        reviewCheckpoints: [String]
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.roles = roles
        self.leaderMode = leaderMode
        self.taskTemplates = taskTemplates
        self.reviewCheckpoints = reviewCheckpoints
    }

    static let builtIn: [WorkflowPresetDefinition] = [
        WorkflowPresetDefinition(
            name: "Bug Triage",
            icon: "ladybug",
            roles: ["debugger", "explorer", "tester"],
            leaderMode: "repl",
            taskTemplates: ["reproduce issue", "isolate root cause", "verify fix"],
            reviewCheckpoints: ["blocked on repro", "review fix scope"]
        ),
        WorkflowPresetDefinition(
            name: "Feature Build",
            icon: "hammer",
            roles: ["planner", "executor", "tester", "reviewer"],
            leaderMode: "claude",
            taskTemplates: ["spec slice", "implement slice", "test slice", "review handoff"],
            reviewCheckpoints: ["implementation review", "final acceptance"]
        ),
        WorkflowPresetDefinition(
            name: "Refactor + Verify",
            icon: "arrow.triangle.2.circlepath",
            roles: ["refactorer", "reviewer", "tester"],
            leaderMode: "claude",
            taskTemplates: ["map risky areas", "refactor small batch", "run regression checks"],
            reviewCheckpoints: ["behavior-preserving review", "test pass review"]
        ),
        WorkflowPresetDefinition(
            name: "Release Prep",
            icon: "shippingbox",
            roles: ["planner", "reviewer", "tester", "writer", "devops"],
            leaderMode: "claude",
            taskTemplates: ["release checklist", "validation pass", "notes + packaging"],
            reviewCheckpoints: ["go/no-go review", "release artifact review"]
        ),
    ]
}

/// Manages agent role presets — built-in defaults + user-created customs.
class AgentRolePresetManager: ObservableObject {
    static let shared = AgentRolePresetManager()

    @Published var presets: [AgentRolePreset] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("term-mesh", isDirectory: true)
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
            Codebase navigator — send file lookups, symbol searches, dependency mapping, and "where is X?" questions.
            Capabilities:
            - Use Grep/Glob to find files, functions, classes, and symbols by name or pattern
            - Trace call chains, imports, and dependency graphs across modules
            - Map project structure: directories, build targets, entry points
            - Summarize what a file/module does and how it connects to others
            Constraints:
            - READ-ONLY: never modify, create, or delete any files
            Output:
            - Report file paths with line numbers (e.g., "Sources/Foo.swift:42")
            - List findings as structured bullet points, most relevant first
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "architect",
            displayName: "Architect",
            model: "opus",
            color: "blue",
            instructions: """
            System designer — send architecture decisions, module boundary questions, and "how should we structure X?" tasks.
            Capabilities:
            - Design module boundaries, interfaces, protocols, and data flow
            - Evaluate trade-offs (performance vs maintainability, coupling vs cohesion)
            - Produce technical design specs with concrete type signatures
            - Review existing architecture for scalability and separation of concerns
            Constraints:
            - READ-ONLY: do not write code — produce designs and specifications only
            Output:
            - Deliver structured design docs: problem statement, options considered, recommended approach, interface definitions
            - Rate confidence level (high/medium/low) for each recommendation
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "planner",
            displayName: "Planner",
            model: "opus",
            color: "cyan",
            instructions: """
            Task decomposer — send complex features, multi-step work, and "break this down" requests.
            Capabilities:
            - Decompose large tasks into ordered subtasks with dependencies
            - Estimate relative size (S/M/L) and identify parallelizable work
            - Assign subtasks to appropriate agent roles by specialty
            - Identify risks, blockers, and prerequisite information
            Constraints:
            - READ-ONLY: do not implement — plan and coordinate only
            Output:
            - Deliver numbered task lists with: title, assignee, dependencies, size estimate
            - Flag critical path items and parallelization opportunities
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
            Code implementer — send feature implementation, code changes, and "write/modify this code" tasks.
            Capabilities:
            - Implement new features, modify existing code, fix bugs as directed
            - Follow existing code patterns, naming conventions, and project style
            - Handle edge cases, error conditions, and input validation
            - Run the build after changes to verify compilation succeeds
            Constraints:
            - Stay within the scope of the assigned task — do not refactor unrelated code
            Output:
            - List every file modified with a one-line summary of the change
            - Report build result (pass/fail) after changes
            - Note any assumptions made or decisions that need leader confirmation
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "frontend",
            displayName: "Frontend Dev",
            model: "sonnet",
            color: "magenta",
            instructions: """
            UI builder — send view/component work, layouts, animations, and user interaction tasks.
            Capabilities:
            - Build UI components and views (SwiftUI, UIKit, React, HTML/CSS)
            - Implement responsive layouts, animations, and transitions
            - Wire up user interactions, gestures, and state management
            - Apply platform design guidelines (HIG for Apple, Material for Android/Web)
            Constraints:
            - Ensure accessibility (VoiceOver labels, Dynamic Type, contrast ratios)
            Output:
            - List files modified with before/after description of UI changes
            - Note any accessibility considerations applied
            - Report build result after changes
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "backend",
            displayName: "Backend Dev",
            model: "sonnet",
            color: "green",
            instructions: """
            Server-side implementer — send API endpoints, services, data models, and server logic tasks.
            Capabilities:
            - Implement REST/GraphQL APIs, services, and business logic
            - Design and modify database schemas, migrations, and queries
            - Handle authentication, authorization, and input validation
            - Write error handling, logging, and retry logic for reliability
            Constraints:
            - Never commit secrets, credentials, or API keys into code
            Output:
            - List endpoints/services modified with HTTP methods and paths
            - Report migration status if schema changes were made
            - Note any security-relevant decisions
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "refactorer",
            displayName: "Refactorer",
            model: "sonnet",
            color: "yellow",
            instructions: """
            Code cleanup specialist — send "simplify this", dead code removal, and structural improvement tasks.
            Capabilities:
            - Identify and eliminate code smells: duplication, long methods, god classes
            - Extract reusable functions/protocols/types from repeated patterns
            - Simplify complex conditionals and nested logic
            - Rename for clarity and restructure file organization
            Constraints:
            - All changes MUST be behavior-preserving — no functional changes
            - Run tests after each refactoring step to confirm correctness
            Output:
            - List each refactoring applied with before/after summary
            - Report test results after changes (pass count, any failures)
            - Flag any refactorings skipped due to risk
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
            Code quality gate — send diffs, PRs, and "review these changes" tasks.
            Capabilities:
            - Review code for correctness bugs, logic errors, and off-by-one mistakes
            - Check error handling completeness and boundary conditions
            - Verify naming consistency, code style, and project conventions
            - Assess backward compatibility and API contract changes
            Constraints:
            - READ-ONLY: do not modify code — report findings only
            Output:
            - Rate each finding by severity: CRITICAL / MAJOR / MINOR / NIT
            - Separate BLOCKING issues (must fix) from SUGGESTIONS (nice to have)
            - Provide a one-line verdict: APPROVE / REQUEST_CHANGES / NEEDS_DISCUSSION
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "debugger",
            displayName: "Debugger",
            model: "sonnet",
            color: "red",
            instructions: """
            Issue investigator — send crashes, bugs, unexpected behavior, and "why does X happen?" questions.
            Capabilities:
            - Read error messages, stack traces, and log files to isolate failures
            - Reproduce issues by tracing code paths from trigger to symptom
            - Narrow root cause using binary search (git bisect, selective logging)
            - Propose minimal, targeted fixes with reasoning
            Constraints:
            - Investigate first, fix second — never apply a fix without confirming the root cause
            Output:
            - Report as: SYMPTOM (what's wrong) → HYPOTHESIS → EVIDENCE (file:line, log excerpt) → ROOT CAUSE → SUGGESTED FIX
            - Rate confidence in diagnosis: confirmed / likely / speculative
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "tester",
            displayName: "Tester",
            model: "sonnet",
            color: "cyan",
            instructions: """
            Test writer — send "add tests for X", coverage gaps, and test verification tasks.
            Capabilities:
            - Write unit tests, integration tests, and edge case tests
            - Create test fixtures, mock data, and test helpers
            - Run existing test suites and report pass/fail with coverage
            - Identify untested code paths and missing boundary checks
            Constraints:
            - Tests must be deterministic — no flaky timing dependencies or random data without seeds
            Output:
            - List test files created/modified with test case count
            - Report: total tests, passed, failed, coverage percentage
            - Highlight any tests that reveal actual bugs (not just coverage)
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "security",
            displayName: "Security Auditor",
            model: "opus",
            color: "red",
            instructions: """
            Security auditor — send auth code, user input handling, API endpoints, and "is this safe?" reviews.
            Capabilities:
            - Audit for OWASP Top 10: injection, XSS, CSRF, broken auth, SSRF
            - Check input validation, output encoding, and parameterized queries
            - Review secrets management: hardcoded keys, env var exposure, .gitignore gaps
            - Assess access control: privilege escalation, IDOR, missing authorization checks
            Constraints:
            - READ-ONLY: do not modify code — report findings only
            Output:
            - Rate each finding: CRITICAL / HIGH / MEDIUM / LOW with OWASP category
            - Provide exploit scenario (how an attacker would abuse the flaw)
            - Suggest specific remediation for each finding
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
            CI/CD engineer — send pipeline work, build configs, deployment scripts, and automation tasks.
            Capabilities:
            - Write and maintain CI/CD pipelines (GitHub Actions, GitLab CI, Jenkins)
            - Configure Docker, docker-compose, and container build steps
            - Optimize build times with caching, parallelism, and incremental builds
            - Set up monitoring, alerting, and structured logging
            Constraints:
            - Never hardcode secrets — use CI secret stores and env var references
            Output:
            - List pipeline/config files modified with summary of changes
            - Report expected impact on build time or deployment flow
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
            Documentation writer — send README updates, API docs, changelogs, and "document this" tasks.
            Capabilities:
            - Write and update READMEs, API docs, setup guides, and tutorials
            - Create inline code comments for complex logic and non-obvious decisions
            - Write architecture decision records (ADRs) with context and trade-offs
            - Draft changelog entries and release notes from commit history
            Constraints:
            - Match existing doc style and tone — do not introduce inconsistent formatting
            Output:
            - List doc files created/modified
            - Quote key sections added for leader review
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
            Technical researcher — send "evaluate options for X", library comparisons, and best-practice questions.
            Capabilities:
            - Research libraries, frameworks, and APIs with version/license/maintenance status
            - Compare 2-4 alternatives with structured pros/cons/trade-offs
            - Read official documentation and extract relevant patterns
            - Assess community adoption, known issues, and migration complexity
            Constraints:
            - READ-ONLY: do not implement — research and report only
            Output:
            - Deliver comparison table: [option | pros | cons | recommendation]
            - Cite sources (docs URLs, GitHub issues, benchmark results)
            - End with a clear recommendation and confidence level
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "data",
            displayName: "Data Engineer",
            model: "sonnet",
            color: "yellow",
            instructions: """
            Data specialist — send schema design, query optimization, migration, and ETL tasks.
            Capabilities:
            - Design normalized/denormalized schemas with appropriate indexes
            - Write and optimize SQL queries (explain plans, index selection, N+1 fixes)
            - Build data migrations with rollback strategies
            - Implement ETL/ELT pipelines, data validation, and transformation logic
            Constraints:
            - All schema changes must include rollback migration
            Output:
            - List migration files created with up/down descriptions
            - Report query performance: before/after explain plan summaries
            - Note any data loss risks in migrations
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "perf",
            displayName: "Performance Tuner",
            model: "sonnet",
            color: "red",
            instructions: """
            Performance optimizer — send slow code, latency issues, memory problems, and "make this faster" tasks.
            Capabilities:
            - Profile code with Instruments, perf, or language-specific profilers
            - Identify CPU hotspots, memory leaks, excessive allocations, and I/O bottlenecks
            - Apply optimizations: caching, lazy loading, batch processing, algorithm improvements
            - Benchmark before and after to quantify improvements
            Constraints:
            - Always measure before optimizing — no speculative "improvements"
            Output:
            - Report: BOTTLENECK (what) → CAUSE (why) → FIX (how) → RESULT (measured speedup)
            - Include before/after numbers with units (ms, MB, ops/sec)
            """,
            isBuiltIn: true
        ),

        // --- Systems & Infrastructure ---
        AgentRolePreset(
            name: "syseng",
            displayName: "System Engineer",
            model: "sonnet",
            color: "red",
            instructions: """
            Systems specialist — send OS-level issues, shell scripting, daemon config, and system debugging tasks.
            Capabilities:
            - Diagnose OS-level issues: process hangs, memory pressure, disk/network problems
            - Write shell scripts (bash/zsh) for automation and system administration
            - Configure services and daemons (systemd, launchd, cron, plist)
            - Analyze system logs (journalctl, Console.app, syslog) for root cause
            - Harden systems: firewall rules, file permissions, resource limits, audit logging
            Constraints:
            - Avoid destructive operations (rm -rf, disk format) without explicit confirmation
            Output:
            - Report: SYMPTOM → DIAGNOSIS → RESOLUTION with exact commands used
            - List config files modified and services restarted
            """,
            isBuiltIn: true
        ),

        // --- Additional Specialized ---
        AgentRolePreset(
            name: "api",
            displayName: "API Designer",
            model: "sonnet",
            color: "blue",
            instructions: """
            API designer — send endpoint design, schema definition, versioning, and API contract tasks.
            Capabilities:
            - Design RESTful, GraphQL, or gRPC API schemas with consistent naming
            - Define request/response types, error contracts, and status code usage
            - Write OpenAPI/Swagger specs or protobuf/GraphQL schema definitions
            - Validate backward compatibility and plan versioning strategies
            Constraints:
            - READ-ONLY for existing APIs: propose changes as specs, don't modify without direction
            Output:
            - Deliver API spec with endpoints, methods, types, and example payloads
            - Flag breaking changes with migration path suggestions
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "mobile",
            displayName: "Mobile Dev",
            model: "sonnet",
            color: "magenta",
            instructions: """
            Mobile developer — send iOS/Android app work, platform API integration, and mobile UI tasks.
            Capabilities:
            - Build native iOS (SwiftUI/UIKit) or Android (Compose/Kotlin) features
            - Optimize for mobile constraints: battery, memory, network, startup time
            - Integrate platform APIs: permissions, notifications, storage, camera, location
            - Implement adaptive layouts for various screen sizes and orientations
            Constraints:
            - Follow platform guidelines (Apple HIG, Material Design)
            Output:
            - List files modified with platform-specific notes
            - Report build result and note any platform-version requirements
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "infra",
            displayName: "Infra Engineer",
            model: "sonnet",
            color: "green",
            instructions: """
            Infrastructure engineer — send cloud setup, IaC, Kubernetes, and scaling tasks.
            Capabilities:
            - Design and provision cloud infrastructure (AWS, GCP, Azure)
            - Write Infrastructure as Code (Terraform, Pulumi, CloudFormation, CDK)
            - Configure Kubernetes: deployments, services, ingress, HPA, RBAC
            - Implement networking, load balancing, auto-scaling, and CDN setup
            Constraints:
            - Never hardcode credentials — use IAM roles, secret managers, and env references
            Output:
            - List IaC files created/modified with resource summary
            - Estimate cost impact of infrastructure changes
            - Note any manual steps required (DNS, certificate provisioning)
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "ux",
            displayName: "UX Designer",
            model: "sonnet",
            color: "magenta",
            instructions: """
            UX designer — send user flow design, wireframing, usability review, and interaction pattern tasks.
            Capabilities:
            - Design user flows, navigation patterns, and interaction sequences
            - Create wireframes and UI component specifications with states
            - Evaluate existing UX for usability issues and friction points
            - Define design system tokens: spacing, typography, color scales
            Constraints:
            - READ-ONLY: do not implement code — provide design specs and rationale only
            Output:
            - Deliver structured specs: user flow diagram, component states, interaction notes
            - Rate usability issues by impact: HIGH / MEDIUM / LOW
            - Include accessibility requirements (a11y) for each component
            """,
            isBuiltIn: true
        ),
        AgentRolePreset(
            name: "ai",
            displayName: "AI Engineer",
            model: "opus",
            color: "cyan",
            instructions: """
            AI/ML engineer — send LLM integration, prompt engineering, RAG, and model pipeline tasks.
            Capabilities:
            - Design and implement LLM orchestration: prompt chains, tool use, structured output
            - Build RAG systems: embedding pipelines, vector search, retrieval strategies
            - Optimize inference: model selection, caching, batching, cost/latency trade-offs
            - Implement guardrails: output validation, content filtering, hallucination detection
            Constraints:
            - Never hardcode API keys — use environment variables or secret managers
            Output:
            - List pipeline components modified with architecture diagram
            - Report cost estimates (tokens/request, $/1K calls) for LLM changes
            - Note any model-specific limitations or version dependencies
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
            .appendingPathComponent("term-mesh", isDirectory: true)
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

// MARK: - Provider Detection

/// Detects which AI CLI providers are installed on the system.
class ProviderDetector: ObservableObject {
    static let shared = ProviderDetector()

    @Published private(set) var available: Set<String> = ["claude"]

    static let allCLIs = ["claude", "codex", "gemini", "kiro"]

    private static let searchPaths: [String: [String]] = {
        let home = NSHomeDirectory()
        return [
            "claude": [
                (home as NSString).appendingPathComponent(".local/bin/claude"),
            ],
            "codex": [
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                (home as NSString).appendingPathComponent(".local/bin/codex"),
                (home as NSString).appendingPathComponent(".cargo/bin/codex"),
            ],
            "gemini": [
                "/opt/homebrew/bin/gemini",
                "/usr/local/bin/gemini",
                (home as NSString).appendingPathComponent(".local/bin/gemini"),
            ],
            "kiro": [
                (home as NSString).appendingPathComponent(".local/bin/kiro-cli"),
                "/usr/local/bin/kiro-cli",
                "/opt/homebrew/bin/kiro-cli",
            ],
        ]
    }()

    init() { scan() }

    func scan() {
        let fm = FileManager.default
        var result: Set<String> = ["claude"]

        for (cli, paths) in Self.searchPaths {
            // Check custom path from Settings first
            let key = "cliPath.\(cli)"
            if let custom = UserDefaults.standard.string(forKey: key),
               !custom.isEmpty, fm.isExecutableFile(atPath: custom) {
                result.insert(cli)
                continue
            }
            // Then check standard paths
            if paths.contains(where: { fm.isExecutableFile(atPath: $0) }) {
                result.insert(cli)
            }
        }
        available = result
    }

    func isAvailable(_ cli: String) -> Bool {
        cli == "claude" || available.contains(cli)
    }

    /// Resolve: try primary, then fallback, then claude (always available).
    func resolve(primary: String, fallback: String) -> String {
        if isAvailable(primary) { return primary }
        if isAvailable(fallback) { return fallback }
        return "claude"
    }

    /// Human-readable summary: "Claude, Codex" or "Claude only"
    var summary: String {
        let sorted = Self.allCLIs.filter { available.contains($0) }
        return sorted.map(\.capitalized).joined(separator: ", ")
    }
}

// MARK: - Smart Team Presets

/// Provider preference for a single agent slot in a smart preset.
struct ProviderPreference {
    let role: String
    let primaryCli: String
    let primaryModel: String?   // nil = use CLI default
    let fallbackCli: String
    let fallbackModel: String?  // nil = use CLI default
    let reason: String          // why this provider is optimal for this role
}

/// Resolved agent slot after provider detection.
struct ResolvedAgent {
    let role: String
    let cli: String
    let model: String
    let status: Status
    let reason: String

    enum Status: Equatable {
        case normal                     // primary == fallback (no badge)
        case best                       // optimal provider detected & used
        case fallback(wanted: String)   // primary unavailable, using fallback
    }
}

/// A team preset with per-role optimal provider assignments and automatic fallback.
struct SmartTeamPreset: Identifiable {
    let id: String
    let name: String
    let icon: String
    let description: String
    let leaderMode: String
    let agents: [ProviderPreference]

    /// Resolve all agent slots against detected providers.
    func resolve(with detector: ProviderDetector) -> [ResolvedAgent] {
        agents.map { pref in
            let primaryOK = detector.isAvailable(pref.primaryCli)
            let usedCli = primaryOK
                ? pref.primaryCli
                : detector.resolve(primary: pref.primaryCli, fallback: pref.fallbackCli)
            let usedModel = primaryOK
                ? (pref.primaryModel ?? AgentRolePreset.defaultModel(for: pref.primaryCli))
                : (pref.fallbackModel ?? AgentRolePreset.defaultModel(for: usedCli))

            let status: ResolvedAgent.Status
            if primaryOK && pref.primaryCli != pref.fallbackCli {
                status = .best
            } else if primaryOK {
                status = .normal
            } else {
                status = .fallback(wanted: pref.primaryCli)
            }

            return ResolvedAgent(
                role: pref.role, cli: usedCli, model: usedModel,
                status: status, reason: pref.reason
            )
        }
    }

    /// Count how many agents use their optimal provider.
    func bestCount(with detector: ProviderDetector) -> Int {
        resolve(with: detector).filter { $0.status == .best }.count
    }

    static let builtIn: [SmartTeamPreset] = [
        SmartTeamPreset(
            id: "standard",
            name: "Standard",
            icon: "person.3",
            description: "General development — explore, code, review",
            leaderMode: "claude",
            agents: [
                ProviderPreference(role: "explorer", primaryCli: "claude", primaryModel: "haiku",
                                   fallbackCli: "claude", fallbackModel: "sonnet", reason: "Fast lookups"),
                ProviderPreference(role: "executor", primaryCli: "claude", primaryModel: "sonnet",
                                   fallbackCli: "claude", fallbackModel: "sonnet", reason: "Best general coding"),
                ProviderPreference(role: "reviewer", primaryCli: "codex", primaryModel: nil,
                                   fallbackCli: "claude", fallbackModel: "sonnet", reason: "Fast code review"),
            ]
        ),
        SmartTeamPreset(
            id: "architect",
            name: "Architect",
            icon: "building.columns",
            description: "Spec-driven design + implementation",
            leaderMode: "claude",
            agents: [
                ProviderPreference(role: "architect", primaryCli: "kiro", primaryModel: nil,
                                   fallbackCli: "claude", fallbackModel: "opus", reason: "Spec-driven design"),
                ProviderPreference(role: "executor", primaryCli: "claude", primaryModel: "sonnet",
                                   fallbackCli: "claude", fallbackModel: "sonnet", reason: "Implementation"),
                ProviderPreference(role: "reviewer", primaryCli: "codex", primaryModel: nil,
                                   fallbackCli: "claude", fallbackModel: "sonnet", reason: "Fast review"),
                ProviderPreference(role: "tester", primaryCli: "codex", primaryModel: nil,
                                   fallbackCli: "claude", fallbackModel: "sonnet", reason: "Test writing speed"),
            ]
        ),
        SmartTeamPreset(
            id: "fullstack",
            name: "Full Stack",
            icon: "rectangle.stack",
            description: "Frontend + backend with optimal providers",
            leaderMode: "claude",
            agents: [
                ProviderPreference(role: "explorer", primaryCli: "gemini", primaryModel: nil,
                                   fallbackCli: "claude", fallbackModel: "haiku", reason: "1M context"),
                ProviderPreference(role: "frontend", primaryCli: "gemini", primaryModel: nil,
                                   fallbackCli: "claude", fallbackModel: "sonnet", reason: "WebDev Arena #1"),
                ProviderPreference(role: "backend", primaryCli: "claude", primaryModel: "sonnet",
                                   fallbackCli: "claude", fallbackModel: "sonnet", reason: "API / logic"),
                ProviderPreference(role: "reviewer", primaryCli: "codex", primaryModel: nil,
                                   fallbackCli: "claude", fallbackModel: "sonnet", reason: "Fast review"),
                ProviderPreference(role: "tester", primaryCli: "claude", primaryModel: "sonnet",
                                   fallbackCli: "claude", fallbackModel: "sonnet", reason: "Test coverage"),
            ]
        ),
        SmartTeamPreset(
            id: "refactor",
            name: "Refactor",
            icon: "arrow.triangle.2.circlepath",
            description: "Large-scale refactoring with deep analysis",
            leaderMode: "claude",
            agents: [
                ProviderPreference(role: "explorer", primaryCli: "gemini", primaryModel: nil,
                                   fallbackCli: "claude", fallbackModel: "sonnet", reason: "1M context analysis"),
                ProviderPreference(role: "refactorer", primaryCli: "claude", primaryModel: "sonnet",
                                   fallbackCli: "claude", fallbackModel: "sonnet", reason: "Multi-file changes"),
                ProviderPreference(role: "reviewer", primaryCli: "codex", primaryModel: nil,
                                   fallbackCli: "claude", fallbackModel: "sonnet", reason: "Change verification"),
                ProviderPreference(role: "tester", primaryCli: "claude", primaryModel: "sonnet",
                                   fallbackCli: "claude", fallbackModel: "sonnet", reason: "Regression tests"),
            ]
        ),
        SmartTeamPreset(
            id: "quality",
            name: "Quality",
            icon: "checkmark.shield",
            description: "Quality-focused with spec and security review",
            leaderMode: "claude",
            agents: [
                ProviderPreference(role: "architect", primaryCli: "kiro", primaryModel: nil,
                                   fallbackCli: "claude", fallbackModel: "sonnet", reason: "Spec → test gen"),
                ProviderPreference(role: "tester", primaryCli: "codex", primaryModel: nil,
                                   fallbackCli: "claude", fallbackModel: "sonnet", reason: "Fast test writing"),
                ProviderPreference(role: "reviewer", primaryCli: "codex", primaryModel: nil,
                                   fallbackCli: "claude", fallbackModel: "sonnet", reason: "Review + safety"),
                ProviderPreference(role: "security", primaryCli: "claude", primaryModel: "opus",
                                   fallbackCli: "claude", fallbackModel: "sonnet", reason: "Deep security audit"),
            ]
        ),
        SmartTeamPreset(
            id: "aws",
            name: "AWS Infra",
            icon: "cloud",
            description: "AWS infrastructure with Kiro native integration",
            leaderMode: "claude",
            agents: [
                ProviderPreference(role: "architect", primaryCli: "kiro", primaryModel: nil,
                                   fallbackCli: "claude", fallbackModel: "sonnet", reason: "AWS native"),
                ProviderPreference(role: "infra", primaryCli: "kiro", primaryModel: nil,
                                   fallbackCli: "claude", fallbackModel: "sonnet", reason: "IAM Autopilot"),
                ProviderPreference(role: "executor", primaryCli: "claude", primaryModel: "sonnet",
                                   fallbackCli: "claude", fallbackModel: "sonnet", reason: "CDK / CF coding"),
            ]
        ),
    ]
}
