//! Prompt templates for autonomous research agents.
//!
//! Extracted from x-agent SKILL.md (v1.3.0) — Research Agent Prompt.
//! Each agent runs an independent discovery loop, sharing findings via a
//! shared board file (stigmergy: indirect coordination through shared state).

/// Returns the depth instructions string for a given depth level.
fn depth_instructions(depth: &str) -> &'static str {
    match depth {
        "shallow" => "Quick scan only. Prioritize breadth over depth. 1-2 findings per round. Max ~3 files per round.",
        "exhaustive" => "Leave no stone unturned. Cross-reference findings across files. Verify every claim. Max ~15 files per round.",
        // "deep" is the default
        _ => "Follow promising leads 2 levels deep. Verify key findings with a second source. Max ~8 files per round.",
    }
}

/// Assembles a Research Agent prompt for autonomous multi-agent research.
///
/// # Arguments
/// - `topic`       — The research topic or question to investigate
/// - `board_path`  — Absolute path to the shared board JSONL file
/// - `agent_n`     — This agent's index (1-based)
/// - `total`       — Total number of parallel agents
/// - `depth`       — Depth level: "shallow", "deep", or "exhaustive"
/// - `budget`      — Maximum number of discovery rounds
/// - `round`       — Current round (used in board POST format)
/// - `web_allowed` — Whether WebSearch/WebFetch tools are permitted
/// - `focus`       — Optional focus area hint
pub fn research_prompt(
    topic: &str,
    board_path: &str,
    agent_n: u32,
    total: u32,
    depth: &str,
    budget: u32,
    web_allowed: bool,
    focus: Option<&str>,
) -> String {
    let focus_hint = match focus {
        Some(f) => format!("\nFocus area: {f}\n"),
        None => String::new(),
    };

    let web_tools = if web_allowed {
        "- WebSearch, WebFetch for external research\n"
    } else {
        ""
    };

    let depth_instr = depth_instructions(depth);

    format!(
        r#"## Autonomous Research: {topic}{focus_hint}
You are researcher-{agent_n}, one of {total} independent researchers.
Your peers are also writing findings to the shared board.

### Your Tools
- Read, Grep, Glob, Bash for code/file exploration
{web_tools}
### Shared Board (Stigmergy)
BOARD FILE: {board_path}

- To POST a finding: Bash("echo '{{json}}' >> {board_path}")
  Format: {{"agent":"researcher-{agent_n}","round":R,"finding":"...","source":"...","implication":"..."}}
- To READ peer findings: Bash("cat {board_path}")

### Discovery Loop

Run up to {budget} rounds. Each round:

1. **READ BOARD** — Check what peers have discovered
   - Bash("cat {board_path}")
   - If a peer's finding opens a new angle: explore it
   - If a peer's finding overlaps your current line: pivot to avoid duplication
   - If a peer's finding contradicts yours: investigate the discrepancy

2. **FRAME** — What is the most valuable question to explore next?
   - Round 1: derive from the topic directly
   - Round 2+: informed by your findings AND board contents

3. **EXPLORE** — Gather evidence for your current question
   - {depth_instr}
   - Cite every finding: file path, line number, URL, or inference

4. **POST** — Write your finding to the board
   - Bash("echo '{{\"agent\":\"researcher-{agent_n}\",\"round\":R,\"finding\":\"...\",\"source\":\"...\",\"implication\":\"...\"}}' >> {board_path}")
   - Only post genuinely useful discoveries, not every observation

5. **JUDGE** — Should you continue?
   - STOP if: your questions are answered + confidence is high + board shows convergence
   - CONTINUE if: budget remains + open questions exist or board suggests new angles

### Depth: {depth}
{depth_instr}

### Final Report

When done (STOP or budget exhausted), output:

## Findings
| # | Finding | Confidence | Source |
|---|---------|------------|--------|
(number each finding, HIGH/MEDIUM/LOW confidence, cite source)

## Key Insights
- (3-5 most important takeaways)

## Board Interactions
- (what you learned from the board, how it changed your direction)
- (which peer findings influenced your exploration)

## Open Questions
- (what you couldn't resolve within budget)

## Self-Assessment
- Rounds used: X/{budget}
- Thoroughness: (1-10)
- Confidence: CONFIDENT / UNCERTAIN
"#,
        topic = topic,
        focus_hint = focus_hint,
        agent_n = agent_n,
        total = total,
        web_tools = web_tools,
        board_path = board_path,
        budget = budget,
        depth = depth,
        depth_instr = depth_instr,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_research_prompt_basic() {
        let prompt = research_prompt(
            "How does the tab system work?",
            "/tmp/research/board.jsonl",
            1,
            3,
            "deep",
            5,
            false,
            None,
        );
        assert!(prompt.contains("researcher-1"));
        assert!(prompt.contains("/tmp/research/board.jsonl"));
        assert!(prompt.contains("Run up to 5 rounds"));
        assert!(prompt.contains("Follow promising leads 2 levels deep"));
        assert!(!prompt.contains("WebSearch"));
    }

    #[test]
    fn test_research_prompt_web_and_focus() {
        let prompt = research_prompt(
            "Security vulnerabilities",
            "/tmp/board.jsonl",
            2,
            4,
            "exhaustive",
            8,
            true,
            Some("authentication layer"),
        );
        assert!(prompt.contains("researcher-2"));
        assert!(prompt.contains("Focus area: authentication layer"));
        assert!(prompt.contains("WebSearch"));
        assert!(prompt.contains("Leave no stone unturned"));
    }

    #[test]
    fn test_research_prompt_shallow() {
        let prompt = research_prompt(
            "Quick overview",
            "/tmp/board.jsonl",
            1,
            1,
            "shallow",
            2,
            false,
            None,
        );
        assert!(prompt.contains("Quick scan only"));
    }

    #[test]
    fn test_cross_review_prompt() {
        let prompt = cross_review_prompt(
            "stablecoins",
            "{\"agent\":\"r-1\",\"finding\":\"test\"}",
            "explorer",
            &["explorer".to_string(), "executor".to_string()],
        );
        assert!(prompt.contains("You are explorer"));
        assert!(prompt.contains("executor"));
        assert!(prompt.contains("Contradictions"));
    }

    #[test]
    fn test_synthesis_prompt() {
        let prompt = synthesis_prompt("stablecoins", "### explorer review\nGood stuff");
        assert!(prompt.contains("Consensus Points"));
        assert!(prompt.contains("Executive Summary"));
    }

    #[test]
    fn test_solve_prompt() {
        let prompt = solve_prompt("Fix login bug", "/tmp/board.jsonl", 1, 3, 5, Some("bun test"), Some("src/auth.ts"));
        assert!(prompt.contains("solver-1"));
        assert!(prompt.contains("bun test"));
        assert!(prompt.contains("src/auth.ts"));
        assert!(prompt.contains("Try-Share-Adapt"));
    }

    #[test]
    fn test_consensus_prompt() {
        let prompt = consensus_prompt("REST vs GraphQL", "/tmp/board.jsonl", 2, 4, 4, Some("backend perspective"));
        assert!(prompt.contains("voice-2"));
        assert!(prompt.contains("backend perspective"));
        assert!(prompt.contains("Deliberation Loop"));
    }

    #[test]
    fn test_swarm_prompt() {
        let prompt = swarm_prompt("Migrate to v2", "/tmp/board.jsonl", 1, 3, 10, None);
        assert!(prompt.contains("swarm-1"));
        assert!(prompt.contains("Swarm Loop"));
        assert!(prompt.contains("goal_check"));
    }
}

pub fn solve_prompt(
    problem: &str,
    board_path: &str,
    agent_n: u32,
    total: u32,
    budget: u32,
    verify_cmd: Option<&str>,
    target: Option<&str>,
) -> String {
    let verify_hint = match verify_cmd {
        Some(cmd) => format!("\nVerification command: `{cmd}` — run this after each attempt to check success.\n"),
        None => String::new(),
    };
    let target_hint = match target {
        Some(t) => format!("\nFocus area: {t}\n"),
        None => String::new(),
    };

    format!(
        r#"## Autonomous Problem Solving: {problem}{target_hint}{verify_hint}
You are solver-{agent_n}, one of {total} independent problem solvers.
Your peers are also posting attempts to the shared board.

### Your Tools
- Read, Grep, Glob, Bash for code/file exploration and modification
- You CAN edit files to attempt fixes

### Shared Board (Stigmergy)
BOARD FILE: {board_path}

Board entry types:
- attempt: {{"type":"attempt","agent":"solver-{agent_n}","round":R,"approach":"...","result":"success|failed|partial","detail":"...","files_changed":["path"]}}
- insight: {{"type":"insight","agent":"solver-{agent_n}","round":R,"insight":"...","confidence":"HIGH|MEDIUM|LOW"}}
- abandon: {{"type":"abandon","agent":"solver-{agent_n}","round":R,"approach":"...","reason":"..."}}
- adopt: {{"type":"adopt","agent":"solver-{agent_n}","round":R,"from":"solver-M","approach":"...","adaptation":"..."}}
- solved: {{"type":"solved","agent":"solver-{agent_n}","round":R,"solution":"...","verification":"..."}}

To POST: Bash("echo '{{json}}' >> {board_path}")
To READ: Bash("cat {board_path}")

### Try-Share-Adapt Loop

Run up to {budget} rounds. Each round:

1. **READ BOARD** — What failed? What worked? Is it already solved?
   - If a peer posted "solved": verify their solution, then STOP
   - If a peer's approach failed: avoid it or adapt it
   - If a peer shared an insight: incorporate it

2. **FRAME** — Choose your approach
   - Round 1: pick independently based on problem analysis
   - Round 2+: informed by board — adopt promising approaches, avoid dead ends

3. **TRY** — Attempt the solution
   - Make actual code changes if needed
   - Test your changes

4. **POST** — Write your attempt result to the board
   - Success? Post "solved" with verification details
   - Failed? Post "attempt" with what went wrong
   - Found something useful? Post "insight"

5. **VERIFY** — If solution looks good, run verification
   - STOP if verified; post "solved"
   - CONTINUE if more work needed

### Final Report

When done, output:
## Solution
(describe what worked or best attempt)

## Attempts Summary
| # | Approach | Result | Detail |
|---|----------|--------|--------|

## Board Interactions
- What you learned from peers
- Approaches adopted/abandoned based on board

## Self-Assessment
- Rounds used: X/{budget}
- Status: SOLVED / PARTIAL / UNSOLVED
"#,
        problem = problem,
        target_hint = target_hint,
        verify_hint = verify_hint,
        agent_n = agent_n,
        total = total,
        board_path = board_path,
        budget = budget,
    )
}

pub fn consensus_prompt(
    question: &str,
    board_path: &str,
    agent_n: u32,
    total: u32,
    budget: u32,
    perspective: Option<&str>,
) -> String {
    let perspective_hint = match perspective {
        Some(p) => format!("\nYour assigned perspective: {p}\n"),
        None => String::new(),
    };

    format!(
        r#"## Autonomous Consensus: {question}{perspective_hint}
You are voice-{agent_n}, one of {total} independent voices in a deliberation.
Your peers are also posting positions to the shared board.

### Your Tools
- Read, Grep, Glob, Bash for research and evidence gathering

### Shared Board (Stigmergy)
BOARD FILE: {board_path}

Board entry types:
- position: {{"type":"position","agent":"voice-{agent_n}","round":R,"stance":"...","rationale":"...","confidence":N}}
- revision: {{"type":"revision","agent":"voice-{agent_n}","round":R,"prev_stance":"...","new_stance":"...","reason":"...","confidence":N}}
- challenge: {{"type":"challenge","agent":"voice-{agent_n}","round":R,"target":"voice-M","question":"..."}}
- concede: {{"type":"concede","agent":"voice-{agent_n}","round":R,"point":"...","to":"voice-M","reason":"..."}}

confidence is 1-10 (10 = absolute certainty).
To POST: Bash("echo '{{json}}' >> {board_path}")
To READ: Bash("cat {board_path}")

### Deliberation Loop

Run up to {budget} rounds. Each round:

1. **READ BOARD** — All current positions and exchanges
   - Note who holds what position and their confidence levels
   - Look for challenges directed at you

2. **REASON** — Independently evaluate each peer's argument
   - Are their rationales sound?
   - Do they cite evidence you missed?
   - Are there logical flaws?

3. **DECIDE** — Choose one action:
   - HOLD: maintain your position (post nothing or restate with updated confidence)
   - REVISE: change your stance based on new evidence (post "revision")
   - CHALLENGE: question a specific peer's argument (post "challenge")
   - CONCEDE: acknowledge a peer made a better point (post "concede")

4. **POST** — Write your action to the board with confidence (1-10)

5. **CHECK CONVERGENCE** — If all recent positions are aligned, STOP

### Final Report

When done, output:
## My Final Position
(your stance and rationale)

## Deliberation Journey
| Round | Action | Confidence | Detail |
|-------|--------|------------|--------|

## Board Interactions
- Positions that influenced you
- Challenges you made or received

## Convergence Assessment
- Did the group converge? On what?
- Remaining disagreements
- Confidence: 1-10
"#,
        question = question,
        perspective_hint = perspective_hint,
        agent_n = agent_n,
        total = total,
        board_path = board_path,
        budget = budget,
    )
}

pub fn swarm_prompt(
    goal: &str,
    board_path: &str,
    agent_n: u32,
    total: u32,
    budget: u32,
    seed_tasks: Option<&str>,
) -> String {
    let seed_hint = match seed_tasks {
        Some(_s) => format!("\nInitial seed tasks have been added to the board. Read the board to find open tasks.\n"),
        None => format!("\nNo seed tasks provided. Read the board — the leader has seeded initial tasks based on goal analysis.\n"),
    };

    format!(
        r#"## Autonomous Swarm: {goal}{seed_hint}
You are swarm-{agent_n}, one of {total} autonomous workers.
Your peers are also claiming and executing tasks from the shared board.

### Your Tools
- Read, Grep, Glob, Bash for exploration AND file modification
- You CAN edit files to complete tasks

### Shared Board (Stigmergy)
BOARD FILE: {board_path}

Board entry types:
- task: {{"type":"task","id":N,"desc":"description","status":"open","added_by":"leader|swarm-{agent_n}"}}
- claim: {{"type":"claim","id":N,"agent":"swarm-{agent_n}","ts":"ISO timestamp"}}
- result: {{"type":"result","id":N,"agent":"swarm-{agent_n}","status":"done|failed","output":"summary","new_tasks":["desc1","desc2"]}}
- goal_check: {{"type":"goal_check","agent":"swarm-{agent_n}","progress":"...","remaining":N}}

To POST: Bash("echo '{{json}}' >> {board_path}")
To READ: Bash("cat {board_path}")

### Swarm Loop

Run up to {budget} rounds. Each round:

1. **READ BOARD** — Find open (unclaimed) tasks
   - Look for tasks with status "open" and no corresponding "claim" entry
   - Check if someone else already claimed the task you want

2. **CLAIM** — Write a claim entry to prevent double-work
   - Post claim immediately before starting work
   - If you see another agent claimed it first, pick a different task

3. **EXECUTE** — Do the actual work
   - Read files, analyze, write code, run tests — whatever the task requires
   - Focus on completing one task at a time

4. **POST RESULT** — Write result + any new tasks discovered
   - If you discover subtasks while working, add them as new "task" entries
   - If you complete the task, post result with status "done"
   - If you fail, post result with status "failed" and explain why

5. **CHECK GOAL** — Is the overall goal met?
   - Post a "goal_check" entry with progress estimate
   - STOP if goal appears fully met
   - CONTINUE if open tasks remain

### Final Report

When done, output:
## Tasks Completed
| ID | Task | Status | Output |
|----|------|--------|--------|

## Tasks Spawned
(new tasks you added to the board)

## Goal Progress
- Estimated completion: X%
- Remaining work

## Self-Assessment
- Rounds used: X/{budget}
- Tasks completed: N
- Tasks spawned: N
"#,
        goal = goal,
        seed_hint = seed_hint,
        agent_n = agent_n,
        total = total,
        board_path = board_path,
        budget = budget,
    )
}

/// Cross-review prompt: agent reads all board findings and examines them.
pub fn cross_review_prompt(
    topic: &str,
    board_contents: &str,
    my_name: &str,
    all_agents: &[String],
) -> String {
    let peers: Vec<&str> = all_agents.iter()
        .filter(|a| a.as_str() != my_name)
        .map(|a| a.as_str())
        .collect();
    let peer_list = peers.join(", ");

    format!(
        r#"## Research Discussion: Cross-Review

Topic: {topic}
You are {my_name}. Your peers: {peer_list}.

Below are ALL findings from the research phase (board.jsonl):

{board_contents}

Read every finding carefully. Then respond with:

### 1. Strongest Findings
Which 2-3 findings (by any researcher, including yourself) are the most valuable? Why?

### 2. Contradictions & Gaps
- Do any findings contradict each other? Cite specific entries.
- What important aspects of "{topic}" were NOT covered?

### 3. Challenges
- Pick 1-2 findings from OTHER researchers that you disagree with or find weak. Explain why.
- Address them by name: "{peer_list}"

### 4. Synthesis Proposal
In 3-5 bullet points, what should the final consensus be?

Keep total response under 400 words.
"#,
        topic = topic,
        my_name = my_name,
        peer_list = peer_list,
        board_contents = board_contents,
    )
}

/// Synthesis prompt: converge on consensus after cross-review.
pub fn synthesis_prompt(
    topic: &str,
    cross_review_summary: &str,
) -> String {
    format!(
        r#"## Research Discussion: Final Synthesis

Topic: {topic}

Below are all agents' cross-reviews of the research findings:

{cross_review_summary}

Based on the cross-reviews above, produce a FINAL SYNTHESIS:

### Consensus Points
List 3-5 points that all or most reviewers agree on. Be specific.

### Open Disputes
List any points where reviewers disagree. For each:
- The disagreement
- Who holds which position
- What evidence would resolve it

### Executive Summary
Write a 150-word summary of "{topic}" that reflects the group consensus.
Incorporate the strongest findings and note any caveats from the disputes.

### Confidence Assessment
Rate overall research confidence: HIGH / MEDIUM / LOW
Justify in one sentence.

Keep total response under 400 words.
"#,
        topic = topic,
        cross_review_summary = cross_review_summary,
    )
}
