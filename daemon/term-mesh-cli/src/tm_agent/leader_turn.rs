use super::*;

// ── leader turn records: measurement-only per-turn log ───────────────
// Two independent record sources, deliberately not joined at write time: the
// Claude harness hooks write `turn_start`/`turn_end`, and the leader writes
// `turn_route` through `tm-agent leader turn route`. The gap between the two
// counts IS the measurement — `count(turn_start) - count(turn_route)` is the
// number of turns where the leader never stated a route. Recording both from
// one place would destroy that, because a missing leader report would become
// indistinguishable from a turn that never happened.

/// `~/.term-mesh/logs/turns.log`.
///
/// The `.log` extension is deliberate and load-bearing, not a naming
/// preference: `scan_logs` in `term-meshd/src/gc.rs` filters on
/// `extension() == Some("log")`, so a `turns.jsonl` would be an append-only
/// file that grows without bound and that nothing would ever rotate. The
/// contents are still one JSON object per line — the extension describes who
/// manages the file's lifetime, not how to parse it.
///
/// Rotation is automatic, not opt-in: `CATEGORY_LOGS` is in `AUTO_CATEGORIES`
/// (`gc.rs`), and the daemon runs `periodic_safe_sweep` once at startup and
/// then every six hours (`term-meshd/src/main.rs`). A file over
/// `LOG_ROTATE_BYTES` (10 MiB) is renamed to `turns.log.1`, so exactly one
/// generation of history survives. Size the reader's expectations accordingly:
/// a long-running measurement window may need `turns.log.1` too.
///
/// Same directory and the same `create(true).append(true)` discipline as
/// `wt_log` in `term-meshd/src/worktree.rs`, so the daemon and this CLI stay
/// consistent about where append-only records live.
pub(crate) fn turn_log_path() -> Result<PathBuf, String> {
    let home = env::var("HOME")
        .ok()
        .filter(|h| !h.is_empty())
        .ok_or_else(|| "HOME is not set; cannot locate ~/.term-mesh/logs".to_string())?;
    Ok(Path::new(&home)
        .join(".term-mesh")
        .join("logs")
        .join("turns.log"))
}

/// Build one `turn_route` record.
///
/// Pure and separate from the append so the field stance is testable without
/// touching a filesystem — the same reason `delegate_rpc_params` is pure.
///
/// Stance inherited from 526649a1: `route` is stored verbatim (no validation,
/// no normalization, no rejection), and an unstated optional field is OMITTED
/// rather than written as `null`. Absence reads as "not stated"; a `null` would
/// read as a value, and a blank flag value must not become an empty string that
/// a later reader counts as a real classification.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct LeaderParticipationDirective {
    participation: &'static str,
    route: &'static str,
    reasons: Vec<&'static str>,
    dispatch_bounds: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct OverlapCanaryAdmission {
    eligible: bool,
    reasons: Vec<&'static str>,
}

impl OverlapCanaryAdmission {
    fn evaluate(
        delegated_overlap_resolution: bool,
        capability: bool,
        effective_delegation: Option<&str>,
        route: &str,
        suggested_route: Option<&str>,
        checkout_mode: Option<&str>,
        ready_mutating_slices: Option<u32>,
        ownership_disjoint: bool,
        leader_lane_disjoint: bool,
        concurrent_write_overlap: Option<u32>,
        serial_integration: bool,
        resource_health: Option<&str>,
    ) -> Self {
        let mut reasons = Vec::new();
        if !delegated_overlap_resolution {
            reasons.push("delegated_overlap_not_resolved");
        }
        if !capability {
            reasons.push("capability_missing_or_stale");
        }
        if effective_delegation != Some("delegated") {
            reasons.push("delegation_not_delegated");
        }
        if route != "parallel" {
            reasons.push("route_not_parallel");
        }
        if suggested_route != Some("parallel") {
            reasons.push("suggested_route_not_parallel");
        }
        if suggested_route != Some(route) {
            reasons.push("route_deviation");
        }
        if checkout_mode.map(str::trim) != Some("isolated") {
            reasons.push("checkout_not_isolated");
        }
        if ready_mutating_slices.map_or(true, |count| count < 2) {
            reasons.push("fewer_than_two_ready_mutating_slices");
        }
        if !ownership_disjoint {
            reasons.push("worker_ownership_overlap");
        }
        if !leader_lane_disjoint {
            reasons.push("leader_lane_overlap");
        }
        if concurrent_write_overlap != Some(0) {
            reasons.push("concurrent_write_overlap");
        }
        if !serial_integration {
            reasons.push("non_serial_integration");
        }
        if resource_health.map(str::trim) != Some("passed") {
            reasons.push("resource_health_not_passed");
        }
        Self {
            eligible: reasons.is_empty(),
            reasons,
        }
    }
}

impl LeaderParticipationDirective {
    fn from_input(
        task_shape: Option<&str>,
        risk_reasons: &[String],
        available_workers: Option<u32>,
        delegation_level: Option<&str>,
        max_parallel_workers: Option<u32>,
    ) -> Self {
        let shape = task_shape.map(str::trim).map(str::to_ascii_lowercase);
        let Some(workers) = available_workers else {
            return Self {
                participation: "hands_on",
                route: "direct",
                reasons: vec!["unsupported_input"],
                dispatch_bounds: "no required worker dispatch".into(),
            };
        };
        let cap = max_parallel_workers.unwrap_or(3).clamp(1, 10);
        let wave = workers.min(cap);
        if workers == 0 {
            return Self {
                participation: "hands_on",
                route: "direct",
                reasons: vec!["no_available_workers"],
                dispatch_bounds: "no required worker dispatch".into(),
            };
        }
        if delegation_level == Some("delegated")
            && (shape.as_deref() == Some("single_unit") || wave == 1)
        {
            return Self {
                participation: "coordinator",
                route: "delegated",
                reasons: vec!["delegated_serial_work"],
                dispatch_bounds: "exactly one implementation worker".into(),
            };
        }
        if delegation_level == Some("delegated") {
            return Self {
                participation: "coordinator",
                route: "parallel",
                reasons: vec!["delegated_max_capacity"],
                dispatch_bounds: format!(
                    "up to {wave} useful dependency-ready, ownership-disjoint tasks; one if serial"
                ),
            };
        }
        if risk_reasons.iter().any(|reason| !reason.trim().is_empty()) {
            return Self {
                participation: "balanced",
                route: "probe",
                reasons: vec!["high_risk"],
                dispatch_bounds: "at most one read-only probe".into(),
            };
        }
        if workers >= 2
            && matches!(
                shape.as_deref(),
                Some("multi_unit" | "cross_subsystem" | "parallelizable")
            )
        {
            return Self {
                participation: "coordinator",
                route: "parallel",
                reasons: vec!["parallel_ready"],
                dispatch_bounds: format!(
                    "two to {wave} dependency-ready, ownership-disjoint tasks"
                ),
            };
        }
        if shape.as_deref() == Some("single_unit") {
            return Self {
                participation: "hands_on",
                route: "direct",
                reasons: vec!["single_unit"],
                dispatch_bounds: "no required worker dispatch".into(),
            };
        }
        Self {
            participation: "balanced",
            route: "probe",
            reasons: vec!["limited_capacity"],
            dispatch_bounds: "at most one read-only probe".into(),
        }
    }
}

pub(crate) const OVERLAP_CANARY_CAPABILITY_VERSION: u64 = 1;

pub(crate) const LEADER_CONTROL_MAX_BYTES: usize = 64 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct LeaderParticipationControlSnapshot {
    mode: String,
    percent: u8,
    kill_switch: bool,
    supported: bool,
    healthy: bool,
    opt_in: bool,
    project_id: String,
    session_id: String,
    delegation_level: Option<String>,
    delegation_effective: Option<String>,
    max_parallel_workers: Option<u32>,
    overlap_canary_capability: bool,
    overlap_canary_capability_version: Option<u64>,
    delegated_overlap_resolution: bool,
    health_scope: Option<String>,
    leader_policy_version: Option<u64>,
    leader_policy_digest: Option<String>,
}

impl LeaderParticipationControlSnapshot {
    fn overlap_canary_capability(&self) -> bool {
        self.overlap_canary_capability
            && self.overlap_canary_capability_version == Some(OVERLAP_CANARY_CAPABILITY_VERSION)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum LeaderParticipationControlState {
    NotRequested,
    Invalid,
    Valid(LeaderParticipationControlSnapshot),
}

impl LeaderParticipationControlState {
    fn snapshot(&self) -> Option<&LeaderParticipationControlSnapshot> {
        match self {
            Self::Valid(snapshot) => Some(snapshot),
            Self::NotRequested | Self::Invalid => None,
        }
    }

    fn is_invalid(&self) -> bool {
        matches!(self, Self::Invalid)
    }
}

pub(crate) fn parse_leader_control_snapshot(
    data: &[u8],
    project_id: &str,
    expected_session_id: &str,
) -> Option<LeaderParticipationControlSnapshot> {
    let value = serde_json::from_slice::<Value>(data).ok()?;
    if value["schema_version"].as_u64() != Some(1)
        || value["project_id"].as_str() != Some(project_id)
    {
        return None;
    }
    let session_id = value["session_id"].as_str()?.to_string();
    if expected_session_id.trim().is_empty() || session_id != expected_session_id {
        return None;
    }
    let max_parallel_workers = match value.get("max_parallel_workers") {
        Some(value) => Some(value.as_u64()?.clamp(1, 10) as u32),
        None => None,
    };
    let delegation_effective = value["delegation_effective"].as_str().map(str::to_string);
    let delegation_level = delegation_effective
        .clone()
        .or_else(|| value["delegation_configured"].as_str().map(str::to_string));
    let leader_policy_version = match value.get("leader_policy_version") {
        Some(value) => Some(value.as_u64()?),
        None => None,
    };
    let leader_policy_digest = match value.get("leader_policy_digest") {
        Some(value) => Some(value.as_str()?.to_string()),
        None => None,
    };
    Some(LeaderParticipationControlSnapshot {
        // Legacy rollout fields remain optional telemetry. They never decide
        // whether mandatory delegated guidance applies.
        mode: value["mode"]
            .as_str()
            .unwrap_or("off")
            .trim()
            .to_ascii_lowercase(),
        percent: value["percent"].as_u64().unwrap_or(0).min(100) as u8,
        kill_switch: value["kill_switch"].as_bool().unwrap_or(false),
        supported: value["supported"].as_bool().unwrap_or(false),
        healthy: value["healthy"].as_bool().unwrap_or(false),
        opt_in: value["opt_in"].as_bool().unwrap_or(false),
        project_id: project_id.to_string(),
        session_id,
        delegation_level,
        delegation_effective,
        max_parallel_workers,
        overlap_canary_capability: value["overlap_canary_capability"].as_bool() == Some(true),
        overlap_canary_capability_version: value["overlap_canary_capability_version"].as_u64(),
        delegated_overlap_resolution: value["delegated_overlap_resolution"].as_bool() == Some(true),
        health_scope: value["health_scope"].as_str().map(str::to_string),
        leader_policy_version,
        leader_policy_digest,
    })
}

pub(crate) fn read_leader_control_snapshot(
    path: &Path,
    project_id: &str,
    expected_session_id: &str,
) -> Option<LeaderParticipationControlSnapshot> {
    use std::os::unix::fs::MetadataExt;

    let file = fs::File::open(path).ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.file_type().is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
        || metadata.len() > LEADER_CONTROL_MAX_BYTES as u64
    {
        return None;
    }
    let mut data = Vec::with_capacity(LEADER_CONTROL_MAX_BYTES);
    file.take((LEADER_CONTROL_MAX_BYTES + 1) as u64)
        .read_to_end(&mut data)
        .ok()?;
    if data.len() > LEADER_CONTROL_MAX_BYTES {
        return None;
    }
    parse_leader_control_snapshot(&data, project_id, expected_session_id)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct LeaderParticipationResolution {
    mode: &'static str,
    cohort: &'static str,
    applied: bool,
    delegated_overlap_resolution: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct LeaderParticipationCanaryConfig {
    mode: String,
    percent: u8,
    kill_switch: bool,
    supported: bool,
    healthy: bool,
    opt_in: bool,
    project_id: String,
    session_id: String,
    delegation_level: Option<String>,
    delegation_effective: Option<String>,
    max_parallel_workers: Option<u32>,
    overlap_canary_capability: bool,
    overlap_canary_capability_version: Option<u64>,
    delegated_overlap_resolution: bool,
    health_scope: Option<String>,
}

#[derive(Debug, Default, PartialEq)]
pub(crate) struct LeaderParticipationHealth {
    supported_turns: usize,
    linked_turns: usize,
    stated_turns: usize,
    unstated_turns: usize,
    observed_days: u64,
    malformed_lines: usize,
}

impl LeaderParticipationHealth {
    /// Coverage, linkage, and unknown-route ratios. Zero supported turns
    /// would otherwise divide by zero; (0, 0, 1) reads as "no coverage, no
    /// linkage, every turn unknown" instead of NaN, and still fails the gate
    /// below. Shared by `passes_promotion_gate` and the health report so the
    /// two never drift apart.
    fn ratios(&self) -> (f64, f64, f64) {
        if self.supported_turns == 0 {
            return (0.0, 0.0, 1.0);
        }
        let supported = self.supported_turns as f64;
        let coverage = (self.stated_turns + self.unstated_turns) as f64 / supported;
        let linkage = self.linked_turns as f64 / supported;
        let unknown_rate = (self.supported_turns - self.stated_turns) as f64 / supported;
        (coverage, linkage, unknown_rate)
    }

    fn passes_promotion_gate(&self) -> bool {
        if self.supported_turns == 0 || self.malformed_lines > 0 {
            return false;
        }
        let (coverage, linkage, unknown_rate) = self.ratios();
        (self.supported_turns >= 500 || self.observed_days >= 7)
            && coverage >= 0.95
            && linkage >= 0.95
            && unknown_rate <= 0.02
    }
}

pub(crate) fn leader_participation_health(
    log_path: &Path,
    project_id: &str,
    pending_turn_id: Option<&str>,
) -> LeaderParticipationHealth {
    let rotated = log_path.with_extension("log.1");
    let mut records = Vec::new();
    let mut malformed_lines = 0;
    for path in [&rotated, log_path] {
        let Ok(data) = fs::read(path) else { continue };
        let complete_len = data
            .iter()
            .rposition(|byte| *byte == b'\n')
            .map(|index| index + 1)
            .unwrap_or(0);
        if complete_len < data.len() {
            malformed_lines += 1;
        }
        for line in data[..complete_len].split(|byte| *byte == b'\n') {
            if line.is_empty() {
                continue;
            }
            let Ok(record) = serde_json::from_slice::<Value>(line) else {
                malformed_lines += 1;
                continue;
            };
            let event = record["event"].as_str();
            if event.is_none() {
                // `event` missing or not a string: the record is malformed.
                malformed_lines += 1;
                continue;
            }
            if !matches!(event, Some("turn_start" | "turn_route" | "turn_end")) {
                // turns.log also carries non-turn entries (task_dispatch, task_lifecycle)
                // written by tm-agent and the leader turn hook; skip, not malformed.
                continue;
            }
            // One host's turns.log carries every Project that ran on it. A turn
            // record naming another Project is not this Project's measurement,
            // broken fields included: counting it here let one Project's damaged
            // line close another Project's gate for as long as the line stayed
            // in the file. Lines that name no Project at all are still counted,
            // since an unattributable line means the log itself is damaged.
            if let Some(team) = record["team"].as_str() {
                if team != project_id {
                    continue;
                }
            }
            let valid = record["turn_id"]
                .as_str()
                .is_some_and(|value| !value.is_empty())
                && record["ts"].as_str().and_then(iso8601_day_number).is_some()
                && record["team"].as_str().is_some();
            if !valid {
                malformed_lines += 1;
                continue;
            }
            records.push(record);
        }
    }

    let absorbed: std::collections::HashSet<&str> = records
        .iter()
        .filter(|record| {
            record["event"].as_str() == Some("turn_end")
                && record["route_status"].as_str() == Some("absorbed")
        })
        .filter_map(|record| record["turn_id"].as_str())
        .collect();
    let routed: std::collections::HashSet<&str> = records
        .iter()
        .filter(|record| record["event"].as_str() == Some("turn_route"))
        .filter_map(|record| record["turn_id"].as_str())
        .collect();
    let ended: std::collections::HashSet<&str> = records
        .iter()
        .filter(|record| record["event"].as_str() == Some("turn_end"))
        .filter_map(|record| record["turn_id"].as_str())
        .collect();
    let mut start_ids = std::collections::HashSet::new();
    let mut unique_starts = Vec::new();
    for (record, turn_id) in records
        .iter()
        .filter(|record| record["event"].as_str() == Some("turn_start"))
        .filter_map(|record| record["turn_id"].as_str().map(|turn_id| (record, turn_id)))
    {
        if !start_ids.insert(turn_id) {
            malformed_lines += 1;
            continue;
        }
        unique_starts.push(record);
    }
    let starts: Vec<&Value> = unique_starts
        .into_iter()
        .filter(|record| {
            record["turn_id"].as_str().is_some_and(|turn_id| {
                !absorbed.contains(turn_id) && Some(turn_id) != pending_turn_id
            })
        })
        .collect();
    let mut stated_turns = 0;
    let mut unstated_turns = 0;
    let mut linked_turns = 0;
    for start in &starts {
        let Some(turn_id) = start["turn_id"].as_str() else {
            continue;
        };
        let has_route = routed.contains(turn_id);
        let has_end = ended.contains(turn_id);
        if has_route {
            stated_turns += 1;
        } else if has_end {
            unstated_turns += 1;
        }
        if turn_id != "unknown" && turn_id != "unstated" && has_route && has_end {
            linked_turns += 1;
        }
    }
    let mut days = starts
        .iter()
        .filter_map(|record| record["ts"].as_str())
        .filter_map(iso8601_day_number)
        .collect::<Vec<_>>();
    days.sort_unstable();
    let observed_days = days
        .first()
        .zip(days.last())
        .map(|(first, last)| (last - first + 1) as u64)
        .unwrap_or(0);
    LeaderParticipationHealth {
        supported_turns: starts.len(),
        linked_turns,
        stated_turns,
        unstated_turns,
        observed_days,
        malformed_lines,
    }
}

/// Read-only report behind `leader turn health`. Pure over an already
/// resolved log path so its field stance is testable without touching the
/// CLI dispatch or `$HOME`, the same reason `leader_participation_health`
/// itself takes a path instead of resolving one.
pub(crate) fn leader_turn_health_report(log_path: &Path, project_id: &str) -> Value {
    let health = leader_participation_health(log_path, project_id, None);
    let (coverage, linkage, unknown_rate) = health.ratios();
    json!({
        "schema_version": 1,
        "project": project_id,
        "scope": "execution_host_project",
        "supported_turns": health.supported_turns,
        "linked_turns": health.linked_turns,
        "stated_turns": health.stated_turns,
        "unstated_turns": health.unstated_turns,
        "observed_days": health.observed_days,
        "malformed_lines": health.malformed_lines,
        "coverage": coverage,
        "linkage": linkage,
        "unknown_rate": unknown_rate,
        "passes_promotion_gate": health.passes_promotion_gate(),
    })
}

/// One human-readable line for `leader turn health` without `--json`. Reads
/// the already-built report instead of recomputing anything, so the printed
/// numbers cannot drift from the JSON output.
pub(crate) fn format_leader_turn_health_line(report: &Value) -> String {
    format!(
        "project={} passes_promotion_gate={} supported_turns={} linked_turns={} \
         stated_turns={} unstated_turns={} observed_days={} malformed_lines={} \
         coverage={:.4} linkage={:.4} unknown_rate={:.4}",
        report["project"].as_str().unwrap_or(""),
        report["passes_promotion_gate"].as_bool().unwrap_or(false),
        report["supported_turns"].as_u64().unwrap_or(0),
        report["linked_turns"].as_u64().unwrap_or(0),
        report["stated_turns"].as_u64().unwrap_or(0),
        report["unstated_turns"].as_u64().unwrap_or(0),
        report["observed_days"].as_u64().unwrap_or(0),
        report["malformed_lines"].as_u64().unwrap_or(0),
        report["coverage"].as_f64().unwrap_or(0.0),
        report["linkage"].as_f64().unwrap_or(0.0),
        report["unknown_rate"].as_f64().unwrap_or(0.0),
    )
}

pub(crate) fn apply_participation_health_scope(
    config: &mut LeaderParticipationCanaryConfig,
    health_scope: Option<&str>,
    log_path: Option<&Path>,
    pending_turn_id: Option<&str>,
) {
    if health_scope == Some("execution_host") {
        config.healthy = log_path
            .map(|path| leader_participation_health(path, &config.project_id, pending_turn_id))
            .is_some_and(|health| health.passes_promotion_gate());
    }
}

pub(crate) fn iso8601_day_number(timestamp: &str) -> Option<i64> {
    let bytes = timestamp.as_bytes();
    if bytes.len() != 20
        || bytes.get(4) != Some(&b'-')
        || bytes.get(7) != Some(&b'-')
        || bytes.get(10) != Some(&b'T')
        || bytes.get(13) != Some(&b':')
        || bytes.get(16) != Some(&b':')
        || bytes.get(19) != Some(&b'Z')
    {
        return None;
    }
    let date = timestamp.get(..10)?;
    let mut fields = date.split('-');
    let year = fields.next()?.parse::<i64>().ok()?;
    let month = fields.next()?.parse::<i64>().ok()?;
    let day = fields.next()?.parse::<i64>().ok()?;
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let days_in_month = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap => 29,
        2 => 28,
        _ => return None,
    };
    if fields.next().is_some() || !(1..=days_in_month).contains(&day) {
        return None;
    }
    let hour = timestamp.get(11..13)?.parse::<u8>().ok()?;
    let minute = timestamp.get(14..16)?.parse::<u8>().ok()?;
    let second = timestamp.get(17..19)?.parse::<u8>().ok()?;
    if hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    let adjusted_year = year - i64::from(month <= 2);
    let era = adjusted_year.div_euclid(400);
    let year_of_era = adjusted_year - era * 400;
    let shifted_month = month + if month > 2 { -3 } else { 9 };
    let day_of_year = (153 * shifted_month + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    Some(era * 146_097 + day_of_era)
}

pub(crate) fn parse_bool_env(name: &str) -> bool {
    matches!(
        env::var(name).ok().as_deref().map(str::trim),
        Some("1" | "true" | "TRUE" | "yes" | "YES")
    )
}

pub(crate) fn stable_canary_bucket(project_id: &str, session_id: &str) -> u8 {
    project_id
        .bytes()
        .chain(std::iter::once(b'|'))
        .chain(session_id.bytes())
        .fold(0u32, |bucket, byte| {
            (bucket.wrapping_mul(31) + u32::from(byte)) % 100
        }) as u8
}

pub(crate) fn resolve_participation(
    config: &LeaderParticipationCanaryConfig,
    known_input: bool,
) -> LeaderParticipationResolution {
    // The overlap canary remains a separate safety diagnostic. Mandatory
    // delegated guidance does not read any rollout field below.
    let delegated_overlap_resolution = config.mode == "canary"
        && config.delegated_overlap_resolution
        && config.delegation_effective.as_deref() == Some("delegated")
        && config.supported
        && config.healthy
        && !config.kill_switch;
    if config.delegation_effective.as_deref() == Some("delegated") && known_input {
        let (mode, cohort) = match config.mode.as_str() {
            "shadow" => ("shadow", "shadow"),
            "canary" if config.percent == 0 => ("canary", "holdout"),
            "canary"
                if !config.project_id.trim().is_empty()
                    && !config.session_id.trim().is_empty()
                    && stable_canary_bucket(&config.project_id, &config.session_id)
                        < config.percent =>
            {
                ("canary", "canary")
            }
            "canary" => ("canary", "holdout"),
            _ => ("off", "static"),
        };
        return LeaderParticipationResolution {
            mode,
            cohort,
            applied: true,
            delegated_overlap_resolution,
        };
    }
    if config.mode == "shadow" {
        return LeaderParticipationResolution {
            mode: "shadow",
            cohort: "shadow",
            applied: false,
            delegated_overlap_resolution,
        };
    }
    if config.mode != "canary"
        || config.kill_switch
        || !config.supported
        || !config.healthy
        || !config.opt_in
        || !known_input
    {
        return LeaderParticipationResolution {
            mode: "off",
            cohort: "static",
            applied: false,
            delegated_overlap_resolution,
        };
    }
    if config.percent == 0 {
        return LeaderParticipationResolution {
            mode: "canary",
            cohort: "holdout",
            applied: false,
            delegated_overlap_resolution,
        };
    }
    if config.project_id.trim().is_empty() || config.session_id.trim().is_empty() {
        return LeaderParticipationResolution {
            mode: "off",
            cohort: "static",
            applied: false,
            delegated_overlap_resolution,
        };
    }
    if stable_canary_bucket(&config.project_id, &config.session_id) < config.percent {
        LeaderParticipationResolution {
            mode: "canary",
            cohort: "canary",
            applied: true,
            delegated_overlap_resolution,
        }
    } else {
        LeaderParticipationResolution {
            mode: "canary",
            cohort: "holdout",
            applied: false,
            delegated_overlap_resolution,
        }
    }
}

pub(crate) fn resolve_participation_from_env(
    known_input: bool,
    pending_turn_id: Option<&str>,
    control: Option<&LeaderParticipationControlSnapshot>,
    control_file_invalid: bool,
) -> LeaderParticipationResolution {
    if control_file_invalid {
        return LeaderParticipationResolution {
            mode: "off",
            cohort: "static",
            applied: false,
            delegated_overlap_resolution: false,
        };
    }
    let mut config = LeaderParticipationCanaryConfig {
        mode: env::var("TERMMESH_LEADER_PARTICIPATION_MODE")
            .unwrap_or_else(|_| "shadow".to_string())
            .trim()
            .to_ascii_lowercase(),
        percent: env::var("TERMMESH_LEADER_PARTICIPATION_PERCENT")
            .ok()
            .and_then(|value| value.trim().parse::<u16>().ok())
            .map(|value| value.min(100) as u8)
            .unwrap_or(0),
        kill_switch: parse_bool_env("TERMMESH_LEADER_PARTICIPATION_KILL_SWITCH"),
        supported: parse_bool_env("TERMMESH_LEADER_PARTICIPATION_SUPPORTED"),
        healthy: parse_bool_env("TERMMESH_LEADER_PARTICIPATION_HEALTHY"),
        opt_in: parse_bool_env("TERMMESH_LEADER_PARTICIPATION_OPT_IN"),
        project_id: env::var("TERMMESH_LEADER_PARTICIPATION_PROJECT_ID").unwrap_or_default(),
        session_id: env::var("TERMMESH_LEADER_PARTICIPATION_SESSION_ID").unwrap_or_default(),
        delegation_level: None,
        delegation_effective: None,
        max_parallel_workers: None,
        overlap_canary_capability: false,
        overlap_canary_capability_version: None,
        delegated_overlap_resolution: false,
        health_scope: None,
    };
    let mut health_scope = None;
    if let Some(control) = control {
        config.mode = control.mode.clone();
        config.percent = control.percent;
        config.kill_switch |= control.kill_switch;
        config.supported = control.supported;
        config.healthy = control.healthy;
        config.opt_in = control.opt_in;
        config.project_id = control.project_id.clone();
        config.session_id = control.session_id.clone();
        config.delegation_level = control.delegation_level.clone();
        config.delegation_effective = control.delegation_effective.clone();
        config.max_parallel_workers = control.max_parallel_workers;
        config.overlap_canary_capability = control.overlap_canary_capability;
        config.overlap_canary_capability_version = control.overlap_canary_capability_version;
        config.delegated_overlap_resolution = control.delegated_overlap_resolution;
    }
    if let Some(control) = control {
        health_scope = control.health_scope.clone();
    }
    let log_path = turn_log_path().ok();
    apply_participation_health_scope(
        &mut config,
        health_scope.as_deref(),
        log_path.as_deref(),
        pending_turn_id,
    );
    resolve_participation(&config, known_input)
}

pub(crate) fn turn_route_record_with_policy_input(
    turn_id: &str,
    route: &str,
    task_shape: Option<&str>,
    available_workers: Option<u32>,
    risk_reasons: &[String],
    wave_id: Option<&str>,
    team: &str,
    surface_id: Option<&str>,
    ts: &str,
    control: Option<&LeaderParticipationControlSnapshot>,
    control_file_invalid: bool,
) -> Value {
    let mut record = json!({
        "event": "turn_route",
        "turn_id": turn_id,
        "ts": ts,
        "route": route,
        // The end hook uses the matching marker below to make omission
        // observable. Keep the route record self-describing too, so a reader
        // that only has rotated history never has to infer that this was a
        // leader-stated classification.
        "route_status": "stated",
        "policy_version": "1",
        "actual_route": route,
        "team": team,
    });
    if let Some(shape) = task_shape.filter(|v| !v.trim().is_empty()) {
        record["task_shape"] = json!(shape);
    }
    let reasons: Vec<&String> = risk_reasons
        .iter()
        .filter(|r| !r.trim().is_empty())
        .collect();
    if !reasons.is_empty() {
        record["risk_reasons"] = json!(reasons);
    }
    if let Some(wave) = wave_id.filter(|v| !v.trim().is_empty()) {
        record["wave_id"] = json!(wave);
    }
    if let Some(surface) = surface_id.filter(|v| !v.trim().is_empty()) {
        record["surface_id"] = json!(surface);
    }
    let suggestion = LeaderParticipationDirective::from_input(
        task_shape,
        risk_reasons,
        available_workers,
        control.and_then(|snapshot| snapshot.delegation_effective.as_deref()),
        control.and_then(|snapshot| snapshot.max_parallel_workers),
    );
    let resolution = resolve_participation_from_env(
        available_workers.is_some_and(|workers| workers > 0),
        Some(turn_id),
        control,
        control_file_invalid,
    );
    record["suggested_participation"] = json!(suggestion.participation);
    record["suggested_route"] = json!(suggestion.route);
    record["policy_reasons"] = json!(suggestion.reasons);
    record["dispatch_bounds"] = json!(suggestion.dispatch_bounds);
    record["policy_mode"] = json!(resolution.mode);
    record["policy_applied"] = json!(resolution.applied);
    record["cohort"] = json!(resolution.cohort);
    record["delegated_overlap_resolution"] = json!(resolution.delegated_overlap_resolution);
    if let Some(snapshot) = control {
        if let Some(version) = snapshot.leader_policy_version {
            record["leader_policy_version"] = json!(version);
        }
        if let Some(digest) = snapshot.leader_policy_digest.as_deref() {
            record["leader_policy_digest"] = json!(digest);
        }
    }
    record
}

#[cfg(test)]
pub(crate) fn turn_route_record(
    turn_id: &str,
    route: &str,
    task_shape: Option<&str>,
    risk_reasons: &[String],
    wave_id: Option<&str>,
    team: &str,
    surface_id: Option<&str>,
    ts: &str,
) -> Value {
    turn_route_record_with_policy_input(
        turn_id,
        route,
        task_shape,
        None,
        risk_reasons,
        wave_id,
        team,
        surface_id,
        ts,
        None,
        false,
    )
}

/// Append one record as a single line.
///
/// One `write_all` of a fully-built line, never read-modify-write: the harness
/// hook appends to this same file concurrently, and a read-then-write would
/// drop whichever record landed in between.
///
/// The file is opened per record and the descriptor is never cached across
/// calls. That is a correctness requirement, not a style choice: `rotate_log`
/// (`term-meshd/src/gc.rs`) unlinks any prior `turns.log.1` and then renames
/// `turns.log` onto it, and the sweep that calls it runs unattended at daemon
/// startup and every six hours. A descriptor held across a rotation keeps
/// writing into an inode that the NEXT rotation's `remove_file` deletes, so
/// those records are lost with no error at the write site. Re-opening the path
/// each time means a rotation costs at most nothing — the path is simply
/// recreated by `create(true)` on the following append.
pub(crate) fn append_turn_record(path: &Path, record: &Value) -> Result<(), String> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| format!("mkdir {}: {e}", dir.display()))?;
    }
    let mut line =
        serde_json::to_string(record).map_err(|e| format!("serialize turn record: {e}"))?;
    line.push('\n');
    // Owner-only: the sink stores prompt digests and byte counts, never content,
    // but a digest next to a short length is still guessable. Whichever writer
    // creates the file decides its mode, so every writer states 0600 rather than
    // inheriting umask (the Swift writer passes S_IRUSR|S_IWUSR, the shell hook
    // sets umask 077). Open-per-record, never a cached handle: term-meshd rotates
    // this file automatically, and a retained descriptor would keep appending to
    // the renamed inode that the next rotation unlinks.
    let mut options = fs::OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(path)
        .map_err(|e| format!("open {}: {e}", path.display()))?;
    file.write_all(line.as_bytes())
        .map_err(|e| format!("append {}: {e}", path.display()))
}

pub(crate) fn rcollect_record(team: &str, via: &str, payload: &Value) -> Value {
    let mut task_ids = Vec::new();
    for path in ["/result/task/id", "/result/task_id"] {
        if let Some(id) = payload.pointer(path).and_then(Value::as_str) {
            task_ids.push(id.to_string());
        }
    }
    for path in ["/result/tasks", "/result/items", "/result/results"] {
        if let Some(items) = payload.pointer(path).and_then(Value::as_array) {
            task_ids.extend(
                items
                    .iter()
                    .filter_map(|item| item["id"].as_str().map(str::to_owned)),
            );
        }
    }
    task_ids.sort();
    task_ids.dedup();
    let mut record = json!({"event":"task_collect","via":via,"task_ids":task_ids,"team":team,"ts":iso8601_utc_now()});
    if let Some(session) = current_leader_session_id() {
        record["leader_session_id"] = json!(session);
    }
    if let Some(turn_id) = turn_id_from_hook_state() {
        record["turn_id"] = json!(turn_id);
    }
    record
}

pub(crate) fn append_rcollect(team: &str, via: &str, payload: &Value) {
    if let Ok(path) = turn_log_path() {
        let _ = append_turn_record(&path, &rcollect_record(team, via, payload));
    }
}

/// `leader turn route` — record this turn's route and print what was written.
///
/// A missing team is an explicit error here, unlike the harness hook that
/// silently no-ops: the leader ran this command deliberately, so a record
/// filed against the wrong team (or against `live-team` by fallback) is worse
/// than no record. `--team` still satisfies this, so an adopted leader pane
/// that never had `TERMMESH_TEAM` injected can pass it explicitly.
///
/// `team` and `surface_id` are recorded as given and nothing more is derived
/// from them. In particular a record is NOT evidence that a leader wrote it:
/// `TERMMESH_TEAM` is injected into worker panes too, so inferring "this came
/// from the leader" from its presence would manufacture an identity claim the
/// data cannot support. Whoever ran the command is who ran it.
/// The turn id the harness hook most recently recorded for this surface.
///
/// The hook keeps `.turn-current-<surface>` as a stack, not a slot, because
/// queued input can start a second hook entry before the first turn ends. The
/// first line is the running turn; later entries are prompts absorbed into it.
/// Reading the oldest open entry
/// rather than inventing an id is what makes `turn_route` joinable to
/// `turn_start`; an invented value still counts, but joins nothing.
///
/// Best-effort by design: a missing file just means no hook ran (a non-Claude
/// leader, or a session started before the hook was wired), and that is a
/// legitimate state to record, not an error to fail on.
pub(crate) fn turn_id_from_hook_state() -> Option<String> {
    let surface = env::var("TERMMESH_SURFACE_ID").ok()?;
    let key: String = surface
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '_' || *c == '-')
        .collect();
    if key.is_empty() {
        return None;
    }
    let path = turn_log_path()
        .ok()?
        .with_file_name(format!(".turn-current-{key}"));
    let contents = fs::read_to_string(path).ok()?;
    contents
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(str::to_string)
}

/// A per-turn marker lets the independent Stop hook distinguish "a route was
/// stated" from "no route command ran" without parsing a concurrently
/// appended, rotation-prone log. It is deliberately ephemeral and is removed
/// by the hook after emitting turn_end.
/// Whether a stated route records a reason for dispatching nothing. The Stop
/// hook honours only this, not the bare marker: any route would otherwise end
/// a delegated turn without a dispatch or a reason.
pub(crate) fn no_dispatch_exemption(route: &str, no_dispatch_reason: Option<&str>) -> bool {
    route.trim() == "direct" && no_dispatch_reason.is_some_and(|reason| !reason.trim().is_empty())
}

pub(crate) fn mark_turn_route_stated(
    path: &Path,
    turn_id: &str,
    no_dispatch: bool,
) -> Result<(), String> {
    let key: String = turn_id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '_' || *c == '-')
        .collect();
    if key.is_empty() {
        return Err("turn id contains no safe marker characters".to_string());
    }
    let marker = path.with_file_name(format!(".turn-route-{key}"));
    let contents: &[u8] = if no_dispatch {
        b"stated\nno_dispatch\n"
    } else {
        b"stated\n"
    };
    fs::write(&marker, contents).map_err(|e| format!("write {}: {e}", marker.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Err(e) = fs::set_permissions(&marker, fs::Permissions::from_mode(0o600)) {
            // The route command fails here without a record, so a marker left
            // behind would let Stop read a route (or an exemption) never logged.
            let _ = fs::remove_file(&marker);
            return Err(format!("chmod {}: {e}", marker.display()));
        }
    }
    Ok(())
}

pub(crate) fn turn_route_marker_path(path: &Path, turn_id: &str) -> Option<PathBuf> {
    let key: String = turn_id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '_' || *c == '-')
        .collect();
    (!key.is_empty()).then(|| path.with_file_name(format!(".turn-route-{key}")))
}

/// Bounds the one `team.status` read `leader turn route` makes for an omitted
/// `--checkout-mode`. The record is written whether or not it answers.
pub(crate) const ROUTE_TOPOLOGY_RPC_TIMEOUT: Duration = Duration::from_secs(2);

/// Facts `leader turn route` filled in itself because the leader omitted the
/// flag. Only facts the app already recorded qualify: ownership, lane, overlap
/// and integration flags are claims about the leader's plan and are never
/// derived.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct DerivedRouteEvidence {
    checkout_mode: Option<String>,
    available_workers: Option<u32>,
    derived: Vec<&'static str>,
}

pub(crate) fn derive_route_evidence(
    explicit_checkout_mode: Option<&str>,
    explicit_available_workers: Option<u32>,
    control_available_workers: impl FnOnce() -> Option<u32>,
    team_checkout_mode: impl FnOnce() -> Option<String>,
) -> DerivedRouteEvidence {
    let mut evidence = DerivedRouteEvidence::default();
    evidence.checkout_mode = match explicit_checkout_mode {
        Some(mode) => Some(mode.to_string()),
        None => team_checkout_mode().map(|mode| {
            evidence.derived.push("checkout_mode");
            mode
        }),
    };
    evidence.available_workers = match explicit_available_workers {
        Some(workers) => Some(workers),
        None => control_available_workers().map(|workers| {
            evidence.derived.push("available_workers");
            workers
        }),
    };
    evidence
}

/// The layout the app briefs workers with as `TEAM_CHECKOUT_MODE`. "unknown"
/// is the app saying nobody recorded one, so it stays absent.
pub(crate) fn checkout_mode_from_team_status(result: &Value, team: &str) -> Option<String> {
    if result["team_name"].as_str() != Some(team) {
        return None;
    }
    result["checkout_mode"]
        .as_str()
        .map(str::trim)
        .filter(|mode| matches!(*mode, "isolated" | "shared" | "off"))
        .map(str::to_string)
}

pub(crate) fn route_team_checkout_mode(team: &str) -> Option<String> {
    // A remote leader's local socket belongs to another app than the Project's.
    if remote_leader_route().is_some() {
        return None;
    }
    let sock = detect_socket()?;
    let response = rpc_call_timeout_duration(
        &sock,
        "team.status",
        json!({ "team_name": team }),
        ROUTE_TOPOLOGY_RPC_TIMEOUT,
    )
    .ok()?;
    checkout_mode_from_team_status(&response["result"], team)
}

pub(crate) fn available_workers_from_control(value: &Value) -> Option<u32> {
    value["available_workers"]
        .as_u64()
        .map(|workers| workers.min(u64::from(u32::MAX)) as u32)
}

/// Called only after the same file passed the project and session check in
/// `read_leader_control_snapshot`, which does not keep this field.
pub(crate) fn control_file_available_workers() -> Option<u32> {
    let path = env::var("TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE").ok()?;
    let data = fs::read(Path::new(&path)).ok()?;
    if data.len() > LEADER_CONTROL_MAX_BYTES {
        return None;
    }
    available_workers_from_control(&serde_json::from_slice::<Value>(&data).ok()?)
}

pub(crate) fn run_leader_turn_route_with_evidence(
    team_resolution: &TeamNameResolution,
    turn_id: &str,
    route: &str,
    task_shape: Option<&str>,
    available_workers: Option<u32>,
    risk_reasons: &[String],
    wave_id: Option<&str>,
    checkout_mode: Option<&str>,
    ready_mutating_slices: Option<u32>,
    ownership_disjoint: bool,
    leader_lane_disjoint: bool,
    concurrent_write_overlap: Option<u32>,
    serial_integration: bool,
    resource_health: Option<&str>,
    no_dispatch_reason: Option<&str>,
) -> Result<Value, String> {
    if turn_id.trim().is_empty() {
        return Err("--turn-id must not be blank".to_string());
    }
    if route.trim().is_empty() {
        return Err("--route must not be blank".to_string());
    }
    if team_resolution.source == TeamNameSource::LiveTeamFallback {
        return Err(
            "no team: pass --team <name> or set TERMMESH_TEAM. A turn record filed \
             against the live-team fallback would attribute the turn to the wrong Project."
                .to_string(),
        );
    }
    let path = turn_log_path()?;
    let expected_session_id = env::var("TERMMESH_LEADER_SESSION_ID")
        .ok()
        .filter(|value| !value.trim().is_empty());
    let control_state = match env::var("TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE") {
        Err(_) => LeaderParticipationControlState::NotRequested,
        Ok(control_path) if control_path.trim().is_empty() => {
            LeaderParticipationControlState::Invalid
        }
        Ok(control_path) => match expected_session_id.as_deref() {
            Some(session_id) => read_leader_control_snapshot(
                Path::new(&control_path),
                &team_resolution.name,
                session_id,
            )
            .map(LeaderParticipationControlState::Valid)
            .unwrap_or(LeaderParticipationControlState::Invalid),
            None => LeaderParticipationControlState::Invalid,
        },
    };
    let control = control_state.snapshot();
    let derived = derive_route_evidence(
        checkout_mode,
        available_workers,
        || control.and_then(|_| control_file_available_workers()),
        || route_team_checkout_mode(&team_resolution.name),
    );
    let mut record = turn_route_record_with_policy_input(
        turn_id,
        route,
        task_shape,
        available_workers,
        risk_reasons,
        wave_id,
        &team_resolution.name,
        env::var("TERMMESH_SURFACE_ID").ok().as_deref(),
        &iso8601_utc_now(),
        control,
        control_state.is_invalid(),
    );
    let resolution = resolve_participation_from_env(
        available_workers.is_some_and(|workers| workers > 0),
        Some(turn_id),
        control,
        control_state.is_invalid(),
    );
    let effective_delegation = control
        .as_ref()
        .and_then(|snapshot| snapshot.delegation_effective.clone());
    let overlap_capability = control
        .as_ref()
        .is_some_and(|snapshot| snapshot.overlap_canary_capability());
    let admission = if available_workers.is_some_and(|workers| workers > 0) {
        OverlapCanaryAdmission::evaluate(
            resolution.delegated_overlap_resolution,
            overlap_capability,
            effective_delegation.as_deref(),
            route,
            record.get("suggested_route").and_then(Value::as_str),
            checkout_mode,
            ready_mutating_slices,
            ownership_disjoint,
            leader_lane_disjoint,
            concurrent_write_overlap,
            serial_integration,
            resource_health,
        )
    } else {
        OverlapCanaryAdmission {
            eligible: false,
            reasons: vec!["no_available_workers"],
        }
    };
    record["overlap_canary"] = json!(admission.eligible);
    record["overlap_canary_reasons"] = json!(admission.reasons);
    record["overlap_canary_evidence"] = json!({
        "capability": overlap_capability,
        "capability_version": OVERLAP_CANARY_CAPABILITY_VERSION,
        "delegated_overlap_resolution": resolution.delegated_overlap_resolution,
        "effective_delegation": effective_delegation,
        "checkout_mode": checkout_mode,
        "ready_mutating_slices": ready_mutating_slices,
        "ownership_disjoint": ownership_disjoint,
        "leader_lane_disjoint": leader_lane_disjoint,
        "concurrent_write_overlap": concurrent_write_overlap,
        "serial_integration": serial_integration,
        "resource_health": resource_health,
    });
    record["derived_evidence"] = json!(derived.derived);
    if let Some(mode) = derived.checkout_mode.filter(|_| checkout_mode.is_none()) {
        record["derived_checkout_mode"] = json!(mode);
    }
    if let Some(workers) = derived
        .available_workers
        .filter(|_| available_workers.is_none())
    {
        record["derived_available_workers"] = json!(workers);
    }
    if let Some(route) = remote_leader_route() {
        record["team_uuid"] = json!(route.team_uuid);
    }
    if let Some(session) = control
        .map(|snapshot| snapshot.session_id.as_str())
        .or(expected_session_id.as_deref())
    {
        record["leader_session_id"] = json!(session);
    }
    if let Some(reason) = no_dispatch_reason.filter(|reason| !reason.trim().is_empty()) {
        record["no_dispatch_reason"] = json!(reason.trim());
    }
    mark_turn_route_stated(
        &path,
        turn_id,
        no_dispatch_exemption(route, no_dispatch_reason),
    )?;
    // The marker and the log line are a small two-phase local transaction. A
    // failed append must not let Stop report a route that never reached the
    // durable measurement stream.
    if let Err(error) = append_turn_record(&path, &record) {
        if let Some(marker) = turn_route_marker_path(&path, turn_id) {
            let _ = fs::remove_file(marker);
        }
        return Err(error);
    }
    let directive = (record["policy_applied"].as_bool().unwrap_or(false) || admission.eligible)
        .then(|| {
            let mut directive = json!({
                "participation": record["suggested_participation"],
                "route": record["suggested_route"],
                "dispatch_bounds": record["dispatch_bounds"],
                "overlap_canary": record["overlap_canary"],
                "requires_isolated_checkout": true,
                "requires_ownership_disjoint": true,
                "requires_zero_write_overlap": true,
                "requires_serial_integration": true,
                "leader_lane_bounds": "coordination, integration, and verification only; mutation requires a separately declared disjoint lane",
            });
            if admission.eligible {
                directive["execution"] = json!("overlap_canary");
                directive["leader_lane_bounds"] =
                    json!("one disjoint leader mutation lane");
                directive["zero_write_overlap"] = json!(true);
                directive["serial_integration"] = json!(true);
            }
            directive
        });
    let route_deviation = match record.get("suggested_route").and_then(Value::as_str) {
        Some(suggested) if suggested != record["actual_route"] => Some(json!({
            "suggested": suggested,
            "stated": record["actual_route"],
        })),
        _ => None,
    };
    Ok(json!({
        "ok": true,
        "path": path.display().to_string(),
        "record": record,
        "directive": directive,
        "route_deviation": route_deviation,
    }))
}

#[cfg(test)]
pub(crate) fn run_leader_turn_route(
    team_resolution: &TeamNameResolution,
    turn_id: &str,
    route: &str,
    task_shape: Option<&str>,
    available_workers: Option<u32>,
    risk_reasons: &[String],
    wave_id: Option<&str>,
) -> Result<Value, String> {
    run_leader_turn_route_with_evidence(
        team_resolution,
        turn_id,
        route,
        task_shape,
        available_workers,
        risk_reasons,
        wave_id,
        None,
        None,
        false,
        false,
        None,
        false,
        None,
        None,
    )
}

#[cfg(test)]
mod leader_turn_record_tests {
    use super::*;

    fn reasons(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    fn canary_config(percent: u8) -> LeaderParticipationCanaryConfig {
        LeaderParticipationCanaryConfig {
            mode: "canary".to_string(),
            percent,
            kill_switch: false,
            supported: true,
            healthy: true,
            opt_in: true,
            project_id: "project-a".to_string(),
            session_id: "session-a".to_string(),
            delegation_level: Some("delegated".to_string()),
            max_parallel_workers: Some(3),
            delegation_effective: Some("delegated".to_string()),
            overlap_canary_capability: true,
            overlap_canary_capability_version: Some(OVERLAP_CANARY_CAPABILITY_VERSION),
            delegated_overlap_resolution: true,
            health_scope: Some("control_host".to_string()),
        }
    }

    #[test]
    fn evaluator_matches_observable_dispatch_contract() {
        let parallel = LeaderParticipationDirective::from_input(
            Some("multi_unit"),
            &[],
            Some(8),
            Some("delegated"),
            Some(5),
        );
        assert_eq!(parallel.participation, "coordinator");
        assert_eq!(parallel.route, "parallel");
        assert_eq!(parallel.reasons, ["delegated_max_capacity"]);
        assert_eq!(
            parallel.dispatch_bounds,
            "up to 5 useful dependency-ready, ownership-disjoint tasks; one if serial"
        );

        let risk = LeaderParticipationDirective::from_input(
            Some("multi_unit"),
            &reasons(&["release"]),
            Some(3),
            Some("delegated"),
            Some(10),
        );
        assert_eq!(risk.participation, "coordinator");
        assert_eq!(risk.route, "parallel");
        assert_eq!(risk.reasons, ["delegated_max_capacity"]);
        assert_eq!(
            risk.dispatch_bounds,
            "up to 3 useful dependency-ready, ownership-disjoint tasks; one if serial"
        );

        let unknown = LeaderParticipationDirective::from_input(
            Some("multi_unit"),
            &[],
            None,
            Some("delegated"),
            Some(10),
        );
        assert_eq!(unknown.participation, "hands_on");
        assert_eq!(unknown.route, "direct");
        assert_eq!(unknown.reasons, ["unsupported_input"]);

        let delegated = LeaderParticipationDirective::from_input(
            None,
            &[],
            Some(12),
            Some("delegated"),
            Some(7),
        );
        assert_eq!(delegated.route, "parallel");
        assert_eq!(delegated.reasons, ["delegated_max_capacity"]);
        assert_eq!(
            delegated.dispatch_bounds,
            "up to 7 useful dependency-ready, ownership-disjoint tasks; one if serial"
        );

        let serial = LeaderParticipationDirective::from_input(
            Some("single_unit"),
            &[],
            Some(12),
            Some("delegated"),
            Some(10),
        );
        assert_eq!(serial.route, "delegated");
        assert_eq!(serial.reasons, ["delegated_serial_work"]);
        assert_eq!(serial.dispatch_bounds, "exactly one implementation worker");

        let one_worker = LeaderParticipationDirective::from_input(
            Some("multi_unit"),
            &[],
            Some(1),
            Some("delegated"),
            Some(10),
        );
        assert_eq!(one_worker.route, "delegated");
        assert_eq!(one_worker.reasons, ["delegated_serial_work"]);
        assert_eq!(
            one_worker.dispatch_bounds,
            "exactly one implementation worker"
        );
    }

    #[test]
    fn overlap_canary_requires_every_positive_admission_fact() {
        let eligible = OverlapCanaryAdmission::evaluate(
            true,
            true,
            Some("delegated"),
            "parallel",
            Some("parallel"),
            Some("isolated"),
            Some(2),
            true,
            true,
            Some(0),
            true,
            Some("passed"),
        );
        assert!(
            eligible.eligible,
            "all positive evidence must admit overlap"
        );

        let cases: &[(
            &str,
            bool,
            bool,
            Option<&str>,
            &str,
            Option<&str>,
            Option<&str>,
            Option<u32>,
            bool,
            bool,
            Option<u32>,
            bool,
            Option<&str>,
        )] = &[
            (
                "resolution",
                false,
                true,
                Some("delegated"),
                "parallel",
                Some("parallel"),
                Some("isolated"),
                Some(2),
                true,
                true,
                Some(0),
                true,
                Some("passed"),
            ),
            (
                "capability",
                true,
                false,
                Some("delegated"),
                "parallel",
                Some("parallel"),
                Some("isolated"),
                Some(2),
                true,
                true,
                Some(0),
                true,
                Some("passed"),
            ),
            (
                "delegation",
                true,
                true,
                Some("guarded"),
                "parallel",
                Some("parallel"),
                Some("isolated"),
                Some(2),
                true,
                true,
                Some(0),
                true,
                Some("passed"),
            ),
            (
                "route",
                true,
                true,
                Some("delegated"),
                "direct",
                Some("parallel"),
                Some("isolated"),
                Some(2),
                true,
                true,
                Some(0),
                true,
                Some("passed"),
            ),
            (
                "suggested_route",
                true,
                true,
                Some("delegated"),
                "parallel",
                Some("direct"),
                Some("isolated"),
                Some(2),
                true,
                true,
                Some(0),
                true,
                Some("passed"),
            ),
            (
                "route_deviation",
                true,
                true,
                Some("delegated"),
                "parallel",
                Some("probe"),
                Some("isolated"),
                Some(2),
                true,
                true,
                Some(0),
                true,
                Some("passed"),
            ),
            (
                "checkout",
                true,
                true,
                Some("delegated"),
                "parallel",
                Some("parallel"),
                Some("shared"),
                Some(2),
                true,
                true,
                Some(0),
                true,
                Some("passed"),
            ),
            (
                "ready_units",
                true,
                true,
                Some("delegated"),
                "parallel",
                Some("parallel"),
                Some("isolated"),
                Some(1),
                true,
                true,
                Some(0),
                true,
                Some("passed"),
            ),
            (
                "ownership",
                true,
                true,
                Some("delegated"),
                "parallel",
                Some("parallel"),
                Some("isolated"),
                Some(2),
                false,
                true,
                Some(0),
                true,
                Some("passed"),
            ),
            (
                "leader_lane",
                true,
                true,
                Some("delegated"),
                "parallel",
                Some("parallel"),
                Some("isolated"),
                Some(2),
                true,
                false,
                Some(0),
                true,
                Some("passed"),
            ),
            (
                "write_overlap",
                true,
                true,
                Some("delegated"),
                "parallel",
                Some("parallel"),
                Some("isolated"),
                Some(2),
                true,
                true,
                Some(1),
                true,
                Some("passed"),
            ),
            (
                "integration",
                true,
                true,
                Some("delegated"),
                "parallel",
                Some("parallel"),
                Some("isolated"),
                Some(2),
                true,
                true,
                Some(0),
                false,
                Some("passed"),
            ),
            (
                "resources",
                true,
                true,
                Some("delegated"),
                "parallel",
                Some("parallel"),
                Some("isolated"),
                Some(2),
                true,
                true,
                Some(0),
                true,
                Some("failed"),
            ),
        ];
        for &(
            name,
            resolution,
            capability,
            delegation,
            route,
            suggested_route,
            checkout,
            ready,
            ownership,
            lane,
            overlap,
            serial,
            resources,
        ) in cases
        {
            let admission = OverlapCanaryAdmission::evaluate(
                resolution,
                capability,
                delegation,
                route,
                suggested_route,
                checkout,
                ready,
                ownership,
                lane,
                overlap,
                serial,
                resources,
            );
            assert!(!admission.eligible, "{name} must fail closed");
        }
    }

    fn control_snapshot_value() -> Value {
        // Overlap follows the mode, so a fixture meant to resolve overlap names
        // canary. `opt_in` stays false, which keeps the ordinary canary off and
        // the recorded policy_mode/cohort at off/static.
        json!({
            "schema_version": 1,
            "mode": "canary",
            "percent": 0,
            "kill_switch": false,
            "supported": true,
            "healthy": true,
            "opt_in": false,
            "project_id": "project-a",
            "session_id": "session-a",
            "delegation_configured": "delegated",
            "delegation_effective": "delegated",
            "max_parallel_workers": 99,
            "health_scope": "control_host",
            "overlap_canary_capability": true,
            "overlap_canary_capability_version": 1,
            "delegated_overlap_resolution": true,
        })
    }

    #[test]
    fn control_snapshot_validates_identity_schema_and_routing_fields() {
        let value = control_snapshot_value();
        let data = serde_json::to_vec(&value).expect("serialize control snapshot");
        let snapshot = parse_leader_control_snapshot(&data, "project-a", "session-a")
            .expect("valid control snapshot");
        assert_eq!(snapshot.delegation_level.as_deref(), Some("delegated"));
        assert_eq!(snapshot.max_parallel_workers, Some(10));
        assert_eq!(snapshot.leader_policy_version, None);
        assert_eq!(snapshot.leader_policy_digest, None);
        assert!(snapshot.overlap_canary_capability());
        assert!(snapshot.delegated_overlap_resolution);

        for (field, replacement) in [
            ("schema_version", json!(2)),
            ("project_id", json!("foreign-project")),
            ("session_id", json!("other-session")),
        ] {
            let mut invalid = value.clone();
            invalid[field] = replacement;
            let data = serde_json::to_vec(&invalid).expect("serialize invalid snapshot");
            assert!(
                parse_leader_control_snapshot(&data, "project-a", "session-a").is_none(),
                "{field} must fail closed"
            );
        }
    }

    #[test]
    fn leader_policy_identity_is_optional_in_control_snapshot_and_route_record() {
        let value = control_snapshot_value();
        let data = serde_json::to_vec(&value).expect("serialize control snapshot");
        let without_identity = parse_leader_control_snapshot(&data, "project-a", "session-a")
            .expect("valid control snapshot without policy identity");
        let absent = turn_route_record_with_policy_input(
            "turn-identity-absent",
            "direct",
            None,
            Some(1),
            &[],
            None,
            "project-a",
            None,
            "2026-08-24T09:15:00Z",
            Some(&without_identity),
            false,
        );
        assert!(absent.get("leader_policy_version").is_none());
        assert!(absent.get("leader_policy_digest").is_none());

        let mut value_with_identity = value;
        value_with_identity["leader_policy_version"] = json!(14);
        value_with_identity["leader_policy_digest"] = json!("digest-14");
        let data = serde_json::to_vec(&value_with_identity).expect("serialize control snapshot");
        let with_identity = parse_leader_control_snapshot(&data, "project-a", "session-a")
            .expect("valid control snapshot with policy identity");
        assert_eq!(with_identity.leader_policy_version, Some(14));
        assert_eq!(
            with_identity.leader_policy_digest.as_deref(),
            Some("digest-14")
        );

        let present = turn_route_record_with_policy_input(
            "turn-identity-present",
            "direct",
            None,
            Some(1),
            &[],
            None,
            "project-a",
            None,
            "2026-08-24T09:15:00Z",
            Some(&with_identity),
            false,
        );
        assert_eq!(present["leader_policy_version"], json!(14));
        assert_eq!(present["leader_policy_digest"], json!("digest-14"));
    }

    #[test]
    fn control_snapshot_requires_owner_only_regular_file() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("control.json");
        let data = serde_json::to_vec(&control_snapshot_value()).expect("serialize snapshot");
        fs::write(&path, data).expect("write snapshot");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).expect("set permissive mode");
        assert!(read_leader_control_snapshot(&path, "project-a", "session-a").is_none());

        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).expect("set owner-only mode");
        assert!(read_leader_control_snapshot(&path, "project-a", "session-a").is_some());
    }

    #[test]
    fn route_requires_a_nonblank_leader_session_before_using_control_snapshot() {
        let _env = ProcessEnvGuard::acquire();
        let dir = tempfile::tempdir().expect("tempdir");
        let home = dir.path().to_path_buf();
        fs::create_dir_all(home.join(".term-mesh").join("logs")).expect("create log directory");
        let control_path = home.join("control.json");
        let mut control = control_snapshot_value();
        control["project_id"] = json!("project-a");
        control["session_id"] = json!("session-a");
        control["available_workers"] = json!(2);
        fs::write(
            &control_path,
            serde_json::to_vec(&control).expect("serialize control"),
        )
        .expect("write control");
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&control_path, fs::Permissions::from_mode(0o600))
            .expect("set control mode");

        let keys = [
            "HOME",
            "TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE",
            "TERMMESH_LEADER_SESSION_ID",
            "TERMMESH_LEADER_PARTICIPATION_KILL_SWITCH",
            "TERMMESH_LEADER_PARTICIPATION_MODE",
            "TERMMESH_LEADER_PARTICIPATION_PERCENT",
            "TERMMESH_LEADER_PARTICIPATION_SUPPORTED",
            "TERMMESH_LEADER_PARTICIPATION_HEALTHY",
            "TERMMESH_LEADER_PARTICIPATION_OPT_IN",
            "TERMMESH_LEADER_PARTICIPATION_PROJECT_ID",
            "TERMMESH_LEADER_PARTICIPATION_SESSION_ID",
        ];
        let saved = keys
            .iter()
            .map(|key| (*key, env::var_os(key)))
            .collect::<Vec<_>>();
        for key in keys {
            env::remove_var(key);
        }
        env::set_var("HOME", &home);
        env::set_var("TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE", &control_path);
        env::set_var("TERMMESH_LEADER_PARTICIPATION_KILL_SWITCH", "false");

        let team = TeamNameResolution {
            name: "project-a".to_string(),
            source: TeamNameSource::Explicit,
        };
        for (session, expected_overlap) in [
            (Some("session-a"), true),
            (None, false),
            (Some("   "), false),
        ] {
            match session {
                Some(value) => env::set_var("TERMMESH_LEADER_SESSION_ID", value),
                None => env::remove_var("TERMMESH_LEADER_SESSION_ID"),
            }
            let result = run_leader_turn_route_with_evidence(
                &team,
                &format!("turn-session-{}", expected_overlap),
                "parallel",
                Some("multi_unit"),
                Some(3),
                &[],
                None,
                Some("isolated"),
                Some(2),
                true,
                true,
                Some(0),
                true,
                Some("passed"),
                None,
            )
            .expect("route evaluation");
            assert_eq!(result["record"]["overlap_canary"], expected_overlap);
            if expected_overlap {
                assert_eq!(result["directive"]["execution"], "overlap_canary");
                assert_eq!(result["directive"]["route"], "parallel");
                assert_eq!(result["directive"]["requires_isolated_checkout"], true);
                assert_eq!(result["directive"]["requires_ownership_disjoint"], true);
                assert_eq!(result["directive"]["requires_zero_write_overlap"], true);
                assert_eq!(result["directive"]["requires_serial_integration"], true);
            } else {
                assert!(result["directive"].is_null());
                assert_eq!(result["record"]["policy_mode"], "off");
                assert_eq!(result["record"]["cohort"], "static");
            }
        }

        env::set_var("TERMMESH_LEADER_SESSION_ID", "session-a");
        let derived_only = run_leader_turn_route_with_evidence(
            &team,
            "turn-derived-evidence-only",
            "parallel",
            Some("multi_unit"),
            None,
            &[],
            None,
            None,
            Some(2),
            true,
            true,
            Some(0),
            true,
            Some("passed"),
            None,
        )
        .expect("route evaluation");
        assert_eq!(derived_only["record"]["derived_available_workers"], 2);
        assert_eq!(derived_only["record"]["policy_applied"], false);
        assert!(derived_only["directive"].is_null());

        env::set_var("TERMMESH_LEADER_PARTICIPATION_MODE", "canary");
        env::set_var("TERMMESH_LEADER_PARTICIPATION_PERCENT", "100");
        env::set_var("TERMMESH_LEADER_PARTICIPATION_SUPPORTED", "true");
        env::set_var("TERMMESH_LEADER_PARTICIPATION_HEALTHY", "true");
        env::set_var("TERMMESH_LEADER_PARTICIPATION_OPT_IN", "true");
        fs::write(&control_path, b"not-json").expect("write invalid control");
        let invalid_configured = run_leader_turn_route_with_evidence(
            &team,
            "turn-invalid-configured-control",
            "parallel",
            Some("multi_unit"),
            Some(3),
            &[],
            None,
            Some("isolated"),
            Some(2),
            true,
            true,
            Some(0),
            true,
            Some("passed"),
            None,
        )
        .expect("route evaluation");
        assert_eq!(invalid_configured["record"]["policy_applied"], false);
        assert_eq!(invalid_configured["record"]["policy_mode"], "off");
        assert_eq!(invalid_configured["record"]["cohort"], "static");
        assert_eq!(invalid_configured["record"]["overlap_canary"], false);
        assert!(invalid_configured["directive"].is_null());

        env::set_var("TERMMESH_LEADER_PARTICIPATION_CONTROL_FILE", "   ");
        let blank_configured = run_leader_turn_route_with_evidence(
            &team,
            "turn-blank-configured-control",
            "parallel",
            Some("multi_unit"),
            Some(3),
            &[],
            None,
            Some("isolated"),
            Some(2),
            true,
            true,
            Some(0),
            true,
            Some("passed"),
            None,
        )
        .expect("route evaluation");
        assert_eq!(blank_configured["record"]["policy_applied"], false);
        assert_eq!(blank_configured["record"]["policy_mode"], "off");
        assert_eq!(blank_configured["record"]["cohort"], "static");
        assert_eq!(blank_configured["record"]["overlap_canary"], false);
        assert!(blank_configured["directive"].is_null());

        for (key, value) in saved {
            match value {
                Some(value) => env::set_var(key, value),
                None => env::remove_var(key),
            }
        }
    }

    #[test]
    fn mandatory_delegated_guidance_ignores_legacy_rollout_values() {
        let eligible = canary_config(100);
        assert_eq!(
            resolve_participation(&eligible, true),
            LeaderParticipationResolution {
                mode: "canary",
                cohort: "canary",
                applied: true,
                delegated_overlap_resolution: true,
            }
        );

        let mut cases = Vec::new();
        let mut unsupported = eligible.clone();
        unsupported.supported = false;
        cases.push(unsupported);
        let mut unhealthy = eligible.clone();
        unhealthy.healthy = false;
        cases.push(unhealthy);
        let mut no_opt_in = eligible.clone();
        no_opt_in.opt_in = false;
        cases.push(no_opt_in);
        let mut killed = eligible.clone();
        killed.kill_switch = true;
        cases.push(killed);
        for config in cases {
            assert!(
                resolve_participation(&config, true).applied,
                "config was {config:?}"
            );
        }
        assert!(!resolve_participation(&eligible, false).applied);

        let mut zero_workers = eligible.clone();
        zero_workers.delegation_effective = Some("delegated".to_string());
        assert!(resolve_participation(&zero_workers, false).applied == false);
    }

    /// Overlap ignores the cohort — opt-in and the percent bucket decide the
    /// ordinary canary, not this one — but it does follow the mode: a leader the
    /// user switched off, or left in shadow, is not running experiments.
    #[test]
    fn delegated_overlap_resolution_ignores_the_cohort_but_follows_the_mode() {
        let mut config = canary_config(0);
        config.opt_in = false;
        let resolution = resolve_participation(&config, true);
        assert!(resolution.applied);
        assert!(resolution.delegated_overlap_resolution);

        for mode in ["shadow", "off"] {
            let mut stopped = config.clone();
            stopped.mode = mode.to_string();
            assert!(
                !resolve_participation(&stopped, true).delegated_overlap_resolution,
                "mode {mode} kept overlap resolving"
            );
        }

        let cases: &[(&str, fn(&mut LeaderParticipationCanaryConfig))] = &[
            (
                "nondelegated",
                |config: &mut LeaderParticipationCanaryConfig| {
                    config.delegation_effective = Some("leaderFirst".to_string());
                },
            ),
            (
                "unsupported",
                |config: &mut LeaderParticipationCanaryConfig| {
                    config.supported = false;
                },
            ),
            (
                "unhealthy",
                |config: &mut LeaderParticipationCanaryConfig| {
                    config.healthy = false;
                },
            ),
            ("killed", |config: &mut LeaderParticipationCanaryConfig| {
                config.kill_switch = true;
            }),
            (
                "missing signal",
                |config: &mut LeaderParticipationCanaryConfig| {
                    config.delegated_overlap_resolution = false;
                },
            ),
        ];
        for (name, mutate) in cases {
            let mut boundary = config.clone();
            mutate(&mut boundary);
            assert!(
                !resolve_participation(&boundary, true).delegated_overlap_resolution,
                "{name} must fail closed"
            );
        }
    }

    fn linked_turn(turn_id: &str, timestamp: &str) -> String {
        [
            json!({"event": "turn_start", "turn_id": turn_id, "ts": timestamp, "team": "p"}),
            json!({"event": "turn_route", "turn_id": turn_id, "ts": timestamp, "team": "p"}),
            json!({"event": "turn_end", "turn_id": turn_id, "ts": timestamp, "team": "p"}),
        ]
        .into_iter()
        .map(|record| serde_json::to_string(&record).expect("serialize record"))
        .collect::<Vec<_>>()
        .join("\n")
            + "\n"
    }

    #[test]
    fn execution_host_health_passes_with_seven_days_of_linked_turns() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("turns.log");
        let records = linked_turn("first", "2026-08-18T23:59:00Z")
            + &linked_turn("last", "2026-08-24T00:01:00Z");
        fs::write(&path, records).expect("write turns");

        let health = leader_participation_health(&path, "p", None);
        assert_eq!(health.supported_turns, 2);
        assert_eq!(health.observed_days, 7);
        assert!(health.passes_promotion_gate(), "health was {health:?}");
    }

    #[test]
    fn execution_host_health_includes_rotated_generation() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("turns.log");
        fs::write(
            path.with_extension("log.1"),
            linked_turn("first", "2026-08-18T23:59:00Z"),
        )
        .expect("write rotated turns");
        fs::write(&path, linked_turn("last", "2026-08-24T00:01:00Z")).expect("write live turns");

        let health = leader_participation_health(&path, "p", None);
        assert_eq!(health.supported_turns, 2);
        assert!(health.passes_promotion_gate(), "health was {health:?}");
    }

    #[test]
    fn execution_host_health_fails_closed_for_malformed_or_torn_input() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("turns.log");
        let records = linked_turn("first", "2026-08-18T23:59:00Z")
            + &linked_turn("last", "2026-08-24T00:01:00Z")
            + "{not-json}\n"
            + "{\"event\":\"turn_start\"";
        fs::write(&path, records).expect("write turns");

        let health = leader_participation_health(&path, "p", None);
        assert_eq!(health.malformed_lines, 2);
        assert!(!health.passes_promotion_gate(), "health was {health:?}");
    }

    #[test]
    fn execution_host_health_skips_interleaved_non_turn_events() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("turns.log");
        let task_dispatch = serde_json::to_string(&json!({
            "event": "task_dispatch",
            "team": "p",
            "ts": "2026-08-20T00:00:00Z"
        }))
        .expect("serialize task_dispatch");
        let task_lifecycle = serde_json::to_string(&json!({
            "event": "task_lifecycle",
            "team": "p",
            "ts": "2026-08-21T00:00:00Z"
        }))
        .expect("serialize task_lifecycle");
        let records = linked_turn("first", "2026-08-18T23:59:00Z")
            + &task_dispatch
            + "\n"
            + &task_lifecycle
            + "\n"
            + &linked_turn("last", "2026-08-24T00:01:00Z");
        fs::write(&path, records).expect("write turns");

        let health = leader_participation_health(&path, "p", None);
        assert_eq!(health.malformed_lines, 0);
        assert_eq!(health.supported_turns, 2);
        assert!(health.passes_promotion_gate(), "health was {health:?}");
    }

    #[test]
    fn execution_host_health_flags_missing_or_non_string_event() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("turns.log");
        let missing_event = serde_json::to_string(&json!({
            "team": "p",
            "ts": "2026-08-20T00:00:00Z"
        }))
        .expect("serialize missing event");
        let numeric_event = serde_json::to_string(&json!({
            "event": 1,
            "team": "p",
            "ts": "2026-08-21T00:00:00Z"
        }))
        .expect("serialize numeric event");
        let records = linked_turn("first", "2026-08-18T23:59:00Z")
            + &missing_event
            + "\n"
            + &numeric_event
            + "\n"
            + &linked_turn("last", "2026-08-24T00:01:00Z");
        fs::write(&path, records).expect("write turns");

        let health = leader_participation_health(&path, "p", None);
        assert_eq!(health.malformed_lines, 2);
        assert!(!health.passes_promotion_gate(), "health was {health:?}");
    }

    #[test]
    fn execution_host_health_flags_turn_event_missing_required_field() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("turns.log");
        let missing_ts = serde_json::to_string(&json!({
            "event": "turn_start",
            "turn_id": "broken",
            "team": "p"
        }))
        .expect("serialize turn_start without ts");
        let records = linked_turn("first", "2026-08-18T23:59:00Z")
            + &missing_ts
            + "\n"
            + &linked_turn("last", "2026-08-24T00:01:00Z");
        fs::write(&path, records).expect("write turns");

        let health = leader_participation_health(&path, "p", None);
        assert_eq!(health.malformed_lines, 1);
        assert!(!health.passes_promotion_gate(), "health was {health:?}");
    }

    #[test]
    fn execution_host_health_is_scoped_to_the_project() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("turns.log");
        let other_team = linked_turn("first", "2026-08-18T23:59:00Z")
            .replace("\"team\":\"p\"", "\"team\":\"other\"")
            + &linked_turn("last", "2026-08-24T00:01:00Z")
                .replace("\"team\":\"p\"", "\"team\":\"other\"");
        fs::write(&path, other_team).expect("write turns");

        let health = leader_participation_health(&path, "p", None);
        assert_eq!(health.supported_turns, 0);
        assert!(!health.passes_promotion_gate());
    }

    /// A host runs many Projects through one turns.log. A damaged record that
    /// names another Project used to count here, which closed this Project's
    /// gate for as long as that line stayed in the file.
    #[test]
    fn execution_host_health_ignores_another_projects_damaged_turn() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("turns.log");
        let foreign_without_ts = serde_json::to_string(&json!({
            "event": "turn_start",
            "turn_id": "broken",
            "team": "other"
        }))
        .expect("serialize foreign turn_start without ts");
        let records = linked_turn("first", "2026-08-18T23:59:00Z")
            + &foreign_without_ts
            + "\n"
            + &linked_turn("last", "2026-08-24T00:01:00Z");
        fs::write(&path, records).expect("write turns");

        let health = leader_participation_health(&path, "p", None);
        assert_eq!(health.malformed_lines, 0);
        assert_eq!(health.supported_turns, 2);
        assert!(health.passes_promotion_gate(), "health was {health:?}");
    }

    #[test]
    fn execution_host_health_excludes_the_pending_route_turn() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("turns.log");
        let records = linked_turn("first", "2026-08-18T23:59:00Z")
            + &linked_turn("last", "2026-08-24T00:01:00Z")
            + &serde_json::to_string(&json!({
                "event": "turn_start",
                "turn_id": "pending",
                "ts": "2026-08-31T00:00:00Z",
                "team": "p"
            }))
            .expect("serialize pending")
            + "\n";
        fs::write(&path, records).expect("write turns");

        let health = leader_participation_health(&path, "p", Some("pending"));
        assert_eq!(health.supported_turns, 2);
        assert!(health.passes_promotion_gate(), "health was {health:?}");
    }

    #[test]
    fn execution_host_health_fails_closed_for_duplicate_turn_starts() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("turns.log");
        let duplicate_start = serde_json::to_string(&json!({
            "event": "turn_start",
            "turn_id": "first",
            "ts": "2026-08-18T23:59:00Z",
            "team": "p"
        }))
        .expect("serialize duplicate start");
        let records = linked_turn("first", "2026-08-18T23:59:00Z")
            + &duplicate_start
            + "\n"
            + &linked_turn("last", "2026-08-24T00:01:00Z");
        fs::write(&path, records).expect("write turns");

        let health = leader_participation_health(&path, "p", None);

        assert_eq!(health.supported_turns, 2);
        assert_eq!(health.malformed_lines, 1);
        assert!(!health.passes_promotion_gate(), "health was {health:?}");
    }

    #[test]
    fn execution_host_health_checks_duplicates_before_pending_exclusion() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("turns.log");
        let duplicate_start = serde_json::to_string(&json!({
            "event": "turn_start",
            "turn_id": "pending",
            "ts": "2026-08-24T00:00:00Z",
            "team": "p"
        }))
        .expect("serialize duplicate start");
        fs::write(
            &path,
            duplicate_start.clone() + "\n" + &duplicate_start + "\n",
        )
        .expect("write turns");

        let health = leader_participation_health(&path, "p", Some("pending"));

        assert_eq!(health.supported_turns, 0);
        assert_eq!(health.malformed_lines, 1);
        assert!(!health.passes_promotion_gate(), "health was {health:?}");
    }

    #[test]
    fn execution_host_scope_overrides_staged_owner_health() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("turns.log");
        fs::write(
            &path,
            linked_turn("first", "2026-08-18T23:59:00Z")
                + &linked_turn("last", "2026-08-24T00:01:00Z"),
        )
        .expect("write turns");
        let mut config = canary_config(100);
        config.project_id = "p".to_string();
        config.healthy = false;

        apply_participation_health_scope(&mut config, Some("execution_host"), Some(&path), None);

        assert!(config.healthy);
        assert!(resolve_participation(&config, true).applied);
    }

    #[test]
    fn execution_host_scope_fails_closed_when_local_log_is_missing() {
        let mut config = canary_config(100);
        config.healthy = true;

        apply_participation_health_scope(&mut config, Some("execution_host"), None, None);

        assert!(!config.healthy);
        assert!(resolve_participation(&config, true).applied);
        assert!(!resolve_participation(&config, true).delegated_overlap_resolution);
    }

    #[test]
    fn control_host_scope_preserves_staged_health() {
        let mut config = canary_config(100);
        config.healthy = true;

        apply_participation_health_scope(&mut config, Some("control_host"), None, None);

        assert!(config.healthy);
    }

    /// Safety net for peer leaders: an executionHost payload drops this Mac's aggregate
    /// health (config.delegated_overlap_resolution starts true), so the
    /// remote per-Project log is the only thing standing between a healthy
    /// signal and a resolved overlap. `resolve_participation` must still AND
    /// in `config.healthy`, whatever `apply_participation_health_scope`
    /// derived it to be.
    #[test]
    fn execution_host_scope_gates_delegated_overlap_resolution_on_the_remote_log() {
        let base = LeaderParticipationCanaryConfig {
            project_id: "p".to_string(),
            healthy: false,
            delegated_overlap_resolution: true,
            delegation_effective: Some("delegated".to_string()),
            supported: true,
            kill_switch: false,
            ..canary_config(100)
        };
        let dir = tempfile::tempdir().expect("tempdir");

        let passing_path = dir.path().join("passing.log");
        fs::write(
            &passing_path,
            linked_turn("first", "2026-08-18T23:59:00Z")
                + &linked_turn("last", "2026-08-24T00:01:00Z"),
        )
        .expect("write passing turns");
        let mut passing = base.clone();
        apply_participation_health_scope(
            &mut passing,
            Some("execution_host"),
            Some(&passing_path),
            None,
        );
        assert!(resolve_participation(&passing, true).delegated_overlap_resolution);

        let malformed_path = dir.path().join("malformed.log");
        fs::write(&malformed_path, "{not-json}\n").expect("write malformed turns");
        let mut malformed = base.clone();
        apply_participation_health_scope(
            &mut malformed,
            Some("execution_host"),
            Some(&malformed_path),
            None,
        );
        assert!(!resolve_participation(&malformed, true).delegated_overlap_resolution);

        let mut missing = base.clone();
        apply_participation_health_scope(&mut missing, Some("execution_host"), None, None);
        assert!(!resolve_participation(&missing, true).delegated_overlap_resolution);
    }

    #[test]
    fn leader_turn_health_report_matches_the_gate_on_the_seven_day_fixture() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("turns.log");
        let records = linked_turn("first", "2026-08-18T23:59:00Z")
            + &linked_turn("last", "2026-08-24T00:01:00Z");
        fs::write(&path, records).expect("write turns");

        let health = leader_participation_health(&path, "p", None);
        let report = leader_turn_health_report(&path, "p");

        assert_eq!(report["schema_version"], json!(1));
        assert_eq!(report["project"], json!("p"));
        assert_eq!(report["scope"], json!("execution_host_project"));
        assert_eq!(report["supported_turns"], json!(health.supported_turns));
        assert_eq!(report["linked_turns"], json!(health.linked_turns));
        assert_eq!(report["stated_turns"], json!(health.stated_turns));
        assert_eq!(report["unstated_turns"], json!(health.unstated_turns));
        assert_eq!(report["observed_days"], json!(health.observed_days));
        assert_eq!(report["malformed_lines"], json!(health.malformed_lines));
        assert_eq!(
            report["passes_promotion_gate"],
            json!(health.passes_promotion_gate())
        );
        assert_eq!(report["passes_promotion_gate"], json!(true));
    }

    #[test]
    fn leader_turn_health_report_flags_malformed_and_torn_input() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("turns.log");
        let records = linked_turn("first", "2026-08-18T23:59:00Z")
            + &linked_turn("last", "2026-08-24T00:01:00Z")
            + "{not-json}\n"
            + "{\"event\":\"turn_start\"";
        fs::write(&path, records).expect("write turns");

        let report = leader_turn_health_report(&path, "p");

        assert_eq!(report["malformed_lines"], json!(2));
        assert_eq!(report["passes_promotion_gate"], json!(false));
    }

    #[test]
    fn leader_turn_health_report_is_scoped_to_the_project() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("turns.log");
        let other_team = linked_turn("first", "2026-08-18T23:59:00Z")
            .replace("\"team\":\"p\"", "\"team\":\"other\"")
            + &linked_turn("last", "2026-08-24T00:01:00Z")
                .replace("\"team\":\"p\"", "\"team\":\"other\"");
        fs::write(&path, other_team).expect("write turns");

        let report = leader_turn_health_report(&path, "p");

        assert_eq!(report["supported_turns"], json!(0));
        assert_eq!(report["passes_promotion_gate"], json!(false));
    }

    #[test]
    fn leader_turn_health_report_is_zero_for_an_empty_or_missing_log() {
        let dir = tempfile::tempdir().expect("tempdir");
        let empty_path = dir.path().join("empty.log");
        fs::write(&empty_path, "").expect("write empty turns");
        let missing_path = dir.path().join("missing.log");

        for path in [&empty_path, &missing_path] {
            let report = leader_turn_health_report(path, "p");
            assert_eq!(report["supported_turns"], json!(0));
            assert_eq!(report["linked_turns"], json!(0));
            assert_eq!(report["stated_turns"], json!(0));
            assert_eq!(report["unstated_turns"], json!(0));
            assert_eq!(report["coverage"], json!(0.0));
            assert_eq!(report["linkage"], json!(0.0));
            assert_eq!(report["unknown_rate"], json!(1.0));
            assert_eq!(report["passes_promotion_gate"], json!(false));
        }
    }

    #[test]
    fn leader_turn_health_cli_requires_project() {
        let parsed = Cli::try_parse_from([
            "tm-agent",
            "leader",
            "turn",
            "health",
            "--project",
            "p",
            "--json",
        ])
        .unwrap();
        assert!(matches!(
            parsed.command,
            Commands::Leader(LeaderCommands::Turn(LeaderTurnCommands::Health { .. }))
        ));

        let missing_project =
            Cli::try_parse_from(["tm-agent", "leader", "turn", "health", "--json"]);
        assert!(missing_project.is_err());
    }

    #[test]
    fn zero_percentage_and_deterministic_holdout_still_apply_mandatory_guidance() {
        let zero = resolve_participation(&canary_config(0), true);
        assert_eq!(zero.cohort, "holdout");
        assert!(zero.applied);

        let mut holdout = canary_config(1);
        for index in 0..1000 {
            holdout.session_id = format!("session-{index}");
            if stable_canary_bucket(&holdout.project_id, &holdout.session_id) >= holdout.percent {
                break;
            }
        }
        let first = resolve_participation(&holdout, true);
        let second = resolve_participation(&holdout, true);
        assert_eq!(first, second);
        assert_eq!(first.cohort, "holdout");
        assert!(first.applied);
    }

    #[test]
    fn full_record_round_trips_every_stated_field() {
        let record = turn_route_record(
            "turn-42",
            "parallel",
            Some("multi_unit"),
            &reasons(&["cross_subsystem", "protocol_or_persistence"]),
            Some("wave-7"),
            "term-mesh",
            Some("surface-9"),
            "2026-08-24T09:15:00Z",
        );
        assert_eq!(record["event"], "turn_route");
        assert_eq!(record["turn_id"], "turn-42");
        assert_eq!(record["ts"], "2026-08-24T09:15:00Z");
        assert_eq!(record["route"], "parallel");
        assert_eq!(record["team"], "term-mesh");
        assert_eq!(record["task_shape"], "multi_unit");
        assert_eq!(
            record["risk_reasons"],
            json!(["cross_subsystem", "protocol_or_persistence"])
        );
        assert_eq!(record["wave_id"], "wave-7");
        assert_eq!(record["surface_id"], "surface-9");

        // Round-trips through the serialized line, not just the in-memory value:
        // the line on disk is what a later reader actually parses.
        let parsed: Value =
            serde_json::from_str(&serde_json::to_string(&record).expect("serialize"))
                .expect("parse");
        assert_eq!(parsed, record);
    }

    /// The delegate-side equivalent of this is
    /// `delegate_params_omit_unstated_measurement_fields`: absence is what "the
    /// leader did not state this" looks like, and a `null` would read as a value.
    #[test]
    fn unstated_optional_fields_are_absent_not_null() {
        let record = turn_route_record(
            "turn-1",
            "direct",
            None,
            &[],
            None,
            "term-mesh",
            None,
            "2026-08-24T09:15:00Z",
        );
        assert!(record.get("task_shape").is_none());
        assert!(record.get("risk_reasons").is_none());
        assert!(record.get("wave_id").is_none());
        assert!(record.get("surface_id").is_none());

        // A blank flag value must not create an empty field that later reads as
        // a real one.
        let blank = turn_route_record(
            "turn-1",
            "direct",
            Some("   "),
            &reasons(&["", "  "]),
            Some(""),
            "term-mesh",
            Some("  "),
            "2026-08-24T09:15:00Z",
        );
        assert!(blank.get("task_shape").is_none());
        assert!(blank.get("risk_reasons").is_none());
        assert!(blank.get("wave_id").is_none());
        assert!(blank.get("surface_id").is_none());

        // The serialized line must not carry the keys either — an omitted key and
        // a key holding `null` look identical on the value side of some readers.
        let line = serde_json::to_string(&record).expect("serialize");
        assert!(!line.contains("task_shape"), "line was {line}");
        assert!(!line.contains("risk_reasons"), "line was {line}");
        assert!(!line.contains("wave_id"), "line was {line}");
        assert!(!line.contains("null"), "line was {line}");
    }

    /// Stance from 526649a1: rejecting an unrecognized route would drop exactly
    /// the anomalies worth seeing, so it is stored verbatim — not normalized,
    /// not lowercased, not mapped to a known value.
    #[test]
    fn unknown_route_is_stored_verbatim() {
        for stated in ["Parallel", "delegated", "probe-then-parallel", "🙂"] {
            let record = turn_route_record(
                "turn-x",
                stated,
                None,
                &[],
                None,
                "term-mesh",
                None,
                "2026-08-24T09:15:00Z",
            );
            assert_eq!(record["route"], stated);
        }
    }

    #[test]
    fn repeated_risk_reason_flags_collect_into_an_array() {
        let record = turn_route_record(
            "turn-3",
            "probe",
            None,
            &reasons(&["repeated_failure", "irreversible_or_release"]),
            None,
            "term-mesh",
            None,
            "2026-08-24T09:15:00Z",
        );
        let array = record["risk_reasons"]
            .as_array()
            .expect("risk_reasons is an array");
        assert_eq!(array.len(), 2);
        assert_eq!(array[0], "repeated_failure");
        assert_eq!(array[1], "irreversible_or_release");

        // A single occurrence is still an array, not a bare string: a reader that
        // has to handle both shapes will eventually handle one of them wrong.
        let single = turn_route_record(
            "turn-4",
            "probe",
            None,
            &reasons(&["repeated_failure"]),
            None,
            "term-mesh",
            None,
            "2026-08-24T09:15:00Z",
        );
        assert_eq!(single["risk_reasons"], json!(["repeated_failure"]));
    }

    #[test]
    fn appended_line_ends_with_exactly_one_newline() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("logs").join("turns.log");
        let record = turn_route_record(
            "turn-5",
            "direct",
            None,
            &[],
            None,
            "term-mesh",
            None,
            "2026-08-24T09:15:00Z",
        );
        append_turn_record(&path, &record).expect("append");

        let body = fs::read_to_string(&path).expect("read");
        assert!(body.ends_with('\n'), "body was {body:?}");
        assert!(!body.ends_with("\n\n"), "body was {body:?}");
        // One record is one line: a record whose own body contained a newline
        // would silently become two rows for a line-oriented reader.
        assert_eq!(body.matches('\n').count(), 1, "body was {body:?}");
    }

    #[test]
    fn two_sequential_appends_produce_two_parseable_lines() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("logs").join("turns.log");
        for (turn, route) in [("turn-a", "direct"), ("turn-b", "parallel")] {
            let record = turn_route_record(
                turn,
                route,
                None,
                &[],
                None,
                "term-mesh",
                None,
                "2026-08-24T09:15:00Z",
            );
            append_turn_record(&path, &record).expect("append");
        }

        let body = fs::read_to_string(&path).expect("read");
        let lines: Vec<&str> = body.lines().collect();
        assert_eq!(lines.len(), 2, "body was {body:?}");
        let first: Value = serde_json::from_str(lines[0]).expect("parse first");
        let second: Value = serde_json::from_str(lines[1]).expect("parse second");
        assert_eq!(first["turn_id"], "turn-a");
        assert_eq!(first["route"], "direct");
        assert_eq!(second["turn_id"], "turn-b");
        assert_eq!(second["route"], "parallel");
        // The second append must not have truncated the first — the whole point
        // of append mode over write mode.
        assert_eq!(first["event"], "turn_route");
    }

    /// A leader ran this deliberately, so a record filed against the `live-team`
    /// fallback would attribute the turn to the wrong Project. The harness hook
    /// is the one allowed to no-op silently.
    #[test]
    fn missing_team_is_an_explicit_error() {
        let fallback = TeamNameResolution {
            name: "live-team".to_string(),
            source: TeamNameSource::LiveTeamFallback,
        };
        let err = run_leader_turn_route(&fallback, "turn-6", "direct", None, None, &[], None)
            .expect_err("live-team fallback must be rejected");
        assert!(err.contains("no team"), "error was {err}");

        // An explicit --team satisfies it, which is how an adopted leader pane
        // with no TERMMESH_TEAM still records.
        let explicit = TeamNameResolution {
            name: "term-mesh".to_string(),
            source: TeamNameSource::Explicit,
        };
        let blank_turn = run_leader_turn_route(&explicit, "  ", "direct", None, None, &[], None)
            .expect_err("blank turn id must be rejected");
        assert!(blank_turn.contains("--turn-id"), "error was {blank_turn}");
        let blank_route = run_leader_turn_route(&explicit, "turn-7", "  ", None, None, &[], None)
            .expect_err("blank route must be rejected");
        assert!(blank_route.contains("--route"), "error was {blank_route}");
    }

    #[test]
    fn stated_route_marker_is_owner_only_and_uses_the_turn_id() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("logs").join("turns.log");
        fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
        mark_turn_route_stated(&path, "turn-42", false).expect("marker");
        let marker = path.with_file_name(".turn-route-turn-42");
        assert_eq!(
            fs::read_to_string(&marker).expect("read marker"),
            "stated\n"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(marker).expect("metadata").permissions().mode() & 0o777,
                0o600
            );
        }
    }

    /// Reproduces what `rotate_log` in `term-meshd/src/gc.rs` does to this file
    /// while the CLI is running: unlink any prior `.log.1`, then rename the live
    /// log onto it. The sweep doing this is unattended (daemon startup, then
    /// every six hours), so it WILL happen mid-measurement rather than only when
    /// somebody runs `gc sweep --apply`.
    ///
    /// A `File` cached across appends would keep writing into the renamed inode
    /// and lose every subsequent record with no error at the write site. Opening
    /// per record means the post-rotation append recreates the path instead.

    #[test]
    fn only_a_direct_route_with_a_reason_marks_the_no_dispatch_exemption() {
        assert!(no_dispatch_exemption(
            "direct",
            Some("question only; nothing to implement")
        ));
        assert!(!no_dispatch_exemption("direct", Some("   ")));
        assert!(!no_dispatch_exemption("direct", None));
        assert!(!no_dispatch_exemption("parallel", Some("a reason")));
        assert!(!no_dispatch_exemption("delegated", Some("a reason")));

        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("logs").join("turns.log");
        fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
        mark_turn_route_stated(&path, "turn-43", true).expect("marker");
        assert_eq!(
            fs::read_to_string(path.with_file_name(".turn-route-turn-43")).expect("read marker"),
            "stated\nno_dispatch\n"
        );
    }
    #[test]
    fn append_survives_a_rotation_between_records() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("logs").join("turns.log");
        let record = |turn: &str| {
            turn_route_record(
                turn,
                "direct",
                None,
                &[],
                None,
                "term-mesh",
                None,
                "2026-08-24T09:15:00Z",
            )
        };

        append_turn_record(&path, &record("before-rotation")).expect("first append");

        // Exactly what rotate_log does, including the unlink of a pre-existing
        // .log.1 — the step that makes a retained descriptor lose data on the
        // SECOND rotation rather than the first.
        let rotated = path.with_extension("log.1");
        let _ = fs::remove_file(&rotated);
        fs::rename(&path, &rotated).expect("rotate");
        assert!(!path.exists(), "rotation should leave the live path absent");

        append_turn_record(&path, &record("after-rotation")).expect("append after rotation");

        // The live path was recreated and holds only the post-rotation record.
        let live = fs::read_to_string(&path).expect("read live");
        let live_lines: Vec<&str> = live.lines().collect();
        assert_eq!(live_lines.len(), 1, "live log was {live:?}");
        let parsed: Value = serde_json::from_str(live_lines[0]).expect("parse live");
        assert_eq!(parsed["turn_id"], "after-rotation");

        // One generation of history survives, so a reader spanning a rotation
        // has to consult turns.log.1 as well.
        let history = fs::read_to_string(&rotated).expect("read rotated");
        let history_lines: Vec<&str> = history.lines().collect();
        assert_eq!(history_lines.len(), 1, "rotated log was {history:?}");
        let old: Value = serde_json::from_str(history_lines[0]).expect("parse rotated");
        assert_eq!(old["turn_id"], "before-rotation");
    }

    /// `TERMMESH_TEAM` is injected into worker panes too, so the record must not
    /// carry any claim about which actor produced it. The policy identity fields
    /// identify the policy snapshot, not the leader or worker actor.
    #[test]
    fn record_makes_no_leader_identity_claim() {
        let mut control_value = control_snapshot_value();
        control_value["leader_policy_version"] = json!(14);
        control_value["leader_policy_digest"] = json!("digest-14");
        let control_data = serde_json::to_vec(&control_value).expect("serialize control snapshot");
        let control = parse_leader_control_snapshot(&control_data, "project-a", "session-a")
            .expect("valid control snapshot");
        let record = turn_route_record_with_policy_input(
            "turn-8",
            "direct",
            Some("single_unit"),
            Some(1),
            &reasons(&["repeated_failure"]),
            Some("wave-1"),
            "project-a",
            Some("surface-3"),
            "2026-08-24T09:15:00Z",
            Some(&control),
            false,
        );
        let object = record.as_object().expect("record is an object");
        for forbidden in [
            "role",
            "agent",
            "agent_name",
            "is_leader",
            "leader",
            "actor",
        ] {
            assert!(
                !object.contains_key(forbidden),
                "record must not assert identity via {forbidden}: {record}"
            );
        }
        // The full key set is closed — a new field is a deliberate decision, not
        // something that arrives by accident.
        let mut keys: Vec<&str> = object.keys().map(|k| k.as_str()).collect();
        keys.sort_unstable();
        assert_eq!(
            keys,
            [
                "actual_route",
                "cohort",
                "delegated_overlap_resolution",
                "dispatch_bounds",
                "event",
                "leader_policy_digest",
                "leader_policy_version",
                "policy_applied",
                "policy_mode",
                "policy_reasons",
                "policy_version",
                "risk_reasons",
                "route",
                "route_status",
                "suggested_participation",
                "suggested_route",
                "surface_id",
                "task_shape",
                "team",
                "ts",
                "turn_id",
                "wave_id",
            ]
        );
    }

    /// The `.log` extension is load-bearing: `scan_logs` in
    /// `term-meshd/src/gc.rs` skips every file whose extension is not exactly
    /// `log`, so a `.jsonl` sink would never be offered for rotation.
    #[test]
    fn sink_is_a_dot_log_file_under_the_term_mesh_logs_dir() {
        let _env = ProcessEnvGuard::acquire();
        let path = turn_log_path().expect("HOME is set in the test environment");
        assert_eq!(path.extension().and_then(|e| e.to_str()), Some("log"));
        assert_eq!(path.file_name().and_then(|f| f.to_str()), Some("turns.log"));
        assert!(
            path.ends_with(".term-mesh/logs/turns.log"),
            "path was {}",
            path.display()
        );
    }

    /// A route record must be joinable to the `turn_start` the harness hook
    /// wrote. The hook keeps the id in a per-surface stack whose first line is
    /// the turn already running; later lines are prompts absorbed into it.
    #[test]
    fn omitted_turn_id_comes_from_the_first_line_of_the_hook_state_stack() {
        let _env = ProcessEnvGuard::acquire();
        let home = std::env::temp_dir().join(format!("tm-turnid-{}", std::process::id()));
        let logs = home.join(".term-mesh/logs");
        fs::create_dir_all(&logs).expect("create temp logs dir");
        fs::write(logs.join(".turn-current-surf-1"), "outer\ninner\n").expect("write stack");

        let prev_home = env::var("HOME").ok();
        let prev_surface = env::var("TERMMESH_SURFACE_ID").ok();
        env::set_var("HOME", &home);
        env::set_var("TERMMESH_SURFACE_ID", "surf-1");

        let resolved = turn_id_from_hook_state();

        // A surface with no state file is a legitimate state (no hook wired),
        // not an error: it must read as absent so the caller can fall back.
        env::set_var("TERMMESH_SURFACE_ID", "surf-absent");
        let missing = turn_id_from_hook_state();

        match prev_home {
            Some(v) => env::set_var("HOME", v),
            None => env::remove_var("HOME"),
        }
        match prev_surface {
            Some(v) => env::set_var("TERMMESH_SURFACE_ID", v),
            None => env::remove_var("TERMMESH_SURFACE_ID"),
        }
        let _ = fs::remove_dir_all(&home);

        assert_eq!(resolved.as_deref(), Some("outer"));
        assert_eq!(missing, None);
    }

    /// The sink stores digests and byte counts, never content, but a digest next
    /// to a short length is guessable — so the file must not inherit umask.
    #[cfg(unix)]
    #[test]
    fn the_sink_is_created_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("tm-turnmode-{}", std::process::id()));
        fs::create_dir_all(&dir).expect("create temp dir");
        let path = dir.join("turns.log");
        append_turn_record(&path, &json!({"event": "turn_route"})).expect("append");
        let mode = fs::metadata(&path).expect("stat").permissions().mode() & 0o777;
        let _ = fs::remove_dir_all(&dir);
        assert_eq!(mode, 0o600, "mode was {mode:o}");
    }

    /// A leader that states the same route the policy would have suggested
    /// needs no callout — `route_deviation` must read as absent, not as an
    /// empty-but-present object, so a consumer can treat `null` as the
    /// no-news case.
    #[test]
    fn route_deviation_is_null_when_stated_route_matches_the_suggestion() {
        let _env = ProcessEnvGuard::acquire();
        let _route_env = RouteDerivationEnv::isolated();
        let home = std::env::temp_dir().join(format!("tm-routedev-match-{}", std::process::id()));
        fs::create_dir_all(home.join(".term-mesh").join("logs")).expect("create temp home");
        let prev_home = env::var("HOME").ok();
        env::set_var("HOME", &home);

        let team = TeamNameResolution {
            name: "term-mesh".to_string(),
            source: TeamNameSource::Explicit,
        };
        // No `available_workers` makes the policy suggest "direct" (see
        // `LeaderParticipationDirective::from_input`), matching the stated
        // route below.
        let result = run_leader_turn_route(&team, "turn-dev-1", "direct", None, None, &[], None)
            .expect("run_leader_turn_route");

        match prev_home {
            Some(v) => env::set_var("HOME", v),
            None => env::remove_var("HOME"),
        }
        let _ = fs::remove_dir_all(&home);

        assert_eq!(result["record"]["suggested_route"], "direct");
        assert_eq!(result["record"]["actual_route"], "direct");
        assert_eq!(result["route_deviation"], Value::Null);
    }

    /// A leader that states a route other than what the policy would have
    /// suggested must have that gap surfaced in the response — the log
    /// record already carries both fields, but the reply never told the
    /// leader they diverged.
    #[test]
    fn route_deviation_reports_suggested_and_stated_when_they_differ() {
        let _env = ProcessEnvGuard::acquire();
        let _route_env = RouteDerivationEnv::isolated();
        let home = std::env::temp_dir().join(format!("tm-routedev-diff-{}", std::process::id()));
        fs::create_dir_all(home.join(".term-mesh").join("logs")).expect("create temp home");
        let prev_home = env::var("HOME").ok();
        env::set_var("HOME", &home);

        let team = TeamNameResolution {
            name: "term-mesh".to_string(),
            source: TeamNameSource::Explicit,
        };
        // `multi_unit` with two available workers makes the policy suggest
        // "parallel"; the leader states "direct" instead.
        let result = run_leader_turn_route(
            &team,
            "turn-dev-2",
            "direct",
            Some("multi_unit"),
            Some(2),
            &[],
            None,
        )
        .expect("run_leader_turn_route");

        match prev_home {
            Some(v) => env::set_var("HOME", v),
            None => env::remove_var("HOME"),
        }
        let _ = fs::remove_dir_all(&home);

        assert_eq!(result["record"]["suggested_route"], "parallel");
        assert_eq!(result["record"]["actual_route"], "direct");
        assert_eq!(
            result["route_deviation"],
            json!({"suggested": "parallel", "stated": "direct"})
        );
    }
}

#[cfg(test)]
mod rcollect_tests {
    use super::*;
    #[test]
    fn rcollect_shape_and_evidence_events_are_ignored_by_health() {
        let record = rcollect_record(
            "p",
            "collect",
            &json!({"result":{"tasks":[{"id":"b"},{"id":"a"}]}}),
        );
        assert_eq!(record["event"], "task_collect");
        assert_eq!(record["task_ids"], json!(["a", "b"]));
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("turns.log");
        fs::write(
            &path,
            b"{\"event\":\"leader_wait\"}\n{\"event\":\"task_collect\"}\n",
        )
        .unwrap();
        assert_eq!(
            leader_participation_health(&path, "p", None).malformed_lines,
            0
        );
    }
}

#[cfg(test)]
mod rroute_tests {
    use super::*;

    #[test]
    fn rroute_explicit_flags_win_and_are_not_marked_derived() {
        let evidence = derive_route_evidence(
            Some("shared"),
            Some(4),
            || panic!("control must not be read when --available-workers is given"),
            || panic!("team.status must not be read when --checkout-mode is given"),
        );
        assert_eq!(evidence.checkout_mode.as_deref(), Some("shared"));
        assert_eq!(evidence.available_workers, Some(4));
        assert!(evidence.derived.is_empty());
    }

    #[test]
    fn rroute_omitted_flags_are_filled_from_recorded_facts() {
        let evidence =
            derive_route_evidence(None, None, || Some(3), || Some("isolated".to_string()));
        assert_eq!(evidence.checkout_mode.as_deref(), Some("isolated"));
        assert_eq!(evidence.available_workers, Some(3));
        assert_eq!(evidence.derived, vec!["checkout_mode", "available_workers"]);
    }

    #[test]
    fn rroute_unknown_sources_stay_absent() {
        let evidence = derive_route_evidence(None, None, || None, || None);
        assert_eq!(evidence, DerivedRouteEvidence::default());
    }

    #[test]
    fn rroute_reads_only_a_recorded_layout_of_this_team() {
        let status = json!({"team_name": "mine", "checkout_mode": " isolated "});
        assert_eq!(
            checkout_mode_from_team_status(&status, "mine").as_deref(),
            Some("isolated")
        );
        assert_eq!(checkout_mode_from_team_status(&status, "other"), None);
        for mode in ["shared", "off"] {
            let status = json!({"team_name": "mine", "checkout_mode": mode});
            assert_eq!(
                checkout_mode_from_team_status(&status, "mine").as_deref(),
                Some(mode)
            );
        }
        for status in [
            json!({"team_name": "mine", "checkout_mode": "unknown"}),
            json!({"team_name": "mine", "checkout_mode": ""}),
            json!({"team_name": "mine", "worktree_mode": "isolated"}),
            json!({"team_name": "mine", "checkout_mode": 1}),
        ] {
            assert_eq!(
                checkout_mode_from_team_status(&status, "mine"),
                None,
                "{status}"
            );
        }
    }

    #[test]
    fn rroute_reads_the_roster_count_from_the_control_payload() {
        assert_eq!(
            available_workers_from_control(&json!({"available_workers": 2})),
            Some(2)
        );
        assert_eq!(
            available_workers_from_control(&json!({"available_workers": 0})),
            Some(0)
        );
        assert_eq!(available_workers_from_control(&json!({})), None);
        assert_eq!(
            available_workers_from_control(&json!({"available_workers": "2"})),
            None
        );
        assert_eq!(
            available_workers_from_control(&json!({"available_workers": -1})),
            None
        );
    }
}
