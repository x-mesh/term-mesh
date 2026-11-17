use super::*;

// ---------------------------------------------------------------------------
// gc — disk reclamation
// ---------------------------------------------------------------------------

/// Scanning walks whole worktrees, so the default 6s RPC budget is far too
/// tight for anything but `status` on a small machine.
pub(crate) const GC_TIMEOUT_SECS: u64 = 120;

pub(crate) fn gc_call(sock: &PathBuf, method: &str, params: Value) -> Result<Value, String> {
    decode_daemon_response(rpc_call_timeout(sock, method, params, GC_TIMEOUT_SECS)?)
}

pub(crate) fn human_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "K", "M", "G", "T"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes}{}", UNITS[0])
    } else {
        format!("{value:.1}{}", UNITS[unit])
    }
}

pub(crate) fn gc_scope_params(categories: &[String], roots: &[String], deep: bool) -> Value {
    let mut params = json!({});
    if !categories.is_empty() {
        params["categories"] = json!(categories);
    }
    if !roots.is_empty() {
        params["roots"] = json!(roots);
    }
    if deep {
        params["deep"] = json!(true);
    }
    params
}

pub(crate) fn cmd_gc(sock: &PathBuf, command: &GcCommand) {
    let result = match command {
        GcCommand::Status { project, json: raw } => {
            let params = match project {
                Some(id) => json!({ "project_id": id }),
                None => json!({}),
            };
            gc_call(sock, "gc.status", params).map(|value| {
                if *raw {
                    println!("{}", pretty(&value));
                } else {
                    render_gc_status(&value);
                }
            })
        }
        GcCommand::Plan {
            categories,
            roots,
            deep,
            json: raw,
        } => gc_call(sock, "gc.plan", gc_scope_params(categories, roots, *deep)).map(|value| {
            if *raw {
                println!("{}", pretty(&value));
            } else {
                render_gc_plan(&value);
            }
        }),
        GcCommand::Sweep {
            apply,
            force,
            categories,
            roots,
            deep,
            json: raw,
        } => {
            let mut params = gc_scope_params(categories, roots, *deep);
            params["apply"] = json!(*apply);
            params["force"] = json!(*force);
            gc_call(sock, "gc.sweep", params).map(|value| {
                if *raw {
                    println!("{}", pretty(&value));
                } else {
                    render_gc_sweep(&value, *apply);
                }
            })
        }
    };

    if let Err(error) = result {
        eprintln!("Error: {error}");
        process::exit(1);
    }
}

pub(crate) fn render_gc_status(value: &Value) {
    let categories = value
        .get("categories")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    println!(
        "{:<20} {:>7} {:>10} {:>10} {:>11}  {}",
        "CATEGORY", "ENTRIES", "SIZE", "RECLAIM", "CANDIDATES", "SWEPT"
    );
    for category in &categories {
        let name = category
            .get("category")
            .and_then(Value::as_str)
            .unwrap_or("?");
        let entries = category
            .get("entry_count")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let total = category
            .get("total_bytes")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let reclaim = category
            .get("reclaimable_bytes")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let candidates = category
            .get("candidate_count")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let auto = category
            .get("auto")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        println!(
            "{:<20} {:>7} {:>10} {:>10} {:>11}  {}",
            name,
            entries,
            human_bytes(total),
            human_bytes(reclaim),
            candidates,
            if auto { "auto" } else { "manual" }
        );
    }

    let total = value
        .get("total_bytes")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let reclaim = value
        .get("reclaimable_bytes")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    println!();
    println!(
        "total {}  reclaimable {}",
        human_bytes(total),
        human_bytes(reclaim)
    );

    match value.get("last_sweep") {
        Some(sweep) if !sweep.is_null() => {
            println!(
                "last sweep: {} — removed {}, reclaimed {}",
                sweep.get("mode").and_then(Value::as_str).unwrap_or("?"),
                sweep.get("removed").and_then(Value::as_u64).unwrap_or(0),
                human_bytes(
                    sweep
                        .get("reclaimed_bytes")
                        .and_then(Value::as_u64)
                        .unwrap_or(0)
                )
            );
        }
        _ => println!("last sweep: never"),
    }
    println!("run `tm-agent gc plan` for the candidate list");
}

pub(crate) fn render_gc_plan(value: &Value) {
    let categories = value
        .get("categories")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    for category in &categories {
        let candidates = category
            .get("candidates")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        if candidates.is_empty() {
            continue;
        }
        let name = category
            .get("category")
            .and_then(Value::as_str)
            .unwrap_or("?");
        println!("── {name}");
        if let Some(note) = category.get("note").and_then(Value::as_str) {
            println!("   ({note})");
        }
        for candidate in &candidates {
            let path = candidate.get("path").and_then(Value::as_str).unwrap_or("?");
            let bytes = candidate.get("bytes").and_then(Value::as_u64).unwrap_or(0);
            let blockers = candidate
                .get("blockers")
                .and_then(Value::as_array)
                .map(|list| {
                    list.iter()
                        .filter_map(Value::as_str)
                        .collect::<Vec<_>>()
                        .join(",")
                })
                .unwrap_or_default();
            let marker = if blockers.is_empty() { "✓" } else { "✗" };
            let detail = if blockers.is_empty() {
                candidate
                    .get("reasons")
                    .and_then(Value::as_array)
                    .map(|list| {
                        list.iter()
                            .filter_map(Value::as_str)
                            .collect::<Vec<_>>()
                            .join(",")
                    })
                    .unwrap_or_default()
            } else {
                format!("blocked: {blockers}")
            };
            println!("   {marker} {:>8}  {path}", human_bytes(bytes));
            if !detail.is_empty() {
                println!("              {detail}");
            }
        }
        println!();
    }

    let reclaim = value
        .get("reclaimable_bytes")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    println!("reclaimable {}", human_bytes(reclaim));
    println!("`tm-agent gc sweep` previews the removal; add --apply to perform it");
}

pub(crate) fn render_gc_sweep(value: &Value, applied: bool) {
    let outcomes = value
        .get("outcomes")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    for outcome in &outcomes {
        let action = outcome.get("action").and_then(Value::as_str).unwrap_or("?");
        if action == "skipped" {
            continue;
        }
        println!(
            "{:<13} {:>8}  {}",
            action,
            human_bytes(outcome.get("bytes").and_then(Value::as_u64).unwrap_or(0)),
            outcome.get("path").and_then(Value::as_str).unwrap_or("?")
        );
    }

    let removed = value.get("removed").and_then(Value::as_u64).unwrap_or(0);
    let skipped = value.get("skipped").and_then(Value::as_u64).unwrap_or(0);
    let reclaimed = value
        .get("reclaimed_bytes")
        .and_then(Value::as_u64)
        .unwrap_or(0);

    println!();
    println!(
        "{} item(s), {} — {} skipped by blockers",
        removed,
        human_bytes(reclaimed),
        skipped
    );
    if !applied {
        println!("(dry-run — pass --apply to delete)");
    }
}

/// Say so when this binary and the app it just failed to talk to are from
/// different builds.
///
/// A stale CLI fails in whatever way its own generation failed: a 0.167.0
/// `tm-agent` driving a 0.170.x app answered every leader-scoped command with
/// `noMatchingLeaderSession` — a name that exists nowhere in the current tree,
/// so the message pointed at nothing and the team simply never received an
/// instruction. Nothing in that failure suggested the binary was the problem,
/// and the binary was the whole problem.
///
/// This runs only on the failure path, so the check costs nothing when things
/// work, and it stays quiet unless the two builds actually disagree — a
/// version line printed under every unrelated error would train people to
/// scroll past it.
pub(crate) fn eprint_version_skew() {
    let Some(sock) = detect_socket() else { return };
    let Ok(info) = rpc_call(&sock, "system.info", json!({})) else {
        return;
    };
    if let Some(note) = version_skew_note(
        GIT_SHA,
        info["result"]["git_sha"].as_str().unwrap_or_default(),
        env!("CARGO_PKG_VERSION"),
        info["result"]["app_version"].as_str().unwrap_or("unknown"),
    ) {
        eprintln!("{note}");
    }
}

/// The note for a CLI and an app built from different commits, or `None` when
/// they agree — or when the app did not say, which is not evidence of skew and
/// must not be reported as one.
pub(crate) fn version_skew_note(
    cli_sha: &str,
    app_sha: &str,
    cli_version: &str,
    app_version: &str,
) -> Option<String> {
    if app_sha.is_empty() || app_sha == cli_sha {
        return None;
    }
    Some(format!(
        "\nThis tm-agent is {} ({}), the term-mesh app is {} ({}).\n\
         Different builds: the command above may have failed for that reason \
         alone. Check which binary is running with `command -v tm-agent` — an \
         older copy earlier in PATH shadows a current one.",
        cli_version,
        short_sha(cli_sha),
        app_version,
        short_sha(app_sha),
    ))
}

pub(crate) fn short_sha(sha: &str) -> &str {
    if sha.len() > 9 {
        &sha[..9]
    } else {
        sha
    }
}

/// Parse a `tm-agent daemon replay-capacity --set` value: a plain byte
/// count, or a byte count with a `k`/`kb` (KiB, ×1024) or `m`/`mb` (MiB,
/// ×1024²) suffix — case-insensitive (e.g. `262144`, `256kb`, `2mb`, `2M`).
pub(crate) fn parse_byte_size(raw: &str) -> Result<usize, String> {
    let s = raw.trim();
    if s.is_empty() {
        return Err("empty value".to_string());
    }
    let lower = s.to_ascii_lowercase();
    let (digits, multiplier) =
        if let Some(prefix) = lower.strip_suffix("kb").or_else(|| lower.strip_suffix('k')) {
            (prefix, 1024usize)
        } else if let Some(prefix) = lower.strip_suffix("mb").or_else(|| lower.strip_suffix('m')) {
            (prefix, 1024usize * 1024)
        } else {
            (lower.as_str(), 1usize)
        };
    let n: usize = digits
        .trim()
        .parse()
        .map_err(|e| format!("invalid byte size {raw:?}: {e}"))?;
    n.checked_mul(multiplier)
        .ok_or_else(|| format!("byte size overflow: {raw:?}"))
}

/// One daemon RPC: the `result` value, or the transport/RPC error message.
pub(crate) fn cmd_daemon_rpc(
    sock: &PathBuf,
    method: &str,
    params: serde_json::Value,
) -> Result<serde_json::Value, String> {
    // Forced prune waits for each selected process group to stop.
    let response = if method == "peer.project_presentations.prune"
        && params["force"] == true
        && params["apply"] == true
    {
        let timeout = env::var("TERMMESH_RPC_TIMEOUT")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(120);
        rpc_call_timeout(sock, method, params, timeout)
    } else {
        rpc_call(sock, method, params)
    };
    match response {
        Ok(resp) if resp["error"].is_null() => Ok(resp["result"].clone()),
        Ok(resp) => Err(resp["error"]["message"]
            .as_str()
            .map(str::to_string)
            .unwrap_or_else(|| format!("{method} failed"))),
        Err(e) => Err(e.to_string()),
    }
}

/// Print a daemon RPC result, or the error and a non-zero exit so scripts
/// can trust the status. Returns the result for callers adding a summary.
pub(crate) fn cmd_daemon_rpc_print(
    sock: &PathBuf,
    method: &str,
    params: serde_json::Value,
) -> serde_json::Value {
    match cmd_daemon_rpc(sock, method, params) {
        Ok(result) => {
            println!("{}", pretty(&result));
            result
        }
        Err(msg) => {
            eprintln!("Error: {msg}");
            process::exit(1);
        }
    }
}

/// The peer state directory term-meshd writes.
///
/// Mirrors `peer::persist::default_workspaces_path`'s base deliberately: that
/// function reads no environment variable, so every daemon on this machine —
/// tagged dev builds included — shares one directory, and an offline reset has
/// exactly one place to look.
pub(crate) fn peer_state_dir() -> std::path::PathBuf {
    dirs::data_local_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("/tmp"))
        .join("term-meshd")
}

/// Which files a scope covers. Ensured-surface records are never included:
/// losing those costs runner identity, not a stale name.
pub(crate) fn peer_state_files(scope: &str) -> Vec<(&'static str, std::path::PathBuf)> {
    let dir = peer_state_dir();
    let mut out = Vec::new();
    if scope == "projects" || scope == "all" {
        out.push(("projects", dir.join("peer-project-presentations.json")));
    }
    if scope == "workspaces" || scope == "all" {
        out.push(("workspaces", dir.join("peer-workspaces.json")));
    }
    out
}

/// Take `.peer-state.lock` exclusively. Failing is the answer to "is a daemon
/// still running": one holds this shared for the life of its listener, and
/// rewriting these files under it would just be saved over by its next write.
pub(crate) fn try_lock_peer_state_dir(dir: &std::path::Path) -> std::io::Result<std::fs::File> {
    use std::os::fd::AsRawFd;

    std::fs::create_dir_all(dir)?;
    let file = std::fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(dir.join(".peer-state.lock"))?;
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(file)
}

/// Copy `path` next to itself before removing it, matching the daemon's
/// `persist::backup_state_file` naming so both paths leave the same trail.
pub(crate) fn backup_peer_state_file(path: &std::path::Path) -> Result<Option<String>, String> {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or(0);
    backup_peer_state_file_at(path, stamp)
}

pub(crate) fn backup_peer_state_file_at(
    path: &std::path::Path,
    stamp: u64,
) -> Result<Option<String>, String> {
    if !path.exists() {
        return Ok(None);
    }
    let stem = path
        .file_stem()
        .and_then(|stem| stem.to_str())
        .ok_or_else(|| format!("cannot derive a backup name for {}", path.display()))?;
    for suffix in 0..=1000 {
        let name = if suffix == 0 {
            format!("{stem}.{stamp}.bak.json")
        } else {
            format!("{stem}.{stamp}-{suffix}.bak.json")
        };
        let candidate = path.with_file_name(name);
        // `create_new` refuses any existing name, a symlink included, so the
        // copy never writes through a link planted in a shared state directory
        // between choosing the name and writing it.
        let mut backup = match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&candidate)
        {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(format!("backup failed: {e}")),
        };
        let copied = std::fs::File::open(path).and_then(|mut source| {
            std::io::copy(&mut source, &mut backup)?;
            // Through the open handle (fchmod), not the path: the name could
            // be swapped for a link after `create_new` made it.
            backup.set_permissions(source.metadata()?.permissions())
        });
        if let Err(e) = copied {
            let _ = std::fs::remove_file(&candidate);
            return Err(format!("backup failed: {e}"));
        }
        return Ok(Some(candidate.display().to_string()));
    }
    Err(format!("too many backups beside {}", path.display()))
}

/// Reset with no daemon to ask.
///
/// This cannot tell a live surface from a dead one, so it does not try to be
/// selective: it backs each file up and removes it, which the loaders treat
/// exactly like an empty file. The daemon path (`peer.state.reset`) is the one
/// that refuses live work — prefer it whenever the daemon is up.
pub(crate) fn cmd_daemon_reset_offline(scope: &str, apply: bool) -> ! {
    let dir = peer_state_dir();
    let files = peer_state_files(scope);

    let lock = match try_lock_peer_state_dir(&dir) {
        Ok(lock) => lock,
        Err(error) => {
            eprintln!(
                "Error: {} is still owned by a running term-meshd ({error}).\n\
                 Stop it first (systemctl stop term-meshd, or quit the app), or run this\n\
                 with the daemon up so it can clear its in-memory copy too.",
                dir.display()
            );
            // Same class as `watch doctor`'s \"tried and it is still wrong\".
            process::exit(3);
        }
    };

    let mut entries = Vec::new();
    for (scope_name, path) in &files {
        entries.push(json!({
            "scope": scope_name,
            "path": path.display().to_string(),
            "present": path.exists(),
        }));
    }

    if !apply {
        let present = files.iter().filter(|(_, path)| path.exists()).count();
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "applied": false,
                "daemon": "not running",
                "files": entries,
            }))
            .unwrap_or_default()
        );
        if present > 0 {
            println!("(dry-run — pass --apply to clear {present} file(s))");
        }
        drop(lock);
        process::exit(0);
    }

    // `scope=all` clears two files, so a failure on the second one leaves the
    // first already gone. Exiting inside the loop would take the `cleared`
    // list with it — including the backup path that is the only way back — so
    // failures are collected and reported next to what did get removed.
    let mut cleared = Vec::new();
    let mut failed = Vec::new();
    for (scope_name, path) in &files {
        if !path.exists() {
            continue;
        }
        let backup = match backup_peer_state_file(path) {
            Ok(backup) => backup,
            Err(error) => {
                failed.push(json!({
                    "scope": scope_name,
                    "path": path.display().to_string(),
                    "error": error,
                }));
                continue;
            }
        };
        if let Err(error) = std::fs::remove_file(path) {
            failed.push(json!({
                "scope": scope_name,
                "path": path.display().to_string(),
                "backup_path": backup,
                "error": format!("could not remove: {error}"),
            }));
            continue;
        }
        cleared.push(json!({
            "scope": scope_name,
            "path": path.display().to_string(),
            "backup_path": backup,
        }));
    }

    println!(
        "{}",
        serde_json::to_string_pretty(&json!({
            // What ran, not what qualified: an --apply that found nothing to
            // clear still ran, and `cleared` says it removed nothing.
            "applied": true,
            "daemon": "not running",
            "directory": dir.display().to_string(),
            "cleared": cleared,
            "failed": failed,
        }))
        .unwrap_or_default()
    );
    for failure in &failed {
        eprintln!(
            "Error: {} — {}",
            failure["path"].as_str().unwrap_or("?"),
            failure["error"].as_str().unwrap_or("?")
        );
    }
    let exit_code = if failed.is_empty() { 0 } else { 1 };
    drop(lock);
    process::exit(exit_code);
}

/// `tm-agent daemon replay-capacity [--set <value>]` — get or set the peer
/// PTY-surface replay buffer capacity via the `peer.replay_capacity` RPC.
pub(crate) fn cmd_daemon_replay_capacity(sock: &PathBuf, set: Option<&str>) {
    let params = match set {
        Some(raw) => match parse_byte_size(raw) {
            Ok(bytes) => json!({ "bytes": bytes }),
            Err(e) => {
                eprintln!("Error: {e}");
                process::exit(1);
            }
        },
        None => json!({}),
    };
    match rpc_call(sock, "peer.replay_capacity", params) {
        Ok(resp) if resp["error"].is_null() => {
            println!("{}", pretty(&resp["result"]));
        }
        Ok(resp) => {
            let msg = resp["error"]["message"]
                .as_str()
                .unwrap_or("peer.replay_capacity failed");
            eprintln!("Error: {msg}");
            process::exit(1);
        }
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    }
}

#[cfg(test)]
mod daemon_replay_capacity_tests {
    use super::*;

    #[test]
    fn reply_task_identity_rejects_same_name_sibling() {
        let task = json!({
            "assignee": "executor",
            "agent_instance_id": "instance-a",
        });
        assert_eq!(
            task_instance_for_reply(&task, "task-a", "executor", Some("instance-a")).unwrap(),
            Some("instance-a".to_string())
        );
        assert!(task_instance_for_reply(&task, "task-a", "executor", Some("instance-b")).is_err());
    }

    #[test]
    fn parse_byte_size_plain_digits() {
        assert_eq!(parse_byte_size("262144"), Ok(262144));
    }

    #[test]
    fn parse_byte_size_kb_and_k_suffix() {
        assert_eq!(parse_byte_size("256kb"), Ok(256 * 1024));
        assert_eq!(parse_byte_size("256KB"), Ok(256 * 1024));
        assert_eq!(parse_byte_size("256k"), Ok(256 * 1024));
        assert_eq!(parse_byte_size("256K"), Ok(256 * 1024));
    }

    #[test]
    fn parse_byte_size_mb_and_m_suffix() {
        assert_eq!(parse_byte_size("2mb"), Ok(2 * 1024 * 1024));
        assert_eq!(parse_byte_size("2MB"), Ok(2 * 1024 * 1024));
        assert_eq!(parse_byte_size("2m"), Ok(2 * 1024 * 1024));
        assert_eq!(parse_byte_size("2M"), Ok(2 * 1024 * 1024));
    }

    #[test]
    fn parse_byte_size_trims_whitespace() {
        assert_eq!(parse_byte_size(" 2mb \n"), Ok(2 * 1024 * 1024));
    }

    #[test]
    fn parse_byte_size_rejects_garbage_and_empty() {
        assert!(parse_byte_size("").is_err());
        assert!(parse_byte_size("not-a-number").is_err());
        assert!(parse_byte_size("kb").is_err()); // suffix with no digits
    }
}

/// Does this socket path look like the term-mesh *app* socket rather than the
/// term-meshd daemon socket? App sockets are `term-mesh*.sock` (no trailing `d`)
/// or `cmux.sock`; the daemon is `term-meshd*.sock`. Used to keep daemon RPCs off
/// the app socket.
pub(crate) fn is_app_socket_path(path: &Path) -> bool {
    match path.file_name().and_then(|n| n.to_str()) {
        Some(name) => {
            name == "cmux.sock"
                || (name.starts_with("term-mesh") && !name.starts_with("term-meshd"))
        }
        None => false,
    }
}

/// Resolve the app (Swift) socket for watch's GUI execution path (§4 pane
/// recycle). The daemon needs it to drive recycle/send/read on a GUI watcher
/// pane; without it the GUI path can't run and watch falls back to the headless
/// one-shot. Priority: an explicit value, then an app `TERMMESH_SOCKET`, then an
/// auto-detected *app* socket (a detected daemon socket is rejected — the
/// `watch on` caller's leader pane may lack TERMMESH_SOCKET, so detection covers
/// it). Returns None for pure-headless callers, which keeps the headless path.
pub(crate) fn resolve_app_socket(explicit: Option<&str>) -> Option<String> {
    if let Some(e) = explicit {
        let p = PathBuf::from(e);
        if !e.is_empty() && is_app_socket_path(&p) && is_socket_alive(&p) {
            return Some(e.to_string());
        }
    }
    if let Ok(ts) = env::var("TERMMESH_SOCKET") {
        let p = PathBuf::from(&ts);
        if !ts.is_empty() && is_app_socket_path(&p) && is_socket_alive(&p) {
            return Some(ts);
        }
    }
    detect_socket()
        .filter(|p| is_app_socket_path(p))
        .map(|p| p.to_string_lossy().into_owned())
}

/// Derive this app instance's term-meshd socket from its *app* socket path (P15).
///
/// Mirrors `scripts/reload.sh`: a tagged app socket `/tmp/term-mesh-debug-<tag>.sock`
/// is served by daemon `~/Library/Application Support/term-mesh/term-meshd-dev-<tag>.sock`.
/// Returns `None` for the live/untagged app socket so it falls through to the
/// default daemon — preserving instance isolation (a tagged leader never derives
/// the live daemon, and the live leader keeps using the default).
pub(crate) fn derive_daemon_socket_from_app(app_path: &Path) -> Option<PathBuf> {
    let name = app_path.file_name().and_then(|n| n.to_str())?;
    // Only the tagged debug app socket maps to an isolated Application Support daemon.
    let tag = name
        .strip_prefix("term-mesh-debug-")
        .and_then(|rest| rest.strip_suffix(".sock"))
        .filter(|t| !t.is_empty())?;
    let home = env::var("HOME").ok().filter(|h| !h.is_empty())?;
    Some(
        PathBuf::from(home)
            .join("Library/Application Support/term-mesh")
            .join(format!("term-meshd-dev-{tag}.sock")),
    )
}

/// Resolve the term-meshd socket for `tm-agent watch` (P12 #4, P15 routing).
///
/// Priority:
/// 1. `TERMMESH_DAEMON_SOCKET` / `TERMMESH_DAEMON_UNIX_PATH` (the app injects the
///    latter into every pane env, so a leader pane reaches its own daemon).
/// 2. `TERMMESH_SOCKET` when it is itself a *daemon* socket (tagged standalone).
/// 3. `TERMMESH_SOCKET` when it is an *app* socket → derive this instance's daemon
///    socket from it (P15: `TERMMESH_SOCKET`-only routing, isolation-preserving).
/// 4. the default daemon socket.
/// 5. any live socket as a last resort.
///
/// The app-socket guard at steps 2/3 keeps a leader pane from misrouting `watch.*`
/// to the app socket (which returns method_not_found) while still reaching the
/// correct per-instance daemon.
pub(crate) fn detect_watch_socket() -> Option<PathBuf> {
    // Highest priority (F1): an explicit *app-socket* TERMMESH_SOCKET is a deliberate
    // instance selection. Derive its daemon and use it, overriding the ambient
    // TERMMESH_DAEMON_* env (which reflects the *calling pane's* default instance,
    // not the explicitly chosen one). Without this, running `tm-agent watch …` with
    // an explicit TERMMESH_SOCKET from inside another instance's pane misroutes the
    // watch (and its ticks) to the wrong/stale daemon. Only applies when the app
    // socket is derivable (tagged) and its daemon is alive; otherwise fall through.
    if let Ok(p) = env::var("TERMMESH_SOCKET") {
        if !p.is_empty() {
            let path = PathBuf::from(&p);
            if is_socket_alive(&path) && is_app_socket_path(&path) {
                if let Some(derived) = derive_daemon_socket_from_app(&path) {
                    if is_socket_alive(&derived) {
                        return Some(derived);
                    }
                }
            }
        }
    }
    for var in ["TERMMESH_DAEMON_SOCKET", "TERMMESH_DAEMON_UNIX_PATH"] {
        if let Ok(p) = env::var(var) {
            if !p.is_empty() {
                let path = PathBuf::from(&p);
                if is_socket_alive(&path) {
                    return Some(path);
                }
            }
        }
    }
    if let Ok(p) = env::var("TERMMESH_SOCKET") {
        if !p.is_empty() {
            let path = PathBuf::from(&p);
            if is_socket_alive(&path) {
                // Explicit daemon socket → use directly.
                if !is_app_socket_path(&path) {
                    return Some(path);
                }
                // App socket → derive this instance's daemon (P15).
                if let Some(derived) = derive_daemon_socket_from_app(&path) {
                    if is_socket_alive(&derived) {
                        return Some(derived);
                    }
                }
            }
        }
    }
    // Default daemon socket, then every other place a daemon binds one.
    daemon_socket_candidates()
        .into_iter()
        .find(is_socket_alive)
        // Last resort: any socket the generic resolver finds.
        .or_else(detect_socket)
}

/// `TERMMESH_DAEMON_UNIX_PATH` as the peer-host config records it.
///
/// systemd hands this file to the service through `EnvironmentFile`, so the
/// daemon binds what it says while a login shell never sees the value. That
/// is the whole reason a Linux operator had to export the variable by hand
/// before `tm-agent` could reach their own daemon.
///
/// Later files win, matching the `tail -n 1` the ssh probe applies over the
/// same two paths.
pub(crate) fn peer_env_daemon_sockets_from_paths(configs: &[PathBuf]) -> Vec<PathBuf> {
    let mut found = Vec::new();
    for config in configs {
        let Ok(contents) = std::fs::read_to_string(&config) else {
            continue;
        };
        for line in contents.lines() {
            let Some(value) = line.trim().strip_prefix("TERMMESH_DAEMON_UNIX_PATH=") else {
                continue;
            };
            let value = value.trim().trim_matches(['"', '\''].as_slice());
            if !value.is_empty() {
                let path = PathBuf::from(value);
                found.retain(|existing| existing != &path);
                found.insert(0, path);
            }
        }
    }
    found
}

pub(crate) fn peer_env_daemon_sockets() -> Vec<PathBuf> {
    let mut configs = Vec::new();
    if let Some(home) = env::var_os("HOME") {
        configs.push(PathBuf::from(home).join(".config/term-mesh/peer.env"));
    }
    configs.push(PathBuf::from("/etc/term-mesh/peer.env"));
    peer_env_daemon_sockets_from_paths(&configs)
}

/// Every place a term-meshd control socket can live, in the order to try.
///
/// The daemon's own `default_socket_path` resolves `dirs::runtime_dir()`
/// before `TMPDIR`. On Linux that is `$XDG_RUNTIME_DIR` — a directory this
/// resolver never looked in — while on macOS there is no runtime dir at all
/// and the daemon lands in `TMPDIR`. That asymmetry, not any Linux-specific
/// packaging, is why the CLI needed no environment on a Mac and needed
/// `TERMMESH_DAEMON_UNIX_PATH` exported by hand on every Linux host.
///
/// The installer's two scopes add the rest: a user service binds
/// `/run/user/<uid>/term-meshd.sock`, a system service
/// `/run/term-mesh/term-meshd.sock`.
///
/// Same paths and same order as `REMOTE_CONTROL_SOCKET_DISCOVERY` in
/// `peer.rs`, which has always resolved this correctly over ssh. A path that
/// cannot exist on this platform fails the liveness probe on its first
/// syscall, so one list serves both rather than a per-OS pair that can drift.
pub(crate) fn daemon_socket_candidates() -> Vec<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    let mut push = |path: PathBuf| {
        if !path.as_os_str().is_empty() && !candidates.contains(&path) {
            candidates.push(path);
        }
    };
    for var in ["TERMMESH_DAEMON_SOCKET", "TERMMESH_DAEMON_UNIX_PATH"] {
        if let Ok(value) = env::var(var) {
            push(PathBuf::from(value));
        }
    }
    for path in peer_env_daemon_sockets() {
        push(path);
    }
    if let Ok(runtime_dir) = env::var("XDG_RUNTIME_DIR") {
        if !runtime_dir.is_empty() {
            push(PathBuf::from(runtime_dir).join("term-meshd.sock"));
        }
    }
    // `id -u` without spawning it: the ssh probe's `/run/user/$(id -u)` for a
    // user-scope service whose XDG_RUNTIME_DIR did not reach this shell.
    push(PathBuf::from(format!("/run/user/{}", unsafe { libc::getuid() })).join("term-meshd.sock"));
    push(PathBuf::from("/run/term-mesh/term-meshd.sock"));
    if let Ok(tmpdir) = env::var("TMPDIR") {
        if !tmpdir.is_empty() {
            push(PathBuf::from(tmpdir).join("term-meshd.sock"));
        }
    }
    push(PathBuf::from("/tmp/term-meshd.sock"));
    candidates
}

pub(crate) fn detect_daemon_socket() -> Option<PathBuf> {
    daemon_socket_candidates().into_iter().find(is_socket_alive)
}

/// The daemon whose headless agents are members of this process's team. A
/// remote leader's team lives on the owning host, so a same-name headless team
/// on this host's daemon is unrelated and must never be resolved.
pub(crate) fn team_headless_daemon_socket() -> Option<PathBuf> {
    headless_daemon_socket_for_route(remote_leader_route().is_some(), detect_daemon_socket)
}

pub(crate) fn headless_daemon_socket_for_route(
    has_route: bool,
    detect: impl FnOnce() -> Option<PathBuf>,
) -> Option<PathBuf> {
    if has_route {
        return None;
    }
    detect()
}

#[derive(Debug, Clone)]
pub(crate) enum DoctorSocketOutcome {
    Report(Vec<Value>),
    Unsupported(String),
    RpcFailed(String),
    ProbeFailed(String),
    Untrusted(String),
}

pub(crate) fn parse_doctor_result(result: Value) -> Result<Vec<Value>, String> {
    let object = result
        .as_object()
        .ok_or_else(|| "protocol error: peer.doctor result is not an object".to_string())?;
    let healthy = object
        .get("healthy")
        .and_then(Value::as_bool)
        .ok_or_else(|| "protocol error: peer.doctor result has no boolean healthy".to_string())?;
    let findings = object
        .get("findings")
        .and_then(Value::as_array)
        .cloned()
        .ok_or_else(|| "protocol error: peer.doctor result has no findings array".to_string())?;
    if healthy != findings.is_empty() {
        return Err("protocol error: peer.doctor healthy disagrees with findings".to_string());
    }
    Ok(findings)
}

pub(crate) fn local_doctor_finding(code: &str, socket: &Path, detail: String) -> Value {
    json!({
        "code": code,
        "severity": "error",
        "socket": socket.display().to_string(),
        "detail": detail,
        "remedy": "",
        "repair_argv": [],
    })
}

pub(crate) fn safe_inspect_repair() -> (String, Vec<Value>) {
    let argv = vec![
        Value::String("tm-agent".into()),
        Value::String("daemon".into()),
        Value::String("project-presentations".into()),
        Value::String("list".into()),
    ];
    (
        "'tm-agent' 'daemon' 'project-presentations' 'list'".into(),
        argv,
    )
}

pub(crate) fn with_multiple_daemon_repair_withheld(mut finding: Value) -> Value {
    let repair_argv = finding["repair_argv"].as_array();
    let applied = repair_argv
        .and_then(|argv| argv.last())
        .and_then(Value::as_str)
        == Some("--apply");
    let legacy_nonempty_remedy = repair_argv.is_none_or(Vec::is_empty)
        && finding["remedy"]
            .as_str()
            .is_some_and(|remedy| !remedy.is_empty());
    if !applied && !legacy_nonempty_remedy {
        return finding;
    }
    if let Some(object) = finding.as_object_mut() {
        let detail = object
            .get("detail")
            .and_then(Value::as_str)
            .unwrap_or_default();
        object.insert(
            "detail".into(),
            Value::String(format!(
                "{detail}; applied repair is withheld because multiple daemons are live and the source socket must be resolved first"
            )),
        );
        let (remedy, argv) = safe_inspect_repair();
        object.insert("remedy".into(), Value::String(remedy));
        object.insert("repair_argv".into(), Value::Array(argv));
    }
    finding
}

pub(crate) fn doctor_is_complete(outcomes: &[(PathBuf, DoctorSocketOutcome)]) -> bool {
    outcomes
        .iter()
        .any(|(_, outcome)| matches!(outcome, DoctorSocketOutcome::Report(_)))
        && !outcomes.iter().any(|(_, outcome)| {
            matches!(
                outcome,
                DoctorSocketOutcome::Unsupported(_)
                    | DoctorSocketOutcome::RpcFailed(_)
                    | DoctorSocketOutcome::ProbeFailed(_)
            )
        })
}

pub(crate) fn doctor_exit_code(
    outcomes: &[(PathBuf, DoctorSocketOutcome)],
    findings: &[Value],
) -> i32 {
    if !doctor_is_complete(outcomes) {
        1
    } else if findings.is_empty() {
        0
    } else {
        2
    }
}

pub(crate) fn human_remedy(finding: &Value) -> String {
    let has_control = finding["repair_argv"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .any(|argument| argument.chars().any(char::is_control));
    if has_control {
        "unavailable in human output; inspect --json".into()
    } else {
        terminal_safe(finding["remedy"].as_str().unwrap_or_default())
    }
}

pub(crate) fn human_remedy_line(finding: &Value) -> Option<String> {
    let remedy = finding["remedy"].as_str().unwrap_or_default();
    if remedy.is_empty() {
        None
    } else {
        Some(human_remedy(finding))
    }
}

pub(crate) fn aggregate_doctor_findings(outcomes: &[(PathBuf, DoctorSocketOutcome)]) -> Vec<Value> {
    let trusted: Vec<_> = outcomes
        .iter()
        .filter(|(_, outcome)| {
            !matches!(
                outcome,
                DoctorSocketOutcome::ProbeFailed(_) | DoctorSocketOutcome::Untrusted(_)
            )
        })
        .collect();
    let connected_count = outcomes
        .iter()
        .filter(|(_, outcome)| !matches!(outcome, DoctorSocketOutcome::ProbeFailed(_)))
        .count();
    let mut findings = Vec::new();
    if trusted.len() > 1 {
        let paths = trusted
            .iter()
            .map(|(path, _)| path.display().to_string())
            .collect::<Vec<_>>();
        findings.push(json!({
            "code": "multiple_daemon_owners",
            "severity": "error",
            "detail": format!(
                "{} trusted term-meshd sockets are listening ({})",
                paths.len(),
                paths.join(", ")
            ),
            "remedy": "stop every term-meshd but the intended owner, then restart it",
            "repair_argv": [],
        }));
    }
    let connected_ambiguity = connected_count > 1;
    for (path, outcome) in outcomes {
        match outcome {
            DoctorSocketOutcome::Report(reported) => {
                for finding in reported {
                    let mut finding = finding.clone();
                    if let Some(object) = finding.as_object_mut() {
                        object.insert("socket".into(), Value::String(path.display().to_string()));
                    }
                    findings.push(if connected_ambiguity {
                        with_multiple_daemon_repair_withheld(finding)
                    } else {
                        finding
                    });
                }
            }
            DoctorSocketOutcome::Unsupported(message) => {
                findings.push(local_doctor_finding(
                    "doctor_unsupported",
                    path,
                    format!("the daemon does not support peer.doctor: {message}"),
                ));
            }
            DoctorSocketOutcome::RpcFailed(message) => {
                findings.push(local_doctor_finding(
                    "doctor_rpc_failed",
                    path,
                    format!("peer.doctor failed: {message}"),
                ));
            }
            DoctorSocketOutcome::ProbeFailed(message) => findings.push(local_doctor_finding(
                "socket_probe_failed",
                path,
                message.clone(),
            )),
            DoctorSocketOutcome::Untrusted(message) => findings.push(local_doctor_finding(
                "untrusted_socket_owner",
                path,
                message.clone(),
            )),
        }
    }
    findings
}

pub(crate) fn daemon_rpc_on_stream(stream: &UnixStream) -> Result<Value, String> {
    stream.set_read_timeout(Some(Duration::from_secs(6))).ok();
    stream.set_write_timeout(Some(Duration::from_secs(6))).ok();
    let mut reader = BufReader::new(stream);
    let response = rpc_call_with_reader(stream, &mut reader, "peer.doctor", json!({}))?;
    if response["error"].is_null() {
        Ok(response["result"].clone())
    } else {
        Err(response["error"]["message"]
            .as_str()
            .unwrap_or("peer.doctor failed")
            .to_string())
    }
}

/// `tm-agent daemon doctor`: report, never repair.
///
/// Probes the whole candidate list rather than stopping at the first live
/// socket the way [`detect_daemon_socket`] does. Which one a client picks is
/// exactly the thing being checked: a host was found running one daemon under
/// systemd and a second, left from a `--help` invocation weeks earlier, still
/// listening on the runtime-dir default. Every client silently chose one of
/// them.
/// Probe every candidate socket once and keep what each one answered.
///
/// Split out of `cmd_daemon_doctor` so the interactive picker diagnoses with
/// exactly the same probe rather than a second, drifting copy of it.
pub(crate) fn collect_doctor_outcomes() -> Vec<(PathBuf, DoctorSocketOutcome)> {
    let expected_uid = doctor_expected_uid();
    let mut outcomes = Vec::new();
    let mut trusted_identities = std::collections::HashSet::new();
    for path in daemon_socket_candidates() {
        let stream = match UnixStream::connect(&path) {
            Ok(stream) => stream,
            Err(error)
                if matches!(
                    error.kind(),
                    ErrorKind::NotFound | ErrorKind::ConnectionRefused
                ) =>
            {
                continue;
            }
            Err(error) => {
                outcomes.push((
                    path,
                    DoctorSocketOutcome::ProbeFailed(format!("connect: {error}")),
                ));
                continue;
            }
        };
        let Some(identity) = doctor_peer_identity(&stream) else {
            outcomes.push((
                path,
                DoctorSocketOutcome::Untrusted(
                    "peer credentials are unavailable; refusing this socket".into(),
                ),
            ));
            continue;
        };
        if !uid_is_trusted(identity.uid, expected_uid) {
            outcomes.push((
                path,
                DoctorSocketOutcome::Untrusted(format!(
                    "socket owner uid {} is neither expected uid {expected_uid} nor root",
                    identity.uid
                )),
            ));
            continue;
        }
        if !trusted_identities.insert(identity) {
            continue;
        }
        let outcome = match daemon_rpc_on_stream(&stream) {
            Ok(result) => match parse_doctor_result(result) {
                Ok(findings) => DoctorSocketOutcome::Report(findings),
                Err(message) => DoctorSocketOutcome::RpcFailed(message),
            },
            Err(message) if message.contains("unknown method") => {
                DoctorSocketOutcome::Unsupported(message)
            }
            Err(message) => DoctorSocketOutcome::RpcFailed(message),
        };
        outcomes.push((path, outcome));
    }
    outcomes
}

pub(crate) fn cmd_daemon_doctor(json: bool) {
    let outcomes = collect_doctor_outcomes();

    if outcomes.is_empty() {
        let report = json!({
            "sockets": [],
            "complete": false,
            "healthy": false,
            "findings": [{
                "code": "no_daemon",
                "severity": "error",
                "detail": "no term-meshd is listening on any known socket path on this host",
                "remedy": "start term-meshd",
                "repair_argv": []
            }]
        });
        if json {
            println!("{}", pretty(&report));
        } else {
            println!("no term-meshd is listening on this host.");
        }
        process::exit(1);
    }
    let findings = aggregate_doctor_findings(&outcomes);
    let exit_code = doctor_exit_code(&outcomes, &findings);
    let complete = doctor_is_complete(&outcomes);
    let healthy = complete && findings.is_empty();
    let sockets = outcomes
        .iter()
        .map(|(path, _)| path.display().to_string())
        .collect::<Vec<_>>();
    if json {
        println!(
            "{}",
            pretty(
                &json!({ "sockets": sockets, "complete": complete, "healthy": healthy,
                            "findings": findings })
            )
        );
    } else if healthy {
        println!("{}: no problems found.", terminal_safe(&sockets.join(", ")));
    } else {
        println!(
            "{} problem(s) across {} socket(s).\n",
            findings.len(),
            sockets.len()
        );
        for finding in &findings {
            let text = |key: &str| terminal_safe(finding[key].as_str().unwrap_or(""));
            let (severity, code) = (text("severity"), text("code"));
            println!("[{severity}] {code}");
            let socket = text("socket");
            if !socket.is_empty() {
                println!("  socket {socket}");
            }
            let project = text("project_id");
            if !project.is_empty() {
                let team = text("team_name");
                println!(
                    "  project {project}{}",
                    if team.is_empty() {
                        String::new()
                    } else {
                        format!(" (team {team})")
                    }
                );
            }
            println!("  {}", text("detail"));
            if let Some(remedy) = human_remedy_line(finding) {
                println!("  fix: {remedy}\n");
            } else {
                println!();
            }
        }
    }
    if exit_code != 0 {
        process::exit(exit_code);
    }
}

/// The `daemon` help clap would have printed for a missing subcommand.
pub(crate) fn daemon_help_text() -> String {
    use clap::CommandFactory;
    let mut command = Cli::command();
    // Without build() the nested command renders its usage as bare `daemon`
    // instead of `tm-agent daemon`.
    command.build();
    command
        .find_subcommand_mut("daemon")
        .map(|daemon| daemon.render_help().to_string())
        .unwrap_or_default()
}

/// `daemon` subcommands whose argv the picker will execute.
///
/// The daemon composes `repair_argv`, so this list is the boundary that keeps
/// a malformed or unexpected report from choosing what runs. Everything else
/// is printed for the operator to run by hand.
pub(crate) const DAEMON_REPAIR_COMMANDS: [&str; 2] = ["project-presentations", "reset"];

/// The runnable argv a finding carries, or None when the picker must not run it.
pub(crate) fn daemon_repair_argv(finding: &Value) -> Option<Vec<String>> {
    let argv = finding["repair_argv"]
        .as_array()?
        .iter()
        .map(|value| value.as_str().map(str::to_string))
        .collect::<Option<Vec<String>>>()?;
    if argv.first().map(String::as_str) != Some("tm-agent")
        || argv.get(1).map(String::as_str) != Some("daemon")
    {
        return None;
    }
    let group = argv.get(2)?;
    if !DAEMON_REPAIR_COMMANDS.contains(&group.as_str()) {
        return None;
    }
    Some(argv)
}

/// The word the applied run needs. Anything else cancels.
pub(crate) const DAEMON_REPAIR_CONFIRM_WORD: &str = "apply";

/// Split one repair into the run that reports and the run that changes things.
///
/// The dry run is the same argv without `--apply`, so what the operator sees
/// is what the applied run repeats. The second element is None when the repair
/// only inspects, and there is then nothing to confirm.
pub(crate) fn daemon_repair_runs(argv: &[String]) -> (Vec<String>, Option<Vec<String>>) {
    let dry_run: Vec<String> = argv
        .iter()
        .filter(|arg| *arg != "--apply")
        .cloned()
        .collect();
    let applied = (dry_run.len() != argv.len()).then(|| argv.to_vec());
    (dry_run, applied)
}

pub(crate) fn daemon_repair_display(argv: &[String]) -> String {
    terminal_safe(&argv.join(" "))
}

/// Run one repair argv by re-entering this same binary.
///
/// Arguments go to the process directly, never through a shell, and the child
/// inherits the terminal so its own report reaches the operator unchanged.
pub(crate) fn run_daemon_repair(argv: &[String]) -> Result<i32, String> {
    let exe = env::current_exe().map_err(|error| format!("cannot locate this binary: {error}"))?;
    let status = process::Command::new(exe)
        .args(&argv[1..])
        .status()
        .map_err(|error| format!("cannot run the repair: {error}"))?;
    Ok(status.code().unwrap_or(1))
}

/// Read one line from the terminal, or None when stdin ends.
pub(crate) fn daemon_prompt_line(prompt: &str) -> Option<String> {
    eprint!("{prompt}");
    std::io::stderr().flush().ok();
    let mut input = String::new();
    match std::io::stdin().read_line(&mut input) {
        Ok(0) | Err(_) => None,
        Ok(_) => Some(input.trim().to_string()),
    }
}

/// `daemon -i` / `daemon doctor -i`: diagnose, then offer each finding's
/// repair as a numbered choice.
///
/// The picker never applies anything on its own. It runs the dry run first,
/// shows what the repair reports, and asks for a typed word before it repeats
/// the command with `--apply`.
pub(crate) fn cmd_daemon_interactive() -> ! {
    // Without this the picker blocks forever in a script, a hook, or an ssh
    // command — the places that call this CLI without a terminal.
    if !std::io::stdin().is_terminal() {
        eprintln!("Error: -i/--interactive needs a terminal on stdin.");
        eprintln!("       Run `tm-agent daemon doctor --json` and act on the findings instead.");
        process::exit(2);
    }

    let outcomes = collect_doctor_outcomes();
    if outcomes.is_empty() {
        println!("no term-meshd is listening on this host.");
        process::exit(1);
    }
    let findings = aggregate_doctor_findings(&outcomes);
    let exit_code = doctor_exit_code(&outcomes, &findings);
    if findings.is_empty() {
        let sockets = outcomes
            .iter()
            .map(|(path, _)| path.display().to_string())
            .collect::<Vec<_>>();
        println!("{}: no problems found.", terminal_safe(&sockets.join(", ")));
        process::exit(exit_code);
    }

    println!("{} problem(s) found.\n", findings.len());
    let mut choices: Vec<Vec<String>> = Vec::new();
    for finding in &findings {
        let text = |key: &str| terminal_safe(finding[key].as_str().unwrap_or(""));
        let argv = daemon_repair_argv(finding);
        let label = match &argv {
            Some(_) => {
                choices.push(argv.clone().expect("checked above"));
                format!("{:>2})", choices.len())
            }
            None => "  -".to_string(),
        };
        println!("{label} [{}] {}", text("severity"), text("code"));
        let project = text("project_id");
        if !project.is_empty() {
            println!("     project {project}");
        }
        println!("     {}", text("detail"));
        match &argv {
            Some(argv) => println!("     fix: {}\n", daemon_repair_display(argv)),
            None => match human_remedy_line(finding) {
                // A finding the daemon did not hand a runnable repair for:
                // report it the way `doctor` does and let the operator act.
                Some(remedy) => println!("     fix (run by hand): {remedy}\n"),
                None => println!(),
            },
        }
    }

    if choices.is_empty() {
        println!("No repair here is runnable from this picker. Act on the findings by hand.");
        process::exit(exit_code);
    }

    let prompt = format!("Select a repair [1-{}] or q to quit: ", choices.len());
    let Some(answer) = daemon_prompt_line(&prompt) else {
        process::exit(exit_code);
    };
    if answer.is_empty() || answer == "q" {
        process::exit(exit_code);
    }
    let Some(argv) = answer
        .parse::<usize>()
        .ok()
        .filter(|choice| (1..=choices.len()).contains(choice))
        .map(|choice| choices[choice - 1].clone())
    else {
        eprintln!(
            "Error: `{}` is not one of the choices.",
            terminal_safe(&answer)
        );
        process::exit(2);
    };

    let (dry_run, applied) = daemon_repair_runs(&argv);
    println!("\n$ {}", daemon_repair_display(&dry_run));
    let code = match run_daemon_repair(&dry_run) {
        Ok(code) => code,
        Err(message) => {
            eprintln!("Error: {message}");
            process::exit(1);
        }
    };
    if code != 0 {
        eprintln!("The dry run failed (exit {code}). Nothing was changed.");
        process::exit(code);
    }
    let Some(applied) = applied else {
        // The daemon offered inspection only, so there is nothing to confirm.
        process::exit(exit_code);
    };

    println!("\nThe run above changed nothing. Applying repeats it with --apply:");
    println!("  {}", daemon_repair_display(&applied));
    let confirmed = daemon_prompt_line(&format!(
        "Type `{DAEMON_REPAIR_CONFIRM_WORD}` to run it, anything else to cancel: "
    ))
    .is_some_and(|answer| answer == DAEMON_REPAIR_CONFIRM_WORD);
    if !confirmed {
        println!("Cancelled. Nothing was changed.");
        process::exit(exit_code);
    }
    println!("\n$ {}", daemon_repair_display(&applied));
    match run_daemon_repair(&applied) {
        Ok(0) => {
            println!("\nRepair applied. Run `tm-agent daemon doctor` again to confirm.");
            process::exit(0);
        }
        Ok(code) => process::exit(code),
        Err(message) => {
            eprintln!("Error: {message}");
            process::exit(1);
        }
    }
}

pub(crate) fn discover_term_mesh_sockets() -> Vec<Value> {
    let patterns = [
        "/tmp/term-mesh-debug-*.sock",
        "/tmp/term-mesh-debug.sock",
        "/tmp/term-mesh*.sock",
        "/tmp/cmux.sock",
    ];
    let mut sockets = Vec::new();
    let mut seen = std::collections::BTreeSet::new();

    for pattern in patterns {
        if let Ok(paths) = glob::glob(pattern) {
            for path in paths.flatten() {
                let display = path.to_string_lossy().to_string();
                if !seen.insert(display.clone()) {
                    continue;
                }
                sockets.push(json!({
                    "path": display,
                    "alive": is_socket_alive(&path),
                }));
            }
        }
    }

    sockets
}

/// What the peer state directory holds, read straight off disk.
///
/// Read from the files rather than asked of the daemon, because the moment
/// someone runs doctor is often the moment no daemon is up. The one fact only
/// a daemon knows is how many of a manifest's surfaces are alive, so that
/// field stays null without one.
pub(crate) fn peer_state_report(daemon_socket: Option<&PathBuf>, live_sockets: usize) -> Value {
    let dir = peer_state_dir();

    // Asking the daemon costs nothing when it is down and gives the liveness
    // column when it is up.
    let live_by_project: std::collections::HashMap<String, u64> = daemon_socket
        // `cmd_daemon_rpc`, not `rpc_call`: this is a daemon-local query with
        // no team context, and `rpc_call` would route it through the remote
        // leader policy and fail.
        .and_then(|sock| cmd_daemon_rpc(sock, "peer.project_presentations.list", json!({})).ok())
        .and_then(|value| value["records"].as_array().cloned())
        .map(|records| {
            records
                .iter()
                .filter_map(|record| {
                    Some((
                        record["project_id"].as_str()?.to_string(),
                        record["live_surfaces"].as_u64().unwrap_or(0),
                    ))
                })
                .collect()
        })
        .unwrap_or_default();

    let mut files = Vec::new();
    let mut projects = Vec::new();
    let mut workspaces = Vec::new();

    for (scope, path) in peer_state_files("all") {
        let present = path.exists();
        let bytes = std::fs::metadata(&path).map(|meta| meta.len()).ok();
        let parsed: Option<Value> = std::fs::read(&path)
            .ok()
            .and_then(|raw| serde_json::from_slice(&raw).ok());
        let records = match (scope, &parsed) {
            ("projects", Some(value)) => value["records"].as_array().map(|r| r.len()),
            ("workspaces", Some(value)) => value.as_array().map(|r| r.len()),
            _ => None,
        };
        files.push(json!({
            "scope": scope,
            "path": path.display().to_string(),
            "present": present,
            "bytes": bytes,
            // Distinguishes "no file" from "a file that will not load" — the
            // loaders treat both as empty, so only this tells them apart.
            "parsed": if present { Some(parsed.is_some()) } else { None },
            "records": records,
        }));

        match (scope, parsed) {
            ("projects", Some(value)) => {
                for record in value["records"].as_array().cloned().unwrap_or_default() {
                    let project_id = record["project_id"]
                        .as_str()
                        .unwrap_or_default()
                        .to_string();
                    let working_directory = record["working_directory"]
                        .as_str()
                        .unwrap_or_default()
                        .to_string();
                    projects.push(json!({
                        "team_name": record["team_name"],
                        "project_id": project_id.clone(),
                        "working_directory": working_directory.clone(),
                        "leader_surface_id": record["leader_surface_id"],
                        "directory_present": !working_directory.is_empty()
                            && std::path::Path::new(&working_directory).is_dir(),
                        "live_surfaces": live_by_project.get(&project_id),
                    }));
                }
            }
            ("workspaces", Some(value)) => {
                for entry in value.as_array().cloned().unwrap_or_default() {
                    workspaces.push(json!({
                        "id": entry["id"],
                        "name": entry["name"],
                        "is_default": entry["is_default"],
                    }));
                }
            }
            _ => {}
        }
    }

    // Taking it exclusively for an instant is the only way to learn whether a
    // daemon holds it shared. Dropped immediately; a daemon that boots while
    // we hold it logs a warning and carries on.
    let lock_error = match try_lock_peer_state_dir(&dir) {
        Ok(lock) => {
            drop(lock);
            None
        }
        Err(error) => Some(error),
    };
    // The lock alone is not enough. A daemon built before the lock existed
    // never takes it, yet still saves a full snapshot over anything written
    // here — so a live socket has to count as ownership too.
    let reset_blocked_by = match (lock_error, live_sockets) {
        (Some(error), _) => Some(format!(
            "a running term-meshd holds the state lock ({error})"
        )),
        (None, 0) => None,
        (None, count) => Some(format!(
            "{count} live term-mesh socket(s): a daemon that predates the state \
             lock does not take it and would save over this"
        )),
    };

    json!({
        "directory": dir.display().to_string(),
        "reset_safe": reset_blocked_by.is_none(),
        "reset_blocked_by": reset_blocked_by,
        "files": files,
        "projects": projects,
        "workspaces": workspaces,
    })
}

pub(crate) fn cmd_doctor(verbose: bool, json_output: bool) {
    let app_socket = detect_socket();
    let daemon_socket = detect_daemon_socket();
    let sockets = discover_term_mesh_sockets();
    let team = resolve_team_name(None);
    let agent = env::var("TERMMESH_AGENT_NAME").unwrap_or_else(|_| "anonymous".into());

    let app_status = app_socket
        .as_ref()
        .and_then(|sock| rpc_call(sock, "team.status", json!({ "team_name": &team })).ok());
    let daemon_status = daemon_socket
        .as_ref()
        .and_then(|sock| rpc_call(sock, "daemon.status", json!({})).ok());

    // `discover_term_mesh_sockets` globs /tmp, which is where a Mac keeps its
    // sockets. A Linux peer host puts them under the systemd RuntimeDirectory
    // (/run/term-mesh), so counting only the glob's hits reports zero owners on
    // exactly the hosts this reset targets. Fold in the two resolved paths.
    let mut owner_paths: std::collections::BTreeSet<String> = sockets
        .iter()
        .filter(|socket| socket["alive"].as_bool().unwrap_or(false))
        .filter_map(|socket| socket["path"].as_str().map(str::to_string))
        .collect();
    for candidate in [daemon_socket.as_ref(), app_socket.as_ref()]
        .into_iter()
        .flatten()
    {
        if is_socket_alive(candidate) {
            owner_paths.insert(candidate.to_string_lossy().to_string());
        }
    }
    let live_sockets = owner_paths.len();
    // Same fallback `daemon project-presentations` uses: the peer host answers
    // on whichever of the two sockets this machine actually exposes.
    let peer_rpc_socket = daemon_socket.as_ref().or(app_socket.as_ref());
    let peer_state = peer_state_report(peer_rpc_socket, live_sockets);

    let result = json!({
        "ok": app_socket.is_some() || daemon_socket.is_some(),
        "team": team,
        "agent": agent,
        "app_socket": app_socket.as_ref().map(|p| p.to_string_lossy().to_string()),
        "daemon_socket": daemon_socket.as_ref().map(|p| p.to_string_lossy().to_string()),
        "app_status": app_status,
        "daemon_status": daemon_status,
        "sockets": if verbose { Value::Array(sockets.clone()) } else { json!(sockets.iter().filter(|s| s["alive"].as_bool().unwrap_or(false)).count()) },
        "peer_state": peer_state,
    });

    if json_output {
        println!("{}", pretty(&result));
        return;
    }

    println!("tm-agent doctor");
    println!("team: {}", result["team"].as_str().unwrap_or("unknown"));
    println!("agent: {}", result["agent"].as_str().unwrap_or("unknown"));
    println!(
        "app socket: {}",
        result["app_socket"].as_str().unwrap_or("not found")
    );
    println!(
        "daemon socket: {}",
        result["daemon_socket"].as_str().unwrap_or("not found")
    );
    if verbose {
        println!("sockets:");
        for socket in sockets {
            println!(
                "  {} {}",
                if socket["alive"].as_bool().unwrap_or(false) {
                    "alive"
                } else {
                    "dead"
                },
                socket["path"].as_str().unwrap_or("")
            );
        }
    } else {
        println!("alive sockets: {}", result["sockets"].as_u64().unwrap_or(0));
    }

    println!(
        "peer state: {}",
        peer_state["directory"].as_str().unwrap_or("?")
    );
    for file in peer_state["files"].as_array().cloned().unwrap_or_default() {
        let scope = file["scope"].as_str().unwrap_or("?");
        if !file["present"].as_bool().unwrap_or(false) {
            println!("  {scope}: absent");
            continue;
        }
        // A file that will not parse loads as empty, silently. Say so.
        if file["parsed"].as_bool() == Some(false) {
            println!("  {scope}: UNREADABLE (loads as empty)");
            continue;
        }
        println!(
            "  {scope}: {} record(s)",
            file["records"].as_u64().unwrap_or(0)
        );
    }
    for project in peer_state["projects"]
        .as_array()
        .cloned()
        .unwrap_or_default()
    {
        let live = match project["live_surfaces"].as_u64() {
            Some(count) => format!("{count} live surface(s)"),
            None => "liveness unknown (no daemon)".to_string(),
        };
        println!(
            "    project {} [{}] dir={} {}{}",
            project["team_name"].as_str().unwrap_or("?"),
            project["project_id"].as_str().unwrap_or("?"),
            project["working_directory"].as_str().unwrap_or("?"),
            live,
            if project["directory_present"].as_bool().unwrap_or(false) {
                ""
            } else {
                " (directory gone)"
            }
        );
    }
    for workspace in peer_state["workspaces"]
        .as_array()
        .cloned()
        .unwrap_or_default()
    {
        println!(
            "    workspace {}{}",
            workspace["name"].as_str().unwrap_or("?"),
            if workspace["is_default"].as_bool().unwrap_or(false) {
                " (default)"
            } else {
                ""
            }
        );
    }
    match peer_state["reset_blocked_by"].as_str() {
        Some(reason) => println!("  reset: unsafe — {reason}"),
        None => println!("  reset: safe (no daemon holds this directory)"),
    }

    println!(
        "status: {}",
        if result["ok"].as_bool().unwrap_or(false) {
            "ok"
        } else {
            "no live sockets found"
        }
    );
}

#[cfg(test)]
mod version_skew_tests {
    use super::version_skew_note;

    /// The case that cost an afternoon: a 0.167.0 CLI driving a 0.170.x app
    /// answered every leader command with `noMatchingLeaderSession`, a name
    /// that exists nowhere in the current tree. The note has to name both
    /// builds, or it explains nothing.
    #[test]
    fn different_builds_name_both_versions() {
        let note = version_skew_note("abc123456", "def987654", "0.167.0", "0.170.1")
            .expect("mismatched builds must produce a note");
        assert!(note.contains("0.167.0"), "{note}");
        assert!(note.contains("0.170.1"), "{note}");
        assert!(
            note.contains("abc123456") && note.contains("def987654"),
            "{note}"
        );
        // The actionable half: which binary is actually running.
        assert!(note.contains("command -v tm-agent"), "{note}");
    }

    #[test]
    fn matching_builds_say_nothing() {
        assert_eq!(
            version_skew_note("abc123456", "abc123456", "0.170.1", "0.170.1"),
            None
        );
    }

    /// An app that reports no SHA is unknown, not skewed. Printing a version
    /// warning under every unrelated failure would train people to ignore it.
    #[test]
    fn an_unknown_app_build_is_not_a_mismatch() {
        assert_eq!(
            version_skew_note("abc123456", "", "0.170.1", "unknown"),
            None
        );
    }
}

#[cfg(all(test, unix))]
mod backup_create_new_tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn a_backup_never_writes_through_a_planted_symlink() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("peer-workspaces.json");
        std::fs::write(&state, "state").unwrap();
        std::fs::set_permissions(&state, std::fs::Permissions::from_mode(0o600)).unwrap();
        let victim = dir.path().join("victim");
        std::fs::write(&victim, "keep").unwrap();
        let planted = dir.path().join("peer-workspaces.42.bak.json");
        std::os::unix::fs::symlink(&victim, &planted).unwrap();

        let backup = backup_peer_state_file_at(&state, 42).unwrap().unwrap();

        assert_eq!(
            backup,
            dir.path()
                .join("peer-workspaces.42-1.bak.json")
                .display()
                .to_string()
        );
        assert_eq!(std::fs::read_to_string(&victim).unwrap(), "keep");
        assert!(std::fs::symlink_metadata(&planted)
            .unwrap()
            .file_type()
            .is_symlink());
        assert_eq!(std::fs::read_to_string(&backup).unwrap(), "state");
        let mode = std::fs::metadata(&backup).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    /// A link to a path that does not exist yet passes an `exists()` check,
    /// the same window a link planted after the check opens.
    #[test]
    fn a_backup_never_creates_the_target_of_a_dangling_symlink() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("peer-workspaces.json");
        std::fs::write(&state, "state").unwrap();
        let victim = dir.path().join("victim");
        let planted = dir.path().join("peer-workspaces.42.bak.json");
        std::os::unix::fs::symlink(&victim, &planted).unwrap();

        let backup = backup_peer_state_file_at(&state, 42).unwrap().unwrap();

        assert_eq!(
            backup,
            dir.path()
                .join("peer-workspaces.42-1.bak.json")
                .display()
                .to_string()
        );
        assert!(
            !victim.exists(),
            "the backup was written through the planted link"
        );
        assert_eq!(std::fs::read_to_string(&backup).unwrap(), "state");
    }

    #[test]
    fn a_failed_copy_leaves_no_partial_backup() {
        let dir = tempfile::tempdir().unwrap();
        let state = dir.path().join("peer-workspaces.json");
        std::fs::write(&state, "state").unwrap();
        std::fs::set_permissions(&state, std::fs::Permissions::from_mode(0o000)).unwrap();
        if std::fs::File::open(&state).is_ok() {
            return; // running as root: mode 000 does not stop the read
        }

        assert!(backup_peer_state_file_at(&state, 42).is_err());

        let left: Vec<_> = std::fs::read_dir(dir.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert_eq!(left, vec![std::ffi::OsString::from("peer-workspaces.json")]);
    }

    #[test]
    fn a_missing_state_file_has_nothing_to_back_up() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(
            backup_peer_state_file_at(&dir.path().join("peer-workspaces.json"), 42).unwrap(),
            None
        );
    }
}
