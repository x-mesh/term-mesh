use super::*;

// ── Task template system ─────────────────────────────────────────────

/// Parse `key=value` CLI arg for `--var`.
pub(crate) fn parse_template_var(s: &str) -> Result<(String, String), String> {
    s.split_once('=')
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .ok_or_else(|| format!("expected key=value, got: {s}"))
}

/// A task template with optional variable placeholders (`{{var}}`).
pub(crate) struct TaskTemplate {
    pub(crate) name: String,
    pub(crate) title: String,
    pub(crate) description: Option<String>,
    pub(crate) priority: Option<u32>,
    pub(crate) assign: Option<String>,
}

impl TaskTemplate {
    pub(crate) fn substitute(&self, vars: &[(String, String)]) -> TaskTemplate {
        let apply = |s: &str| {
            let mut out = s.to_string();
            for (k, v) in vars {
                out = out.replace(&format!("{{{{{k}}}}}"), v);
            }
            out
        };
        TaskTemplate {
            name: self.name.clone(),
            title: apply(&self.title),
            description: self.description.as_deref().map(apply),
            priority: self.priority,
            assign: self.assign.clone(),
        }
    }
}

/// Built-in templates hardcoded in binary (no file needed).
pub(crate) fn builtin_templates() -> Vec<TaskTemplate> {
    vec![
        TaskTemplate {
            name: "analysis".into(),
            title: "코드 분석: {{target}}".into(),
            description: Some(
                "{{target}}을 분석하고 다음을 보고하라:\n\
                 - 구조 및 의존성\n\
                 - 잠재적 이슈\n\
                 - 개선 제안"
                    .into(),
            ),
            priority: Some(2),
            assign: Some("explorer".into()),
        },
        TaskTemplate {
            name: "review".into(),
            title: "코드 리뷰: {{target}}".into(),
            description: Some(
                "{{target}}을 리뷰하라:\n\
                 - 버그 및 엣지 케이스\n\
                 - 성능 문제\n\
                 - 보안 취약점\n\
                 - 가독성 및 유지보수성"
                    .into(),
            ),
            priority: Some(2),
            assign: Some("reviewer".into()),
        },
        TaskTemplate {
            name: "implement".into(),
            title: "구현: {{feature}}".into(),
            description: Some(
                "{{feature}}을 구현하라:\n\
                 1. 설계 확인\n\
                 2. 코드 구현\n\
                 3. 테스트 작성\n\
                 4. 결과 보고"
                    .into(),
            ),
            priority: Some(2),
            assign: Some("executor".into()),
        },
    ]
}

/// Parse a minimal YAML template file (key: value / multiline |).
pub(crate) fn parse_template_yaml(content: &str) -> TaskTemplate {
    let mut map: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    let mut current_key = String::new();
    let mut multiline: Vec<String> = Vec::new();
    let mut in_multiline = false;

    for line in content.lines() {
        if in_multiline {
            if line.starts_with("  ") || line.starts_with('\t') {
                multiline.push(line.trim_start().to_string());
                continue;
            } else {
                map.insert(current_key.clone(), multiline.join("\n"));
                multiline.clear();
                in_multiline = false;
            }
        }
        if let Some((k, v)) = line.split_once(':') {
            let k = k.trim().to_string();
            let v = v.trim();
            if v == "|" {
                current_key = k;
                in_multiline = true;
            } else if !v.is_empty() {
                let unquoted = v.trim_matches('"').trim_matches('\'').to_string();
                map.insert(k, unquoted);
            }
        }
    }
    if in_multiline && !multiline.is_empty() {
        map.insert(current_key, multiline.join("\n"));
    }

    TaskTemplate {
        name: map.get("name").cloned().unwrap_or_default(),
        title: map
            .get("title")
            .cloned()
            .unwrap_or_else(|| "{{title}}".into()),
        description: map.get("description").cloned(),
        priority: map.get("priority").and_then(|s| s.parse().ok()),
        assign: map.get("assign").cloned(),
    }
}

/// Load a template: builtin first, then ~/.term-mesh/templates/{name}.yaml.
pub(crate) fn load_template(name: &str) -> Result<TaskTemplate, String> {
    // 1. Check builtin templates
    for t in builtin_templates() {
        if t.name == name {
            return Ok(t);
        }
    }
    // 2. Try user templates dir
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let path = PathBuf::from(home)
        .join(".term-mesh/templates")
        .join(format!("{name}.yaml"));
    let content = std::fs::read_to_string(&path)
        .map_err(|_| format!("template '{}' not found (checked builtin + {path:?})", name))?;
    Ok(parse_template_yaml(&content))
}

/// List all available templates (builtin + files in ~/.term-mesh/templates/).
pub(crate) fn list_all_templates() -> Vec<(String, String)> {
    let mut result: Vec<(String, String)> = builtin_templates()
        .into_iter()
        .map(|t| (t.name, "(builtin)".into()))
        .collect();

    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let dir = PathBuf::from(home).join(".term-mesh/templates");
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.extension().and_then(|e| e.to_str()) == Some("yaml") {
                let name = p
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("")
                    .to_string();
                if !result.iter().any(|(n, _)| n == &name) {
                    result.push((name, dir.display().to_string()));
                }
            }
        }
    }
    result
}

// ── Agent runbook installer ─────────────────────────────────────────

pub(crate) const RUNBOOK_MARKER: &str = "<!-- term-mesh-managed: runbook-installer v1 -->";
pub(crate) const RUNBOOK_SOURCE_DIR: &str = ".agent-runbooks";

#[derive(Clone, Copy)]
pub(crate) enum RunbookTool {
    Claude,
    Codex,
    OpenCode,
    Gemini,
}

impl RunbookTool {
    fn as_str(self) -> &'static str {
        match self {
            RunbookTool::Claude => "claude",
            RunbookTool::Codex => "codex",
            RunbookTool::OpenCode => "opencode",
            RunbookTool::Gemini => "gemini",
        }
    }
}

pub(crate) struct RunbookRole {
    name: &'static str,
    title: &'static str,
    description: &'static str,
    when_to_use: &'static [&'static str],
    rules: &'static [&'static str],
    verify: &'static [&'static str],
}

pub(crate) fn builtin_runbook_roles() -> Vec<RunbookRole> {
    vec![
        RunbookRole {
            name: "explorer",
            title: "Explorer Runbook",
            description: "Read-only codebase exploration and symbol tracing.",
            when_to_use: &[
                "The task asks where something is defined, who calls it, or how modules depend on each other.",
                "The leader needs precise context before code is changed.",
            ],
            rules: &[
                "Use rg or rg --files first for searches.",
                "Return findings as path:line plus one concise role sentence.",
                "Do not edit files unless the leader explicitly changes your role.",
                "Prefer exact call sites, ownership boundaries, and dependency edges over broad summaries.",
            ],
            verify: &[
                "Include the exact search command or pattern family you used when absence matters.",
                "If no match is found, say what paths or symbols were checked.",
            ],
        },
        RunbookRole {
            name: "executor",
            title: "Executor Runbook",
            description: "Scoped implementation work with direct file edits and verification.",
            when_to_use: &[
                "The task has a concrete implementation target and an owned file/module scope.",
                "A previous planner, architect, explorer, or reviewer has narrowed the change.",
            ],
            rules: &[
                "Own the files assigned in the task and avoid unrelated refactors.",
                "Do not revert edits made by other agents or the user.",
                "Run the narrowest useful verification command before reporting.",
                "Report changed files, verification, and remaining risk in the standard header.",
            ],
            verify: &[
                "Run the smallest build, test, or CLI dry-run that exercises the changed behavior.",
                "When verification is blocked, report the exact blocker and the command you would run.",
            ],
        },
        RunbookRole {
            name: "reviewer",
            title: "Reviewer Runbook",
            description: "Code review focused on regressions, bugs, and missing tests.",
            when_to_use: &[
                "An implementation diff is ready for quality, regression, or release gate review.",
                "The leader needs risk-ranked findings rather than another implementation pass.",
            ],
            rules: &[
                "Lead with findings ordered by severity.",
                "Ground every finding in file:line references.",
                "Prefer actionable patch snippets over style-only comments.",
                "Return VERDICT: LGTM or VERDICT: CHANGES after findings.",
            ],
            verify: &[
                "Name the tests or manual checks that would catch each material issue.",
                "If no issues are found, state residual risk and any unrun coverage.",
            ],
        },
        RunbookRole {
            name: "security",
            title: "Security Runbook",
            description: "Security review for process execution, sockets, quoting, and trust boundaries.",
            when_to_use: &[
                "The change touches Process(), shell quoting, sockets, permissions, tokens, or external input.",
                "A feature changes what agents, CLI commands, or browser automation can access.",
            ],
            rules: &[
                "Inspect Process(), shell invocation, socket authorization, allowAll paths, and external input parsing.",
                "Include severity, CWE when obvious, PoC, fix, and verify command.",
                "Flag focus stealing or privilege boundary changes when socket commands are involved.",
                "Do not suggest broad rewrites when a local validation or escaping fix is enough.",
            ],
            verify: &[
                "Provide a concrete PoC or negative test for exploitable paths.",
                "Call out when the issue is theoretical and what evidence would confirm it.",
            ],
        },
        RunbookRole {
            name: "frontend",
            title: "Frontend Runbook",
            description: "SwiftUI/AppKit interface work for term-mesh panels and dashboard UI.",
            when_to_use: &[
                "The change touches Sources/Panels, Sources/Splits, Settings, team UI, keyboard handling, or SwiftUI/AppKit layout.",
                "The user-visible behavior depends on visual hierarchy, focus, or panel state.",
            ],
            rules: &[
                "Preserve portal layering contracts for terminal and browser surfaces.",
                "Use existing design tokens and avoid nested card layouts.",
                "Add DEBUG dlog events only behind DEBUG guards when useful.",
                "Verify responsive layout and avoid overlapping text or controls.",
            ],
            verify: &[
                "Run the project xcodebuild command for Swift changes.",
                "Use reload or UI smoke coverage when the changed surface is interactive.",
            ],
        },
        RunbookRole {
            name: "backend",
            title: "Backend Runbook",
            description: "Rust daemon, JSON-RPC, IPC, and telemetry implementation.",
            when_to_use: &[
                "The change touches daemon/, tm-agent, JSON-RPC schemas, socket commands, peer relay, or telemetry paths.",
                "A UI change requires new daemon capabilities or contract updates.",
            ],
            rules: &[
                "Default new socket commands to off-main handling unless UI state requires main actor access.",
                "Parse and validate external input before scheduling UI mutation.",
                "Keep JSON response shapes backward compatible where existing clients depend on them.",
                "Run cargo test for daemon changes when feasible.",
            ],
            verify: &[
                "Run cargo fmt and cargo test for daemon changes.",
                "Exercise new or changed CLI/socket commands with a dry-run or local request.",
            ],
        },
        RunbookRole {
            name: "refactorer",
            title: "Refactorer Runbook",
            description: "Behavior-preserving refactors with small reversible steps.",
            when_to_use: &[
                "The goal is reducing duplication, moving code, or clarifying boundaries without changing behavior.",
                "The leader needs a contained cleanup before or after feature work.",
            ],
            rules: &[
                "Preserve public behavior and avoid mixed feature work.",
                "Make mechanical moves separately from semantic edits.",
                "Run focused regression checks after each meaningful batch.",
                "Report compatibility risk before broadening the refactor.",
            ],
            verify: &[
                "Run regression checks covering the moved or renamed behavior.",
                "List any behavior that intentionally changed; otherwise state behavior-preserving.",
            ],
        },
        RunbookRole {
            name: "architect",
            title: "Architect Runbook",
            description: "Design decisions for module boundaries, threading, and protocol changes.",
            when_to_use: &[
                "A change affects module boundaries, protocol shape, threading policy, focus policy, or long-lived extension points.",
                "Multiple agents or phases need a shared design before implementation.",
            ],
            rules: &[
                "Write the decision, rejected alternatives, and compatibility impact.",
                "Include Swift/Rust stubs or sequence pseudocode when it clarifies the boundary.",
                "Call out focus policy, socket threading, and panel layering impacts explicitly.",
                "Avoid abstractions that do not remove real duplication or risk.",
            ],
            verify: &[
                "Name the compatibility checks and contract tests the executor or tester should run.",
                "Flag unresolved decisions as explicit open questions, not hidden assumptions.",
            ],
        },
        RunbookRole {
            name: "tester",
            title: "Tester Runbook",
            description: "Verification planning and regression execution.",
            when_to_use: &[
                "The task needs a test matrix, regression run, smoke test, or reproduction confirmation.",
                "A change is ready but still lacks confidence across UI, CLI, daemon, or workflow contracts.",
            ],
            rules: &[
                "Map tests to user-visible risk and changed contracts.",
                "Use VM-only UI test commands for macOS UI automation.",
                "Report test case count, failures, and whether VM coverage is still needed.",
                "Prefer reproducible shell commands over prose-only validation.",
            ],
            verify: &[
                "Report commands exactly as run and summarize pass/fail counts.",
                "Separate host-only checks from required VM UI checks.",
            ],
        },
        RunbookRole {
            name: "debugger",
            title: "Debugger Runbook",
            description: "Reproduction, root cause isolation, and minimal fix guidance.",
            when_to_use: &[
                "There is a failing command, crash, flaky behavior, or user-reported symptom without a known cause.",
                "The leader needs root cause and a minimal fix path before assigning implementation.",
            ],
            rules: &[
                "Start from observed symptoms and identify a reproducible path.",
                "Separate root cause from nearby incidental failures.",
                "Prefer minimal fixes with a clear verification command.",
                "Escalate to tester when the fix needs UI or regression coverage.",
            ],
            verify: &[
                "Capture the failing command, relevant log excerpt, and expected passing command.",
                "State confidence in the root cause and what would falsify it.",
            ],
        },
        RunbookRole {
            name: "writer",
            title: "Writer Runbook",
            description: "Documentation, changelog, and release-note updates.",
            when_to_use: &[
                "A shipped or ready change needs README, docs-site, AGENTS/CLAUDE, changelog, or release note updates.",
                "User-facing CLI, Settings, workflow, or onboarding behavior changed.",
            ],
            rules: &[
                "Update the single source of truth first, then linked docs.",
                "Keep docs aligned with current CLI names and socket methods.",
                "Mention exact insertion locations and self-check consistency.",
                "Avoid documenting speculative behavior as shipped behavior.",
            ],
            verify: &[
                "Check linked docs for stale command names and mismatched behavior.",
                "Report the source document and every synchronized projection touched.",
            ],
        },
        RunbookRole {
            name: "devops",
            title: "DevOps Runbook",
            description: "Build, release, CI, packaging, and operational workflows.",
            when_to_use: &[
                "The task touches build scripts, CI, release packaging, signing, tags, artifacts, or deployment.",
                "The leader needs reproducible operational commands and rollback awareness.",
            ],
            rules: &[
                "Check scripts, signing, packaging, and environment assumptions.",
                "Keep commands reproducible and avoid host-specific hidden state.",
                "Report artifact paths, versions, and rollback considerations.",
                "Do not publish, tag, or push unless the leader explicitly requested it.",
            ],
            verify: &[
                "Prefer dry-runs or read-only status commands before publishing actions.",
                "Record artifact paths and exact versions produced or inspected.",
            ],
        },
        RunbookRole {
            name: "planner",
            title: "Planner Runbook",
            description: "Task decomposition, dependency mapping, and phase gates.",
            when_to_use: &[
                "The work spans several files, agents, phases, or dependencies.",
                "The leader needs ownership, acceptance criteria, and ordering before execution.",
            ],
            rules: &[
                "Split work into independently assignable tasks with clear owners.",
                "List inputs, outputs, dependencies, and acceptance criteria.",
                "Prefer phase gates where shared contracts or multiple agents are involved.",
                "Emit tm-agent task create lines when actionable.",
            ],
            verify: &[
                "Ensure every task has an owner, input, output, dependency, and acceptance check.",
                "Call out critical-path blockers separately from parallelizable work.",
            ],
        },
        RunbookRole {
            name: "researcher",
            title: "Researcher Runbook",
            description: "Focused research, evidence gathering, and synthesis.",
            when_to_use: &[
                "The answer depends on external facts, current docs, prior art, or uncertain project history.",
                "The leader needs evidence and tradeoffs before design or implementation.",
            ],
            rules: &[
                "State sources and confidence, and separate fact from inference.",
                "Prefer primary sources and current project artifacts.",
                "Summarize findings into decisions, risks, and next checks.",
                "Avoid implementing changes while acting as researcher.",
            ],
            verify: &[
                "Cite sources or local artifacts used for material claims.",
                "List remaining unknowns and the fastest check to resolve each.",
            ],
        },
        RunbookRole {
            name: "data",
            title: "Data Engineer Runbook",
            description: "Schema design, query optimization, migrations, and data pipeline work.",
            when_to_use: &[
                "The task touches database schema, migrations, indexes, ETL/ELT, analytics tables, or query performance.",
                "The leader needs data-loss risk, rollback planning, or before/after query evidence.",
            ],
            rules: &[
                "Read existing schema, migration, and data access patterns before proposing changes.",
                "Include rollback strategy for every schema migration.",
                "Optimize queries from measured plans, not guesses.",
                "Flag data loss, backfill, locking, and deployment-order risks explicitly.",
            ],
            verify: &[
                "Run the migration, query test, or EXPLAIN command that validates the change.",
                "Report before/after plan or timing when query performance is part of the task.",
            ],
        },
        RunbookRole {
            name: "perf",
            title: "Performance Tuner Runbook",
            description: "Profiling, bottleneck isolation, optimization, and benchmark verification.",
            when_to_use: &[
                "The task asks to reduce latency, memory, CPU, I/O, startup time, or resource usage.",
                "A change claims performance impact and needs measurement.",
            ],
            rules: &[
                "Measure baseline behavior before changing code.",
                "Identify whether the bottleneck is CPU, memory, I/O, network, rendering, or algorithmic complexity.",
                "Apply one targeted optimization at a time.",
                "Do not trade correctness or maintainability for unmeasured speed.",
            ],
            verify: &[
                "Report BOTTLENECK, CAUSE, FIX, and RESULT with units.",
                "Include the benchmark/profiling command and before/after numbers.",
            ],
        },
        RunbookRole {
            name: "syseng",
            title: "System Engineer Runbook",
            description: "OS-level debugging, shell automation, daemon configuration, and system hardening.",
            when_to_use: &[
                "The task touches launchd/systemd, shell scripts, process state, file permissions, logs, networking, or host resources.",
                "The leader needs root-cause analysis from system state rather than application code alone.",
            ],
            rules: &[
                "Start with non-destructive observation commands and logs.",
                "Avoid destructive operations unless the leader explicitly approves them.",
                "List config files, services, sockets, and processes affected by the fix.",
                "Prefer idempotent scripts and reversible config changes.",
            ],
            verify: &[
                "Report exact commands used for diagnosis and verification.",
                "Confirm the symptom is resolved, not merely hidden by a restart.",
            ],
        },
        RunbookRole {
            name: "api",
            title: "API Designer Runbook",
            description: "API contracts, endpoint design, schemas, versioning, and compatibility review.",
            when_to_use: &[
                "The task asks for REST, GraphQL, gRPC, JSON-RPC, OpenAPI, protobuf, or webhook contract work.",
                "A change may affect external or cross-module clients.",
            ],
            rules: &[
                "Read existing API contracts and naming conventions before designing new shapes.",
                "Define request, response, error, auth, and pagination semantics where applicable.",
                "Flag breaking changes and provide a migration/versioning path.",
                "Keep contracts testable and avoid ambiguous nullable/optional behavior.",
            ],
            verify: &[
                "Provide a contract test, schema validation command, or compatibility check.",
                "Include example payloads for new or changed API surfaces.",
            ],
        },
        RunbookRole {
            name: "mobile",
            title: "Mobile Developer Runbook",
            description: "iOS/Android implementation, platform APIs, adaptive layout, and mobile constraints.",
            when_to_use: &[
                "The task touches SwiftUI/UIKit, Android/Compose/Kotlin, mobile permissions, notifications, storage, camera, or location.",
                "The user-visible behavior depends on mobile layout, accessibility, battery, startup, or offline/network constraints.",
            ],
            rules: &[
                "Follow platform idioms and existing app architecture.",
                "Account for permissions, OS version support, background behavior, and accessibility.",
                "Test layout-sensitive work across relevant screen sizes when feasible.",
                "Avoid introducing platform-specific warnings or entitlement drift.",
            ],
            verify: &[
                "Run the platform build or targeted UI/unit test for changed mobile code.",
                "Report device/simulator coverage and any unverified screen-size risk.",
            ],
        },
        RunbookRole {
            name: "infra",
            title: "Infrastructure Engineer Runbook",
            description: "Cloud infrastructure, IaC, Kubernetes, networking, scaling, and operational dependencies.",
            when_to_use: &[
                "The task touches Terraform, Pulumi, CloudFormation, CDK, Kubernetes, IAM, DNS, certificates, CDN, or scaling.",
                "The leader needs cost, dependency, secret, or rollout risk before infrastructure changes.",
            ],
            rules: &[
                "Read existing IaC module structure and naming before editing.",
                "Never hardcode credentials; use IAM, secret managers, or environment references.",
                "Document cost impact, manual steps, and rollout/rollback considerations.",
                "Keep resource changes minimal and reviewable.",
            ],
            verify: &[
                "Prefer plan/diff/dry-run commands over direct apply.",
                "Report resources changed, cost impact, and manual follow-up steps.",
            ],
        },
        RunbookRole {
            name: "ux",
            title: "UX Designer Runbook",
            description: "User flows, interaction design, usability review, component states, and accessibility specs.",
            when_to_use: &[
                "The task asks for flow design, wireframes, usability review, onboarding, interaction states, or UX copy.",
                "A product surface is confusing and needs structure before implementation.",
            ],
            rules: &[
                "Map the user goal and decision points before proposing UI.",
                "Define empty, loading, error, disabled, hover, focus, and success states where relevant.",
                "Call out accessibility requirements and keyboard/focus behavior.",
                "Stay read-only unless the leader explicitly assigns implementation.",
            ],
            verify: &[
                "Check the proposed flow against visibility, feedback, consistency, and recovery heuristics.",
                "Rank usability issues by impact and name the affected user action.",
            ],
        },
        RunbookRole {
            name: "ai",
            title: "AI Engineer Runbook",
            description: "LLM integration, prompt engineering, RAG, model pipelines, guardrails, and evaluation.",
            when_to_use: &[
                "The task touches LLM prompts, tool calls, structured output, embeddings, vector search, RAG, evals, or model selection.",
                "The leader needs cost, latency, quality, safety, or hallucination risk analysis for AI behavior.",
            ],
            rules: &[
                "Read existing prompt, retrieval, tool, and model-selection code before changing behavior.",
                "Define input/output schemas and validate model output before downstream use.",
                "Document cost/latency tradeoffs and model-specific assumptions.",
                "Never hardcode API keys; use environment variables or secret managers.",
            ],
            verify: &[
                "Run or specify an eval, golden-case test, schema validation, or dry-run for changed AI behavior.",
                "Report token/request estimates, expected cost per 1K calls, and known model limitations when applicable.",
            ],
        },
        RunbookRole {
            name: "watcher",
            title: "Watcher Runbook",
            description: "Stateless drift reviewer — compares spec against a watched agent's recent delta, detects execution/direction drift, reports to the leader only.",
            when_to_use: &[
                "A long-running or risky session needs oversight against a spec.",
                "The leader asks for an on-demand \"review now\" drift check, or drift is suspected.",
            ],
            rules: &[
                "Feed only the spec plus the watched agent's recent delta (tm-agent collect --lines N); never the full history.",
                "Distinguish execution drift (the task done wrong) from direction drift (the wrong task in the first place).",
                "Return only a structured drift verdict: VERDICT, drift_type, severity, finding, and spec_clause.",
                "Do not call tm-agent msg send and do not append to .xm/watch/board.jsonl; manual /watch review owns leader reporting, autonomous /watch on is owned by the daemon WatchController.",
                "When nothing is wrong, return a single structured OK verdict.",
                "Propose course corrections only; never edit code directly — the leader approves and applies.",
            ],
            verify: &[
                "Confirm your reply contains the structured verdict fields requested by /watch.",
                "If asked to verify persistence, tell the leader to check tm-agent msg list and tail .xm/watch/board.jsonl; do not write those yourself.",
            ],
        },
    ]
}

pub(crate) fn find_runbook_project_root() -> Result<PathBuf, String> {
    let start = env::current_dir().map_err(|e| format!("current_dir: {e}"))?;
    let mut cur = start.as_path();
    loop {
        if cur.join(".git").exists()
            || cur.join("AGENTS.md").exists()
            || cur.join("TODO.md").exists()
        {
            return Ok(cur.to_path_buf());
        }
        match cur.parent() {
            Some(parent) => cur = parent,
            None => return Ok(start),
        }
    }
}

pub(crate) fn parse_runbook_tools(tool: &str) -> Result<Vec<RunbookTool>, String> {
    let mut out = Vec::new();
    for raw in tool.split(',') {
        match raw.trim().to_ascii_lowercase().as_str() {
            "" => {}
            "all" => {
                return Ok(vec![
                    RunbookTool::Claude,
                    RunbookTool::Codex,
                    RunbookTool::OpenCode,
                    RunbookTool::Gemini,
                ])
            }
            "claude" | "claude-code" | "claudecode" => out.push(RunbookTool::Claude),
            "codex" => out.push(RunbookTool::Codex),
            "opencode" | "open-code" => out.push(RunbookTool::OpenCode),
            "gemini" => out.push(RunbookTool::Gemini),
            other => return Err(format!("unknown runbook tool: {other}")),
        }
    }
    if out.is_empty() {
        return Err("no runbook tool selected".to_string());
    }
    Ok(out)
}

pub(crate) fn selected_runbook_roles(agent: Option<&str>) -> Result<Vec<RunbookRole>, String> {
    let roles = builtin_runbook_roles();
    if let Some(name) = agent {
        let Some(role) = roles.into_iter().find(|r| r.name == name) else {
            return Err(format!("unknown runbook agent: {name}"));
        };
        return Ok(vec![role]);
    }
    Ok(roles)
}

pub(crate) fn runbook_source_path(root: &Path, role: &RunbookRole) -> PathBuf {
    root.join(RUNBOOK_SOURCE_DIR)
        .join(format!("{}.md", role.name))
}

pub(crate) fn load_runbook_content_for_role(root: &Path, role: &str) -> Option<String> {
    if !role
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    {
        return None;
    }
    let path = root.join(RUNBOOK_SOURCE_DIR).join(format!("{role}.md"));
    fs::read_to_string(path)
        .ok()
        .filter(|content| !content.trim().is_empty())
}

pub(crate) fn load_common_runbook_content(root: &Path) -> String {
    let path = root.join(RUNBOOK_SOURCE_DIR).join("_common.md");
    fs::read_to_string(&path)
        .ok()
        .filter(|content| !content.trim().is_empty())
        .unwrap_or_default()
}

pub(crate) fn get_common_runbook_p0_rule(root: &Path) -> String {
    let common = load_common_runbook_content(root);
    if common.is_empty() {
        return "명시 지시 없으면 git 상태를 바꾸지 않는다 — working tree 변경만 남기고 커밋은 leader가 결정".to_string();
    }
    let bullets = runbook_section_bullets(&common, "## P0. Git 상태 변경 금지", 1);
    bullets.first().cloned().unwrap_or_else(|| {
        "명시 지시 없으면 git 상태를 바꾸지 않는다 — working tree 변경만 남기고 커밋은 leader가 결정".to_string()
    })
}

pub(crate) fn runbook_section_bullets(content: &str, section: &str, limit: usize) -> Vec<String> {
    let mut in_section = false;
    let mut out = Vec::new();
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("## ") {
            in_section = trimmed == section;
            continue;
        }
        if in_section {
            if let Some(item) = trimmed.strip_prefix("- ") {
                out.push(item.trim().to_string());
                if out.len() >= limit {
                    break;
                }
            }
        }
    }
    out
}

pub(crate) fn runbook_digest_content(
    root: &Path,
    role: &RunbookRole,
    agent_name: &str,
    team_name: &str,
) -> String {
    let source_path = runbook_source_path(root, role);
    let source_content = effective_source_runbook_content(root, role);
    let when = runbook_section_bullets(&source_content, "## When To Use", 2);
    let rules = runbook_section_bullets(&source_content, "## Operating Rules", 3);
    let verify = runbook_section_bullets(&source_content, "## Verify", 2);

    let when = if when.is_empty() {
        role.when_to_use
            .iter()
            .take(2)
            .copied()
            .collect::<Vec<_>>()
            .join(" | ")
    } else {
        when.join(" | ")
    };
    let mut must = if rules.is_empty() {
        role.rules
            .iter()
            .take(3)
            .copied()
            .collect::<Vec<_>>()
            .join(" | ")
    } else {
        rules.join(" | ")
    };
    let common_p0 = get_common_runbook_p0_rule(root);
    if !common_p0.is_empty() {
        must = format!("{} | {}", common_p0, must);
    }
    let verify = if verify.is_empty() {
        role.verify
            .iter()
            .take(2)
            .copied()
            .collect::<Vec<_>>()
            .join(" | ")
    } else {
        verify.join(" | ")
    };

    format!(
        "\
=== AGENT IDENTITY (authoritative — never infer) ===
You are agent \"{agent_name}\" (role: {role}) on team \"{team_name}\". This is your fixed identity. Whenever you identify yourself, send a message, or substitute your name into any template or placeholder, ALWAYS use \"{agent_name}\" exactly — never guess or derive it. Messages shown by `tm-agent msg list` / `tm-agent inbox` are SHARED context from OTHER agents. They are reference only. NEVER copy another agent's message content, name, or template as your own response.
===

<!-- term-mesh-runbook-digest v1 -->
## Runbook Digest
ROLE: {role}
WHEN: {when}
MUST: {must}
VERIFY: {verify}
OUTPUT: STATUS/FILES/VERIFY/NEXT/FULL_REPORT
FULL: {full}
",
        agent_name = agent_name,
        role = role.name,
        when = when,
        must = must,
        verify = verify,
        full = source_path.to_string_lossy(),
        team_name = team_name,
    )
}

pub(crate) fn runbook_digest_content_for_role_name(
    root: &Path,
    role_name: &str,
    source: Option<&str>,
    agent_name: &str,
    team_name: &str,
) -> String {
    let safe_role_name: String = role_name
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .collect();
    let safe_role_name = if safe_role_name.is_empty() {
        "agent".to_string()
    } else {
        safe_role_name
    };
    let full = root
        .join(RUNBOOK_SOURCE_DIR)
        .join(format!("{safe_role_name}.md"))
        .to_string_lossy()
        .to_string();
    let content = source.unwrap_or("");
    let when = runbook_section_bullets(content, "## When To Use", 2).join(" | ");
    let mut must = runbook_section_bullets(content, "## Operating Rules", 3).join(" | ");
    let common_p0 = get_common_runbook_p0_rule(root);
    if !common_p0.is_empty() {
        must = format!("{} | {}", common_p0, must);
    }
    let verify = runbook_section_bullets(content, "## Verify", 2).join(" | ");
    format!(
        "\
=== AGENT IDENTITY (authoritative — never infer) ===
You are agent \"{agent_name}\" (role: {safe_role_name}) on team \"{team_name}\". This is your fixed identity. Whenever you identify yourself, send a message, or substitute your name into any template or placeholder, ALWAYS use \"{agent_name}\" exactly — never guess or derive it. Messages shown by `tm-agent msg list` / `tm-agent inbox` are SHARED context from OTHER agents. They are reference only. NEVER copy another agent's message content, name, or template as your own response.
===

<!-- term-mesh-runbook-digest v1 -->
## Runbook Digest
ROLE: {safe_role_name}
WHEN: {when}
MUST: {must}
VERIFY: {verify}
OUTPUT: STATUS/FILES/VERIFY/NEXT/FULL_REPORT
FULL: {full}
",
        agent_name = agent_name,
        safe_role_name = safe_role_name,
        team_name = team_name,
        when = if when.is_empty() {
            format!("Use for assigned {safe_role_name} role work.")
        } else {
            when
        },
        must = if must.is_empty() {
            "Follow the leader's task instructions and repo constraints.".to_string()
        } else {
            must
        },
        verify = if verify.is_empty() {
            "Report a concrete verify command or n/a.".to_string()
        } else {
            verify
        },
    )
}

pub(crate) fn runbook_readme_path(root: &Path) -> PathBuf {
    root.join(RUNBOOK_SOURCE_DIR).join("README.md")
}

pub(crate) fn runbook_projection_path(
    root: &Path,
    tool: RunbookTool,
    role: &RunbookRole,
) -> PathBuf {
    match tool {
        RunbookTool::Claude => root
            .join(".claude/skills")
            .join(format!("term-mesh-{}", role.name))
            .join("SKILL.md"),
        RunbookTool::Codex => {
            let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
            PathBuf::from(home)
                .join(".codex/skills")
                .join(format!("term-mesh-{}", role.name))
                .join("SKILL.md")
        }
        RunbookTool::OpenCode => root
            .join(".opencode/runbooks")
            .join(format!("{}.md", role.name)),
        RunbookTool::Gemini => {
            let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
            PathBuf::from(home)
                .join(".agents/skills")
                .join(format!("term-mesh-{}", role.name))
                .join("SKILL.md")
        }
    }
}

pub(crate) fn yaml_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

pub(crate) fn source_runbook_content(role: &RunbookRole) -> String {
    let mut out = format!(
        "{RUNBOOK_MARKER}\n# {}\n\n{}\n\n## Role\n\n`{}` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.\n\n## When To Use\n",
        role.title, role.description, role.name
    );
    for item in role.when_to_use {
        out.push_str(&format!("- {item}\n"));
    }
    out.push_str("\n## Operating Rules\n");
    for rule in role.rules {
        out.push_str(&format!("- {rule}\n"));
    }
    out.push_str("\n## Verify\n");
    for item in role.verify {
        out.push_str(&format!("- {item}\n"));
    }
    out.push_str(
        "\n## Standard Reply Header\n\n```text\nSTATUS: DONE|BLOCKED|NEEDS_REVIEW\nFILES: <changed paths or none>\nVERIFY: <single shell command or n/a>\nNEXT: <leader action or NONE>\nFULL_REPORT: <absolute result path or n/a>\n```\n",
    );
    out
}

pub(crate) fn effective_source_runbook_content(root: &Path, role: &RunbookRole) -> String {
    fs::read_to_string(runbook_source_path(root, role))
        .ok()
        .filter(|content| !content.trim().is_empty())
        .unwrap_or_else(|| source_runbook_content(role))
}

pub(crate) fn tool_runbook_content(
    tool: RunbookTool,
    role: &RunbookRole,
    source_content: &str,
) -> String {
    match tool {
        RunbookTool::Claude | RunbookTool::Codex | RunbookTool::Gemini => format!(
            "---\nname: term-mesh-{}\ndescription: \"{}\"\n---\n{}",
            role.name,
            yaml_escape(&format!(
                "Use when acting as the {} agent in a term-mesh team.",
                role.name
            )),
            source_content
        ),
        RunbookTool::OpenCode => source_content.to_string(),
    }
}

pub(crate) fn runbook_readme_content(roles: &[RunbookRole]) -> String {
    let mut out = format!(
        "{RUNBOOK_MARKER}\n# Agent Runbooks\n\nThese files are the source of truth for term-mesh per-agent behavior. Regenerate tool-specific projections with:\n\n```bash\ntm-agent runbook install --tool all\n```\n\n## Roles\n"
    );
    for role in roles {
        out.push_str(&format!("- `{}`: {}\n", role.name, role.description));
    }
    out
}

pub(crate) fn is_runbook_managed(content: &str) -> bool {
    content.lines().take(30).any(|line| line == RUNBOOK_MARKER)
}

pub(crate) fn file_runbook_state(path: &Path) -> &'static str {
    match fs::read_to_string(path) {
        Ok(content) if is_runbook_managed(&content) => "managed",
        Ok(_) => "custom",
        Err(_) => "missing",
    }
}

pub(crate) fn projection_runbook_state(
    root: &Path,
    tool: RunbookTool,
    role: &RunbookRole,
    path: &Path,
) -> &'static str {
    match fs::read_to_string(path) {
        Ok(content) if !is_runbook_managed(&content) => "custom",
        Ok(content) => {
            let source_content = effective_source_runbook_content(root, role);
            let expected = tool_runbook_content(tool, role, &source_content);
            if content == expected {
                "managed"
            } else {
                "outdated"
            }
        }
        Err(_) => "missing",
    }
}

pub(crate) fn write_managed_runbook(
    path: &Path,
    content: &str,
    dry_run: bool,
    force: bool,
) -> Result<Value, String> {
    let existing = fs::read_to_string(path).ok();
    let action = match existing.as_deref() {
        Some(old) if old == content => "unchanged",
        Some(old) if !is_runbook_managed(old) && !force => "skipped_custom",
        Some(_) if dry_run => "would_update",
        None if dry_run => "would_create",
        Some(_) => "updated",
        None => "created",
    };

    if !dry_run && matches!(action, "created" | "updated") {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| format!("create_dir {}: {e}", parent.display()))?;
        }
        let file_name = path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("runbook");
        let tmp = path.with_file_name(format!(".tmp-{file_name}"));
        fs::write(&tmp, content).map_err(|e| format!("write {}: {e}", tmp.display()))?;
        fs::rename(&tmp, path)
            .map_err(|e| format!("rename {} -> {}: {e}", tmp.display(), path.display()))?;
    }

    Ok(json!({
        "path": path.to_string_lossy(),
        "action": action,
    }))
}

/// `.agent-runbooks/<role>.md` is the project's source of truth, and people
/// edit it below the managed marker. An existing one is therefore kept unless
/// `force`; only a missing one is written. Projections are regenerated from it.
pub(crate) fn write_source_runbook(
    path: &Path,
    content: &str,
    dry_run: bool,
    force: bool,
) -> Result<Value, String> {
    if !force {
        if let Ok(existing) = fs::read_to_string(path) {
            let action = if existing == content {
                "unchanged"
            } else {
                "kept_existing"
            };
            return Ok(json!({
                "path": path.to_string_lossy(),
                "action": action,
            }));
        }
    }
    write_managed_runbook(path, content, dry_run, force)
}

pub(crate) fn runbook_init(dry_run: bool, force: bool) -> Result<Value, String> {
    let root = find_runbook_project_root()?;
    let roles = builtin_runbook_roles();
    let mut files = Vec::new();
    files.push(write_managed_runbook(
        &runbook_readme_path(&root),
        &runbook_readme_content(&roles),
        dry_run,
        force,
    )?);
    for role in &roles {
        files.push(write_source_runbook(
            &runbook_source_path(&root, role),
            &source_runbook_content(role),
            dry_run,
            force,
        )?);
    }
    Ok(json!({
        "ok": true,
        "result": {
            "project_root": root.to_string_lossy(),
            "dry_run": dry_run,
            "files": files,
        }
    }))
}

pub(crate) fn runbook_install(
    tool: &str,
    agent: Option<&str>,
    dry_run: bool,
    force: bool,
) -> Result<Value, String> {
    let root = find_runbook_project_root()?;
    let tools = parse_runbook_tools(tool)?;
    let roles = selected_runbook_roles(agent)?;
    let all_roles = builtin_runbook_roles();
    let mut files = Vec::new();

    files.push(write_managed_runbook(
        &runbook_readme_path(&root),
        &runbook_readme_content(&all_roles),
        dry_run,
        force,
    )?);
    for role in &roles {
        files.push(write_source_runbook(
            &runbook_source_path(&root, role),
            &source_runbook_content(role),
            dry_run,
            force,
        )?);
    }
    for tool in tools {
        for role in &roles {
            // F1+F4 fix: use effective_source_runbook_content (the same
            // resolver projection_runbook_state uses) so user edits to
            // managed source files propagate into projections instead of
            // being silently regenerated to defaults. Eliminates the
            // status="outdated" → install → still "outdated" drift loop.
            let source_content = effective_source_runbook_content(&root, role);
            files.push(write_managed_runbook(
                &runbook_projection_path(&root, tool, role),
                &tool_runbook_content(tool, role, &source_content),
                dry_run,
                force,
            )?);
        }
    }

    Ok(json!({
        "ok": true,
        "result": {
            "project_root": root.to_string_lossy(),
            "dry_run": dry_run,
            "agent": agent.unwrap_or("all"),
            "files": files,
        }
    }))
}

pub(crate) fn runbook_status() -> Result<Value, String> {
    let root = find_runbook_project_root()?;
    let roles = builtin_runbook_roles();
    let source: Vec<Value> = roles
        .iter()
        .map(|role| {
            let path = runbook_source_path(&root, role);
            json!({
                "role": role.name,
                "path": path.to_string_lossy(),
                "state": file_runbook_state(&path),
            })
        })
        .collect();

    let tools: Vec<Value> = [
        RunbookTool::Claude,
        RunbookTool::Codex,
        RunbookTool::OpenCode,
        RunbookTool::Gemini,
    ]
    .iter()
    .map(|tool| {
        let mut files = Vec::new();
        let mut managed = 0;
        let mut custom = 0;
        let mut missing = 0;
        let mut outdated = 0;
        for role in &roles {
            let path = runbook_projection_path(&root, *tool, role);
            let state = projection_runbook_state(&root, *tool, role, &path);
            match state {
                "managed" => managed += 1,
                "custom" => custom += 1,
                "outdated" => outdated += 1,
                _ => missing += 1,
            }
            files.push(json!({
                "role": role.name,
                "path": path.to_string_lossy(),
                "state": state,
            }));
        }
        json!({
            "tool": tool.as_str(),
            "managed": managed,
            "custom": custom,
            "missing": missing,
            "outdated": outdated,
            "files": files,
        })
    })
    .collect();

    Ok(json!({
        "ok": true,
        "result": {
            "project_root": root.to_string_lossy(),
            "source_dir": root.join(RUNBOOK_SOURCE_DIR).to_string_lossy(),
            "roles": roles.iter().map(|r| r.name).collect::<Vec<_>>(),
            "source": source,
            "tools": tools,
        }
    }))
}

pub(crate) fn runbook_digest(agent: Option<&str>) -> Result<Value, String> {
    let root = find_runbook_project_root()?;
    let roles = selected_runbook_roles(agent)?;
    let digests: Vec<Value> = roles
        .iter()
        .map(|role| {
            json!({
                "role": role.name,
                "path": runbook_source_path(&root, role).to_string_lossy(),
                // CLI digest preview has no live agent/team context.
                "digest": runbook_digest_content(&root, role, agent.unwrap_or("generic"), "cli-tools"),
            })
        })
        .collect();
    Ok(json!({
        "ok": true,
        "result": {
            "project_root": root.to_string_lossy(),
            "mode": "digest",
            "agent": agent.unwrap_or("all"),
            "digests": digests,
        }
    }))
}

pub(crate) fn run_runbook_command(command: &RunbookCommands) -> Result<Value, String> {
    match command {
        RunbookCommands::Status => runbook_status(),
        RunbookCommands::Init { dry_run, force } => runbook_init(*dry_run, *force),
        RunbookCommands::Install {
            tool,
            agent,
            dry_run,
            force,
        } => runbook_install(tool, agent.as_deref(), *dry_run, *force),
        RunbookCommands::Digest { agent } => runbook_digest(agent.as_deref()),
    }
}

#[cfg(test)]
mod runbook_tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn resolve_team_name_explicit_flag_wins() {
        // The explicit --team flag returns verbatim and never consults env, so a
        // command run from an adopted leader pane (no TERMMESH_TEAM) can still
        // target a workspace-local `ws-…` team. Env-free → parallel-safe.
        assert_eq!(resolve_team_name(Some("ws-deadbeef")), "ws-deadbeef");
        assert_eq!(resolve_team_name(Some("standard")), "standard");
    }

    #[test]
    fn resolve_team_name_empty_flag_falls_through() {
        // An empty --team must not be taken as the team; it falls through to the
        // env/default chain. With no overriding env the floor is some non-empty
        // name (env TERMMESH_TEAM, a ws-derived name, or the live-team default) —
        // never the empty string.
        assert!(!resolve_team_name(Some("")).is_empty());
    }

    #[test]
    fn rpc_failure_envelopes_are_process_failures() {
        assert!(rpc_response_failed(&json!({
            "ok": false,
            "error": {"code": "not_found", "message": "Team not found"}
        })));
        assert!(rpc_response_failed(&json!({
            "jsonrpc": "2.0",
            "error": {"code": -32601, "message": "method not found"}
        })));
        assert!(!rpc_response_failed(&json!({"ok": true, "result": {}})));
        assert!(!rpc_response_failed(
            &json!({"jsonrpc": "2.0", "result": {}})
        ));
    }

    #[test]
    fn runbook_parse_tools_accepts_all_and_aliases() {
        let all = parse_runbook_tools("all").unwrap();
        assert_eq!(all.len(), 4);
        let all_names: Vec<&str> = all.iter().map(|t| t.as_str()).collect();
        assert_eq!(all_names, vec!["claude", "codex", "opencode", "gemini"]);

        let tools = parse_runbook_tools("claude-code,codex,open-code").unwrap();
        let names: Vec<&str> = tools.iter().map(|t| t.as_str()).collect();
        assert_eq!(names, vec!["claude", "codex", "opencode"]);
    }

    #[test]
    fn runbook_content_has_marker_and_skill_frontmatter() {
        let role = selected_runbook_roles(Some("reviewer")).unwrap().remove(0);
        let source = source_runbook_content(&role);
        assert!(source.starts_with(RUNBOOK_MARKER));
        assert!(source.contains("Reviewer Runbook"));
        assert!(source.contains("## When To Use"));
        assert!(source.contains("## Verify"));

        let skill = tool_runbook_content(RunbookTool::Codex, &role, &source);
        assert!(skill.starts_with("---\nname: term-mesh-reviewer"));
        assert!(skill.contains(RUNBOOK_MARKER));
    }

    /// #903 L1: an edit below the managed marker survived neither `init` nor
    /// `install`, which rewrote the source before projecting it.
    #[test]
    fn an_edited_managed_source_runbook_is_kept_and_projected() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = env::temp_dir().join(format!("tm-agent-runbook-source-{unique}"));
        let role = selected_runbook_roles(Some("reviewer")).unwrap().remove(0);
        let path = runbook_source_path(&dir, &role);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let edited = format!(
            "{}\n## Project rule\nALWAYS-CHECK-MIGRATIONS\n",
            source_runbook_content(&role)
        );
        fs::write(&path, &edited).unwrap();

        let kept =
            write_source_runbook(&path, &source_runbook_content(&role), false, false).unwrap();
        assert_eq!(kept["action"].as_str(), Some("kept_existing"));
        assert_eq!(fs::read_to_string(&path).unwrap(), edited);
        let projected = tool_runbook_content(
            RunbookTool::OpenCode,
            &role,
            &effective_source_runbook_content(&dir, &role),
        );
        assert!(projected.contains("ALWAYS-CHECK-MIGRATIONS"));

        let forced =
            write_source_runbook(&path, &source_runbook_content(&role), false, true).unwrap();
        assert_eq!(forced["action"].as_str(), Some("updated"));
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            source_runbook_content(&role)
        );

        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn a_missing_source_runbook_is_still_created() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = env::temp_dir().join(format!("tm-agent-runbook-missing-{unique}"));
        let path = dir.join("reviewer.md");

        let planned = write_source_runbook(&path, "content\n", true, false).unwrap();
        assert_eq!(planned["action"].as_str(), Some("would_create"));
        assert!(!path.exists());
        let created = write_source_runbook(&path, "content\n", false, false).unwrap();
        assert_eq!(created["action"].as_str(), Some("created"));
        let again = write_source_runbook(&path, "content\n", false, false).unwrap();
        assert_eq!(again["action"].as_str(), Some("unchanged"));

        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn runbook_write_skips_custom_files_without_force() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = env::temp_dir().join(format!("tm-agent-runbook-test-{unique}"));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("custom.md");
        fs::write(&path, "user file\n").unwrap();

        let result = write_managed_runbook(&path, RUNBOOK_MARKER, false, false).unwrap();
        assert_eq!(result["action"].as_str(), Some("skipped_custom"));
        assert_eq!(fs::read_to_string(&path).unwrap(), "user file\n");

        let forced = write_managed_runbook(&path, RUNBOOK_MARKER, false, true).unwrap();
        assert_eq!(forced["action"].as_str(), Some("updated"));
        assert_eq!(file_runbook_state(&path), "managed");

        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn runbook_init_prompt_loads_matching_role_file() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = env::temp_dir().join(format!("tm-agent-runbook-prompt-{unique}"));
        let runbook_dir = dir.join(RUNBOOK_SOURCE_DIR);
        fs::create_dir_all(&runbook_dir).unwrap();
        fs::write(runbook_dir.join("explorer.md"), "EXPLORER ONLY\n").unwrap();

        let prompt = agent_init_prompt(
            "exp1",
            "explorer",
            "test-team",
            &dir.to_string_lossy(),
            "/tmp/socket",
        );
        assert!(prompt.contains("## Runbook Digest"));
        assert!(prompt.contains("OUTPUT: STATUS/FILES/VERIFY/NEXT/FULL_REPORT"));
        assert!(prompt.contains("named \"exp1\" with role \"explorer\""));
        assert!(prompt.contains(".agent-runbooks/explorer.md"));

        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn runbook_prompt_requires_a_separate_unique_full_report_file() {
        let prompt = agent_init_prompt(
            "reviewer",
            "reviewer",
            "test-team",
            "/tmp/project",
            "/tmp/socket",
        );
        assert!(prompt.contains("<task_id>-full.md"));
        assert!(prompt.contains("durable copies, not full-report generators"));
        assert!(prompt.contains("Never use a reply alias or `<task_id>.md` as FULL_REPORT"));
        assert!(!prompt.contains("set FULL_REPORT to that path"));
    }

    #[test]
    fn runbook_projection_state_detects_outdated_managed_files() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = env::temp_dir().join(format!("tm-agent-runbook-drift-{unique}"));
        let role = selected_runbook_roles(Some("reviewer")).unwrap().remove(0);
        let source_path = runbook_source_path(&dir, &role);
        // The Codex projection resolves under `HOME`. Without this the test
        // rewrote the developer's real `~/.codex/skills/term-mesh-reviewer`.
        let projection_path = {
            let _env = ProcessEnvGuard::acquire();
            let prev_home = env::var_os("HOME");
            env::set_var("HOME", dir.join("home"));
            let path = runbook_projection_path(&dir, RunbookTool::Codex, &role);
            match prev_home {
                Some(value) => env::set_var("HOME", value),
                None => env::remove_var("HOME"),
            }
            path
        };
        assert!(
            projection_path.starts_with(&dir),
            "projection must stay in the temp dir: {}",
            projection_path.display()
        );
        fs::create_dir_all(source_path.parent().unwrap()).unwrap();
        fs::create_dir_all(projection_path.parent().unwrap()).unwrap();

        let custom_source = format!("{RUNBOOK_MARKER}\n# Custom Reviewer\n\n## Role\ncustom\n");
        fs::write(&source_path, &custom_source).unwrap();
        fs::write(
            &projection_path,
            tool_runbook_content(RunbookTool::Codex, &role, &source_runbook_content(&role)),
        )
        .unwrap();

        assert_eq!(
            projection_runbook_state(&dir, RunbookTool::Codex, &role, &projection_path),
            "outdated"
        );

        fs::write(
            &projection_path,
            tool_runbook_content(RunbookTool::Codex, &role, &custom_source),
        )
        .unwrap();
        assert_eq!(
            projection_runbook_state(&dir, RunbookTool::Codex, &role, &projection_path),
            "managed"
        );

        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn runbook_digest_uses_source_sections() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = env::temp_dir().join(format!("tm-agent-runbook-digest-{unique}"));
        let role = selected_runbook_roles(Some("executor")).unwrap().remove(0);
        let source_path = runbook_source_path(&dir, &role);
        fs::create_dir_all(source_path.parent().unwrap()).unwrap();
        fs::write(
            &source_path,
            "\
## When To Use
- Custom when

## Operating Rules
- Custom rule A
- Custom rule B

## Verify
- Custom verify
",
        )
        .unwrap();

        let digest = runbook_digest_content(&dir, &role, "test-agent", "test-team");
        assert!(digest.contains("ROLE: executor"));
        assert!(digest.contains("Custom rule A"));
        assert!(digest.contains("Custom verify"));
        assert!(digest.contains("FULL:"));

        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn unknown_role_digest_does_not_inline_full_runbook() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = env::temp_dir().join(format!("tm-agent-runbook-custom-digest-{unique}"));
        let runbook_dir = dir.join(RUNBOOK_SOURCE_DIR);
        fs::create_dir_all(&runbook_dir).unwrap();
        fs::write(
            runbook_dir.join("custom.md"),
            "## When To Use\n- Custom when\n\n## Operating Rules\n- Custom must\n\nLONG BODY SHOULD NOT INLINE\n",
        )
        .unwrap();

        let digest = runbook_digest_content_for_role_name(
            &dir,
            "custom",
            load_runbook_content_for_role(&dir, "custom").as_deref(),
            "test-agent",
            "test-team",
        );
        assert!(digest.contains("ROLE: custom"));
        assert!(digest.contains("Custom must"));
        assert!(!digest.contains("LONG BODY SHOULD NOT INLINE"));

        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn truncate_summary_counts_unicode_chars() {
        assert_eq!(truncate_summary("가나다라마", 3), "가나다...");
        assert_eq!(truncate_summary("abc", 3), "abc");
    }

    #[test]
    fn reply_summary_strips_one_summary_prefix_and_keeps_first_header() {
        let (headers, summary) = reply_header_and_summary(
            "STATUS: DONE\nSTATUS: BLOCKED\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a\n\nSUMMARY:SUMMARY: keep",
            200,
        );
        assert_eq!(headers["status"].as_str(), Some("DONE"));
        assert_eq!(summary, "SUMMARY: keep");
    }

    #[test]
    fn reply_summary_parses_single_line_header() {
        // codex agents often emit all 5 fields on one line — previously the
        // line-based parser captured the whole line as STATUS and dropped
        // FILES/VERIFY/NEXT/FULL_REPORT as "n/a". split_inline_headers fixes
        // this by reshaping into per-line form before parsing.
        let (headers, _summary) = reply_header_and_summary(
            "STATUS: DONE FILES: none VERIFY: echo \"pong\" NEXT: NONE FULL_REPORT: n/a executor ping ok",
            200,
        );
        assert_eq!(headers["status"].as_str(), Some("DONE"));
        assert_eq!(headers["files"].as_str(), Some("none"));
        assert_eq!(headers["verify"].as_str(), Some("echo \"pong\""));
        assert_eq!(headers["next"].as_str(), Some("NONE"));
        assert_eq!(
            headers["full_report"].as_str(),
            Some("n/a executor ping ok")
        );
    }

    #[test]
    fn reply_summary_handles_mixed_inline_and_newline_headers() {
        // Half on one line, half on separate lines — must still parse all 5.
        let (headers, _) = reply_header_and_summary(
            "STATUS: DONE FILES: a.rs\nVERIFY: cargo test\nNEXT: NONE FULL_REPORT: /tmp/x.md\n\nbody",
            200,
        );
        assert_eq!(headers["status"].as_str(), Some("DONE"));
        assert_eq!(headers["files"].as_str(), Some("a.rs"));
        assert_eq!(headers["verify"].as_str(), Some("cargo test"));
        assert_eq!(headers["next"].as_str(), Some("NONE"));
        assert_eq!(headers["full_report"].as_str(), Some("/tmp/x.md"));
    }

    #[test]
    fn reply_protocol_status_done() {
        let content =
            "STATUS: DONE\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a\n\nbody";
        let (h, _) = reply_header_and_summary(content, 1500);
        assert_eq!(h["status"].as_str().unwrap(), "DONE");
    }

    #[test]
    fn bare_reply_refuses_multiple_active_tasks() {
        let candidates = vec!["task-a".to_string(), "task-b".to_string()];
        let error = unambiguous_reply_task(&candidates).unwrap_err();
        assert!(error.contains("--task-id"));
    }

    #[test]
    fn bare_reply_keeps_single_task_compatibility() {
        let candidates = vec!["task-a".to_string()];
        assert_eq!(
            unambiguous_reply_task(&candidates).unwrap().as_deref(),
            Some("task-a")
        );
    }

    #[test]
    fn reply_protocol_status_blocked() {
        let content =
            "STATUS: BLOCKED\nFILES: none\nVERIFY: n/a\nNEXT: leader\nFULL_REPORT: n/a\n\nreason";
        let (h, _) = reply_header_and_summary(content, 1500);
        assert_eq!(h["status"].as_str().unwrap(), "BLOCKED");
    }

    #[test]
    fn reply_protocol_status_needs_review() {
        let content = "STATUS: NEEDS_REVIEW\nFILES: a.rs\nVERIFY: n/a\nNEXT: review\nFULL_REPORT: n/a\n\nsummary";
        let (h, _) = reply_header_and_summary(content, 1500);
        assert_eq!(h["status"].as_str().unwrap(), "NEEDS_REVIEW");
    }

    #[test]
    fn protocol_status_helper_done() {
        assert_eq!(protocol_status_to_task_state("DONE"), Some("completed"));
    }

    #[test]
    fn protocol_status_helper_blocked() {
        assert_eq!(protocol_status_to_task_state("BLOCKED"), Some("blocked"));
    }

    #[test]
    fn protocol_status_helper_needs_review() {
        assert_eq!(
            protocol_status_to_task_state("NEEDS_REVIEW"),
            Some("review_ready")
        );
    }

    #[test]
    fn protocol_status_helper_invalid() {
        assert_eq!(protocol_status_to_task_state("invalid"), None);
        assert_eq!(protocol_status_to_task_state("n/a"), None);
        assert_eq!(protocol_status_to_task_state(""), None);
    }

    #[test]
    fn reply_body_only_blocked_reason() {
        let content = "STATUS: BLOCKED\nFILES: none\nVERIFY: n/a\nNEXT: escalate\nFULL_REPORT: n/a\n\nbuild failed: linker error";
        let (_, body) = reply_header_and_summary(content, 1500);
        assert_eq!(body.trim(), "build failed: linker error");
        assert!(!body.contains("STATUS:"), "body must not contain headers");
    }

    #[test]
    fn split_inline_headers_preserves_body_text_with_colon() {
        // " KEY:" only fires for the 5 known header keys. A body line like
        // "Run: cargo test" must not be mistaken for a header boundary.
        let out = split_inline_headers(
            "STATUS: DONE\nRun: cargo test passes locally",
            &["STATUS", "FILES", "VERIFY", "NEXT", "FULL_REPORT"],
        );
        assert!(out.contains("STATUS: DONE"));
        assert!(out.contains("Run: cargo test passes locally"));
    }

    #[test]
    fn instance_scoped_reply_alias_and_result_candidates_exclude_name_only_alias() {
        assert_eq!(
            reply_alias_filename("reviewer", Some("instance-2")),
            "reviewer-instance-2-reply.md"
        );
        assert_eq!(reply_alias_filename("reviewer", None), "reviewer-reply.md");

        let instance_candidates =
            task_result_candidates("team-a", "task-a", "reviewer", Some("instance-2"));
        let instance_names = instance_candidates
            .iter()
            .filter_map(|path| path.file_name().and_then(|name| name.to_str()))
            .collect::<Vec<_>>();
        assert_eq!(
            instance_names,
            vec!["task-a.md", "reviewer-instance-2-reply.md"]
        );
        assert!(!instance_names.contains(&"reviewer-reply.md"));

        let legacy_candidates = task_result_candidates("team-a", "task-a", "reviewer", None);
        assert_eq!(
            legacy_candidates[1]
                .file_name()
                .and_then(|name| name.to_str()),
            Some("reviewer-reply.md")
        );
    }

    #[test]
    fn self_referential_full_report_is_normalized_for_both_durable_copies() {
        let alias = PathBuf::from("/tmp/results/reviewer-instance-2-reply.md");
        let canonical = PathBuf::from("/tmp/results/task-a.md");
        for self_path in [&alias, &canonical] {
            let content = format!(
                "STATUS: DONE\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: {}\n\nsummary",
                self_path.display()
            );
            let (normalized, rejected) = normalize_self_referential_full_report(
                &content,
                &[alias.clone(), canonical.clone()],
            );
            assert_eq!(
                rejected.as_deref(),
                Some(self_path.to_string_lossy().as_ref())
            );
            assert!(normalized.contains("FULL_REPORT: n/a"));
            assert!(!normalized.contains(&self_path.to_string_lossy().to_string()));
        }

        let separate = "/tmp/results/task-a-full.md";
        let content = format!(
            "STATUS: DONE\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: {separate}\n\nsummary"
        );
        let (unchanged, rejected) =
            normalize_self_referential_full_report(&content, &[alias.clone(), canonical.clone()]);
        assert_eq!(unchanged, content);
        assert_eq!(rejected, None);
    }

    #[test]
    fn result_collect_compaction_removes_full_content() {
        let resp = json!({
            "ok": true,
            "result": {
                "results": [{
                    "agent": "executor",
                    "content": "STATUS: DONE\nFILES: a.rs\nVERIFY: cargo test\nNEXT: NONE\nFULL_REPORT: /tmp/full.md\n\nSUMMARY:\nChanged code"
                }]
            }
        });
        let compact = compact_result_collect_response(resp, true);
        let item = &compact["result"]["results"][0];
        assert!(item.get("content").is_none());
        assert_eq!(item["headers"]["status"].as_str(), Some("DONE"));
        assert_eq!(
            item["headers"]["full_report"].as_str(),
            Some("/tmp/full.md")
        );
        assert!(item["summary"].as_str().unwrap().contains("Changed code"));
    }

    #[test]
    fn task_unblock_forwards_optional_correction_without_changing_default() {
        let with_correction =
            task_unblock_params("team-a", "task-a", Some("retry after fixing input"));
        assert_eq!(with_correction["team_name"], "team-a");
        assert_eq!(with_correction["task_id"], "task-a");
        assert_eq!(with_correction["correction"], "retry after fixing input");

        let without_correction = task_unblock_params("team-a", "task-a", None);
        assert!(without_correction.get("correction").is_none());
    }

    #[test]
    fn task_unblock_cli_parses_correction() {
        let parsed = Cli::try_parse_from([
            "tm-agent",
            "task",
            "unblock",
            "task-a",
            "--correction",
            "retry after fixing input",
        ])
        .unwrap();
        assert!(matches!(
            parsed.command,
            Commands::Task(TaskCommands::Unblock {
                id,
                correction: Some(correction),
            }) if id == "task-a" && correction == "retry after fixing input"
        ));
    }

    #[test]
    fn result_collect_compaction_preserves_body_free_parallel_telemetry() {
        let resp = json!({
            "result": { "results": [{
                "task_id": "task-a",
                "agent_instance_id": "instance-a",
                "parallel_telemetry": {
                    "wave_id": "wave-a", "task_id": "task-a",
                    "agent_instance_id": "instance-a", "host": null,
                    "checkout": "checkout-a", "delivery": "completed", "synthesis": "pending"
                },
                "content": "STATUS: DONE\nFILES: none\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: n/a\n\nsecret body"
            }]}
        });
        let compact = compact_result_collect_response(resp, false);
        let item = &compact["result"]["results"][0];
        assert!(item.get("content").is_none());
        assert_eq!(
            item["parallel_telemetry"]["task_id"].as_str(),
            Some("task-a")
        );
        assert_eq!(
            item["parallel_telemetry"]["agent_instance_id"].as_str(),
            Some("instance-a")
        );
        assert!(!item.to_string().contains("secret body"));
    }

    #[test]
    fn collect_result_path_does_not_override_separate_full_report() {
        // result_path is the durable reply copy, not the separately authored FULL_REPORT.
        let resp = json!({
            "result": {
                "results": [{
                    "agent": "executor",
                    "content": "STATUS: DONE\nFILES: a.rs\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: /tmp/header-path.md\n\nbody",
                    "result_path": "/home/user/.term-mesh/results/team/executor-reply.md"
                }]
            }
        });
        let compact = compact_result_collect_response(resp, false);
        let item = &compact["result"]["results"][0];
        assert_eq!(
            item["headers"]["full_report"].as_str(),
            Some("/tmp/header-path.md"),
            "durable result_path must not replace header FULL_REPORT"
        );
        assert_eq!(
            item["result_path"].as_str(),
            Some("/home/user/.term-mesh/results/team/executor-reply.md")
        );
    }

    #[test]
    fn collect_result_path_skips_na_value() {
        // result_path = "n/a" must not override a valid header FULL_REPORT.
        let resp = json!({
            "result": {
                "results": [{
                    "agent": "executor",
                    "content": "STATUS: DONE\nFILES: a.rs\nVERIFY: n/a\nNEXT: NONE\nFULL_REPORT: /tmp/real.md\n\nbody",
                    "result_path": "n/a"
                }]
            }
        });
        let compact = compact_result_collect_response(resp, false);
        let item = &compact["result"]["results"][0];
        assert_eq!(
            item["headers"]["full_report"].as_str(),
            Some("/tmp/real.md"),
            "n/a result_path must not override header FULL_REPORT"
        );
    }

    #[test]
    fn atomic_write_file_replaces_content_without_temp_residue() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let dir = env::temp_dir().join(format!("tm-agent-atomic-result-{unique}"));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("task.md");

        atomic_write_file(&path, "first").unwrap();
        atomic_write_file(&path, "second").unwrap();

        assert_eq!(fs::read_to_string(&path).unwrap(), "second");
        let leftovers: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .filter_map(|entry| entry.ok())
            .filter(|entry| entry.file_name().to_string_lossy().ends_with(".tmp"))
            .collect();
        assert!(leftovers.is_empty());

        fs::remove_dir_all(dir).ok();
    }

    #[test]
    fn return_retry_policy_is_conservative_when_text_delivery_failed() {
        assert_eq!(
            return_retry_delays_ms(true, "team.send"),
            &[250, 400, 600, 800, 1000, 1500, 2500, 4000]
        );
        assert_eq!(
            return_retry_delays_ms(false, "team.send"),
            &[200, 500, 1000, 2000]
        );
        // Init prompt path now uses the same cadence as team.send — paste
        // truncation is handled by chunking in Swift, not by Rust delays.
        assert_eq!(
            return_retry_delays_ms(true, "team.create.init"),
            &[250, 400, 600, 800, 1000, 1500, 2500, 4000]
        );
    }

    #[test]
    fn return_key_echoes_the_send_gate_sequence_id() {
        let params = send_return_key_params(
            "team-a",
            "reviewer",
            Some("panel-7"),
            Some("instance-7"),
            Some("sequence-42"),
        );
        assert_eq!(params["send_sequence_id"], "sequence-42");
        assert_eq!(params["agent_instance_id"], "instance-7");

        let legacy = send_return_key_params("team-a", "reviewer", None, None, None);
        assert!(legacy["send_sequence_id"].is_null());
    }

    #[test]
    fn return_required_is_read_from_the_result_and_absent_means_none() {
        assert_eq!(
            send_response_return_required(&json!({ "result": { "return_required": false } })),
            Some(false)
        );
        assert_eq!(
            send_response_return_required(&json!({ "result": { "return_required": true } })),
            Some(true)
        );
        // An older app that never learned the field keeps the legacy ladder.
        assert_eq!(
            send_response_return_required(&json!({ "result": {} })),
            None
        );
    }

    #[test]
    fn delegate_return_already_submitted_honours_return_required() {
        assert!(delegate_return_already_submitted(
            &json!({ "result": { "return_required": false } })
        ));
        assert!(!delegate_return_already_submitted(
            &json!({ "result": { "return_required": true } })
        ));
        assert!(!delegate_return_already_submitted(&json!({ "result": {} })));
        assert!(delegate_return_already_submitted(
            &json!({ "remote_leader_proxy": true, "result": {} })
        ));
        assert!(delegate_return_already_submitted(
            &json!({ "result": { "return_submitted": true } })
        ));
    }

    #[test]
    fn send_key_skip_precedes_the_first_delay_and_the_rpc() {
        // The socket does not exist, so any RPC attempt could never answer ok,
        // and the text-delivered ladder would begin with a 250 ms sleep:
        // returning true this fast proves the skip runs before both.
        let missing_sock = PathBuf::from("/nonexistent/tm-agent-unit-test.sock");
        let started = std::time::Instant::now();
        assert!(send_return_key_with_retry(
            &missing_sock,
            "team-a",
            "reviewer",
            true,
            "unit-test",
            None,
            None,
            None,
            Some(false),
        ));
        assert!(started.elapsed() < Duration::from_millis(200));
    }
}
