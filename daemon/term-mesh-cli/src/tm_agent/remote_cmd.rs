use super::*;

// ── `tm-agent remote` (docs/mobile-remote-control.md §4.2) ─────────────

/// Run one `remote` subcommand against the daemon control socket.
pub(crate) fn run_remote_command(sock: &PathBuf, team_flag: Option<&str>, cmd: &RemoteCommand) {
    match cmd {
        RemoteCommand::On {
            keys,
            ttl,
            surface,
            leader,
            agent,
            terminal,
            app_socket,
            cli,
            title,
            json,
        } => {
            let env_agent = env::var("TERMMESH_AGENT_NAME").ok();
            let agent_name = remote_agent_target(
                agent.as_deref(),
                env_agent.as_deref(),
                *leader || surface.is_some(),
                *terminal,
            )
            .unwrap_or_else(|e| {
                eprintln!("Error: {e}");
                process::exit(1);
            });
            if let Some(agent_name) = agent_name {
                run_remote_on_agent(
                    sock,
                    team_flag,
                    &agent_name,
                    *terminal,
                    keys,
                    ttl.as_deref(),
                    title.as_deref(),
                    *json,
                );
                return;
            }
            let surface_id = resolve_remote_surface(surface.as_deref()).unwrap_or_else(|e| {
                // A native agent pane has no terminal surface, so `--terminal`
                // there cannot mean anything.
                if *terminal && env_agent.as_deref().is_some_and(|a| !a.trim().is_empty()) {
                    eprintln!("Error: this agent pane has no terminal to mirror; run without --terminal to expose it as a chat");
                } else {
                    eprintln!("Error: {e}");
                }
                process::exit(1);
            });
            let ttl_secs = match ttl.as_deref().map(parse_ttl_secs).transpose() {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("Error: {e}");
                    process::exit(1);
                }
            };
            let is_leader = *leader || remote_pane_is_leader();
            let team_name = is_leader.then(|| resolve_team_name(team_flag));
            let app_socket = app_socket
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .or_else(resolve_remote_app_socket);
            // No app socket means no app owns this surface: a peer host's pane
            // or a headless one, where the daemon that injected the surface id
            // owns the PTY itself. Its own listener reads those surfaces, so
            // the exposure goes in with `app_socket` unset instead of being
            // refused. A pane the app owns always carries both variables
            // (`GhosttyTerminalView` writes them together).
            let cwd = env::current_dir()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default();
            let title = title
                .clone()
                .filter(|t| !t.trim().is_empty())
                .unwrap_or_else(|| remote_default_title(&cwd));
            let agent_cli = cli.clone().unwrap_or_else(detect_remote_cli);
            let session_id = (!*terminal)
                .then(|| remote_session_id(&agent_cli))
                .flatten();
            let mut params = json!({
                "surface_id": surface_id,
                "kind": if is_leader { "leader" } else { "pane" },
                "keys": keys,
                "app_socket": app_socket,
                "agent_cli": agent_cli,
                "chat_capable": session_id.is_some(),
                "session_id": session_id,
                "title": title,
                "cwd": cwd,
                "owner": env::var("USER").ok(),
            });
            if let Some(team) = &team_name {
                params["team_name"] = json!(team);
            }
            if let Some(ttl) = ttl_secs {
                params["ttl_secs"] = json!(ttl);
            }
            if is_leader {
                // The durable board's list RPC needs the leader pane's capability
                // token; only the daemon ever sees it.
                if let Some(token) = env::var("TERMMESH_LEADER_REQUEST_TOKEN")
                    .ok()
                    .map(|t| t.trim().to_string())
                    .filter(|t| !t.is_empty())
                {
                    params["leader_request_token"] = json!(token);
                }
            }
            let result = remote_rpc(sock, "remote.on", params);
            if *json {
                println!("{}", pretty(&result));
                return;
            }
            let entry = &result["entry"];
            println!(
                "exposed {} ({}, keys={}{})",
                entry["surface_id"].as_str().unwrap_or(&surface_id),
                entry["kind"].as_str().unwrap_or("pane"),
                entry["keys"].as_str().unwrap_or(keys),
                team_name
                    .as_deref()
                    .map(|t| format!(", team={t}"))
                    .unwrap_or_default()
            );
            match result["url"].as_str() {
                Some(url) => {
                    println!("url: {url}");
                    for line in remote_tailnet_lines(url, &surface_id) {
                        println!("{line}");
                    }
                }
                None => println!(
                    "url: unavailable ({})",
                    result["listener_error"]
                        .as_str()
                        .unwrap_or("listener address invalid")
                ),
            }
            if let Some(exp) = entry["expires_at"].as_u64() {
                println!("expires: in {} (unix {exp})", format_remote_relative(exp));
            }
            if result["listener_enabled"].as_bool() != Some(true) {
                eprintln!(
                    "note: the mobile listener is disabled on this daemon; enable it in \
                     Settings or set TERM_MESH_MOBILE_ENABLED=1 before the daemon starts"
                );
            }
            if !is_leader && !*terminal {
                if entry["chat_capable"].as_bool() == Some(true) {
                    eprintln!(
                        "note: the mobile page can switch this target between Chat and Terminal"
                    );
                } else {
                    eprintln!("note: terminal mirror only; no supported Claude/Codex session id was found");
                }
            }
        }
        RemoteCommand::Off { surface, json } => {
            let surface_id = resolve_remote_surface(surface.as_deref()).unwrap_or_else(|e| {
                eprintln!("Error: {e}");
                process::exit(1);
            });
            let result = remote_rpc(sock, "remote.off", json!({ "surface_id": surface_id }));
            if *json {
                println!("{}", pretty(&result));
                return;
            }
            if result["removed"].as_bool() == Some(true) {
                println!("no longer exposed: {surface_id}");
            } else {
                println!("was not exposed: {surface_id}");
            }
        }
        RemoteCommand::Status { surface, all, json } => {
            let params = if *all {
                json!({})
            } else {
                let surface_id = resolve_remote_surface(surface.as_deref()).unwrap_or_else(|e| {
                    eprintln!("Error: {e}");
                    process::exit(1);
                });
                json!({ "surface_id": surface_id })
            };
            let result = remote_rpc(sock, "remote.status", params);
            if *json {
                println!("{}", pretty(&result));
                return;
            }
            let listener = if result["listener_enabled"].as_bool() == Some(true) {
                "enabled".to_string()
            } else {
                "disabled".to_string()
            };
            if *all {
                let entries = result["entries"].as_array().cloned().unwrap_or_default();
                println!("listener: {listener}; exposed surfaces: {}", entries.len());
                for e in entries {
                    println!(
                        "  {}  {}  keys={}  {}",
                        e["surface_id"].as_str().unwrap_or("?"),
                        e["kind"].as_str().unwrap_or("?"),
                        e["keys"].as_str().unwrap_or("?"),
                        e["title"].as_str().unwrap_or("")
                    );
                }
            } else if result["exposed"].as_bool() == Some(true) {
                let e = &result["entry"];
                println!(
                    "exposed: {} ({}, keys={})",
                    result["surface_id"].as_str().unwrap_or("?"),
                    e["kind"].as_str().unwrap_or("?"),
                    e["keys"].as_str().unwrap_or("?")
                );
                if let Some(url) = result["url"].as_str() {
                    println!("url: {url}");
                    let sid = result["surface_id"].as_str().unwrap_or("");
                    for line in remote_tailnet_lines(url, sid) {
                        println!("{line}");
                    }
                }
                if let Some(exp) = e["expires_at"].as_u64() {
                    println!("expires: in {} (unix {exp})", format_remote_relative(exp));
                }
                println!("listener: {listener}");
            } else {
                println!(
                    "not exposed: {} (listener {listener})",
                    result["surface_id"].as_str().unwrap_or("?")
                );
            }
        }
    }
}

/// `tm-agent remote on [--agent <name>]`: expose a team agent's pane as a
/// chat target. The pane is found through the app's `team.status` (panel_id,
/// cli), registered with `kind=agent`, and served from its structured
/// transcript. `terminal` registers the pane as a screen mirror instead.
pub(crate) fn run_remote_on_agent(
    sock: &PathBuf,
    team_flag: Option<&str>,
    agent_name: &str,
    terminal: bool,
    keys: &str,
    ttl: Option<&str>,
    title: Option<&str>,
    json: bool,
) {
    let team_name = resolve_team_name(team_flag);
    let Some(app_sock) = detect_socket() else {
        eprintln!(
            "Error: no term-mesh app socket found to look up the agent (TERMMESH_SOCKET_PATH)"
        );
        process::exit(1);
    };
    let status = match rpc_call(&app_sock, "team.status", json!({ "team_name": team_name })) {
        Ok(resp) if resp.get("error").is_none() => resp["result"].clone(),
        Ok(resp) => {
            eprintln!(
                "Error: team.status: {}",
                resp["error"]["message"].as_str().unwrap_or("rpc error")
            );
            process::exit(1);
        }
        Err(e) => {
            eprintln!("Error: team.status: {e}");
            process::exit(1);
        }
    };
    let agent = status["agents"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|a| {
            a["agent_name"].as_str() == Some(agent_name) || a["name"].as_str() == Some(agent_name)
        })
        .cloned();
    let Some(agent) = agent else {
        eprintln!("Error: agent {agent_name:?} is not in team {team_name:?}");
        process::exit(1);
    };
    let Some(panel_id) = agent["panel_id"].as_str().filter(|p| !p.is_empty()) else {
        eprintln!(
            "Error: agent {agent_name:?} has no pane (headless agents cannot be exposed yet)"
        );
        process::exit(1);
    };
    // Which view: a native pane has a structured transcript (chat); a
    // terminal-mode agent pane only has a screen (mirror). `team.status`
    // does not say which, so ask for one transcript entry unless the caller
    // forced the mirror.
    let kind = if terminal {
        "pane"
    } else {
        let probe = rpc_call(
            &app_sock,
            "team.agent.transcript",
            json!({ "team_name": team_name, "agent_name": agent_name, "limit": 1 }),
        );
        match probe {
            Ok(resp) if resp.get("error").is_none() => "agent",
            Ok(resp) if resp["error"]["code"].as_str() == Some("not_native") => "pane",
            Ok(resp) => {
                eprintln!(
                    "Error: team.agent.transcript: {}",
                    resp["error"]["message"].as_str().unwrap_or("rpc error")
                );
                process::exit(1);
            }
            Err(e) => {
                eprintln!("Error: team.agent.transcript: {e}");
                process::exit(1);
            }
        }
    };
    let session_id = agent["session_id"]
        .as_str()
        .map(str::to_string)
        .or_else(|| {
            let this_agent = env::var("TERMMESH_AGENT_NAME").ok();
            (this_agent.as_deref().map(str::trim) == Some(agent_name))
                .then(|| remote_session_id(agent["cli"].as_str().unwrap_or("")))
                .flatten()
        });
    let ttl_secs = match ttl.map(parse_ttl_secs).transpose() {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Error: {e}");
            process::exit(1);
        }
    };
    let mut params = json!({
        "surface_id": panel_id,
        "kind": kind,
        "team_name": team_name,
        "agent_name": agent_name,
        "keys": keys,
        "app_socket": app_sock.to_string_lossy(),
        "agent_cli": agent["cli"].as_str().unwrap_or(""),
        "chat_capable": kind == "agent" || session_id.is_some(),
        "session_id": session_id,
        "title": title.unwrap_or(agent_name),
        "cwd": agent["working_directory"]
            .as_str()
            .map(str::to_string)
            .unwrap_or_else(|| env::current_dir().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default()),
        "owner": env::var("USER").ok(),
    });
    if let Some(ttl) = ttl_secs {
        params["ttl_secs"] = json!(ttl);
    }
    let result = remote_rpc(sock, "remote.on", params);
    if json {
        println!("{}", pretty(&result));
        return;
    }
    if kind == "agent" {
        println!("exposed agent {agent_name} of {team_name} as chat (native pane)");
    } else if terminal {
        println!("exposed agent {agent_name} of {team_name} as terminal mirror (--terminal, keys={keys})");
    } else {
        println!("exposed agent {agent_name} of {team_name} as terminal mirror (pane is not native, keys={keys})");
    }
    match result["url"].as_str() {
        Some(url) => {
            println!("url: {url}");
            for line in remote_tailnet_lines(url, panel_id) {
                println!("{line}");
            }
        }
        None => println!(
            "url: unavailable ({})",
            result["listener_error"]
                .as_str()
                .unwrap_or("listener address invalid")
        ),
    }
    if let Some(exp) = result["entry"]["expires_at"].as_u64() {
        println!("expires: in {} (unix {exp})", format_remote_relative(exp));
    }
    if result["listener_enabled"].as_bool() != Some(true) {
        eprintln!(
            "note: the mobile listener is disabled on this daemon; enable it in Settings first"
        );
    }
}

/// One `remote.*` RPC; any failure is fatal for the command.
pub(crate) fn remote_rpc(sock: &PathBuf, method: &str, params: Value) -> Value {
    match rpc_call(sock, method, params) {
        Ok(resp) => {
            if let Some(err) = resp.get("error") {
                let msg = err["message"].as_str().unwrap_or("rpc error");
                eprintln!("Error: {method}: {msg}");
                process::exit(1);
            }
            resp.get("result").cloned().unwrap_or(Value::Null)
        }
        Err(e) => {
            eprintln!("Error: {method}: {e}");
            process::exit(1);
        }
    }
}

/// `--surface` wins; otherwise the pane's own `TERMMESH_SURFACE_ID`.
pub(crate) fn resolve_remote_surface(explicit: Option<&str>) -> Result<String, String> {
    remote_surface_from(
        explicit,
        env::var("TERMMESH_SURFACE_ID").ok().as_deref(),
        is_claude_background_session(&|name| env::var(name).ok()),
    )
}

/// In a Claude background session the inherited surface is another session's
/// pane ([`is_claude_background_session`]); exposing it would route mobile
/// input to that session.
pub(crate) fn remote_surface_from(
    explicit: Option<&str>,
    env_value: Option<&str>,
    background: bool,
) -> Result<String, String> {
    if let Some(s) = explicit.map(str::trim).filter(|s| !s.is_empty()) {
        return Ok(s.to_string());
    }
    if background {
        return Err(
            "this is a Claude background session: it has no term-mesh pane, and \
             $TERMMESH_SURFACE_ID belongs to another session's pane. Run /rc in the pane \
             that shows this session; pass --surface only with that pane's id, never \
             $TERMMESH_SURFACE_ID"
                .to_string(),
        );
    }
    env_value
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .ok_or_else(|| {
            "no surface id: run inside a term-mesh pane (TERMMESH_SURFACE_ID) or pass --surface <id>"
                .to_string()
        })
}

/// The app socket that owns this pane. `TERMMESH_SOCKET_PATH` is what the app
/// injects into every pane; `TERMMESH_SOCKET` counts only when it is an app
/// socket (agent panes get it too, but daemon-spawned panes get the daemon's).
pub(crate) fn resolve_remote_app_socket() -> Option<String> {
    remote_app_socket_from(
        env::var("TERMMESH_SOCKET_PATH").ok().as_deref(),
        env::var("TERMMESH_SOCKET").ok().as_deref(),
    )
}

pub(crate) fn remote_app_socket_from(
    socket_path: Option<&str>,
    socket: Option<&str>,
) -> Option<String> {
    let absolute = |s: &str| {
        let s = s.trim();
        (!s.is_empty() && s.starts_with('/')).then(|| s.to_string())
    };
    if let Some(p) = socket_path.and_then(absolute) {
        return Some(p);
    }
    socket
        .and_then(absolute)
        .filter(|p| is_app_socket_path(Path::new(p)))
}

/// A leader pane the app launched carries `TERMMESH_LEADER_REQUEST_TOKEN` and
/// no `TERMMESH_AGENT_NAME` (workers get the latter). Adopted leaders have
/// neither and must pass `--leader`.
/// Which agent `remote on` exposes as a chat, or `None` for this pane's own
/// surface. `--agent NAME` names one; a bare `--agent` and the default both
/// take the pane's own agent name, so an agent exposes itself without naming
/// itself. `pane_flow` (`--leader` or `--surface`) and `--terminal` without a
/// name keep the surface flow, which needs no team lookup.
pub(crate) fn remote_agent_target(
    flag: Option<&str>,
    env_agent: Option<&str>,
    pane_flow: bool,
    terminal: bool,
) -> Result<Option<String>, String> {
    let env_agent = env_agent.map(str::trim).filter(|a| !a.is_empty());
    match flag.map(str::trim) {
        Some(name) if !name.is_empty() => Ok(Some(name.to_string())),
        Some(_) => env_agent.map(|a| Some(a.to_string())).ok_or_else(|| {
            "no agent name: pass --agent <name>, or run inside a team agent pane \
             (TERMMESH_AGENT_NAME)"
                .to_string()
        }),
        None if pane_flow || terminal => Ok(None),
        None => Ok(env_agent.map(str::to_string)),
    }
}

pub(crate) fn remote_pane_is_leader() -> bool {
    remote_leader_from(
        env::var("TERMMESH_LEADER_REQUEST_TOKEN").ok().as_deref(),
        env::var("TERMMESH_AGENT_NAME").ok().as_deref(),
    )
}

pub(crate) fn remote_leader_from(leader_token: Option<&str>, agent_name: Option<&str>) -> bool {
    let has_token = leader_token.map(str::trim).is_some_and(|t| !t.is_empty());
    let is_worker = agent_name.map(str::trim).is_some_and(|a| !a.is_empty());
    has_token && !is_worker
}

/// Best-effort label for the page. Claude Code exports `CLAUDECODE` into the
/// shells it runs; Codex marks its sandboxed commands. Unknown stays empty
/// rather than guessing.
pub(crate) fn detect_remote_cli() -> String {
    let set = |k: &str| env::var(k).map(|v| !v.trim().is_empty()).unwrap_or(false);
    if set("CLAUDECODE") {
        "claude".into()
    } else if set("CODEX_SANDBOX")
        || set("CODEX_SANDBOX_NETWORK_DISABLED")
        || set("CODEX_SESSION_ID")
        || set("CODEX_THREAD_ID")
    {
        "codex".into()
    } else {
        String::new()
    }
}

pub(crate) fn remote_session_id(cli: &str) -> Option<String> {
    remote_session_id_from(cli, |key| env::var(key).ok())
}

pub(crate) fn remote_session_id_from<F>(cli: &str, mut get: F) -> Option<String>
where
    F: FnMut(&str) -> Option<String>,
{
    let keys: &[&str] = match cli {
        // CODEX_SESSION_ID can describe the parent shell while THREAD_ID is
        // the active conversation whose rollout the mobile page must follow.
        "codex" => &["CODEX_THREAD_ID", "CODEX_SESSION_ID"],
        "claude" => &["CLAUDE_CODE_SESSION_ID"],
        _ => &[],
    };
    keys.iter().find_map(|key| {
        get(key)
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
    })
}

pub(crate) fn remote_default_title(cwd: &str) -> String {
    Path::new(cwd)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| "pane".to_string())
}

/// `12h`, `30m`, `2d`, `90s`, or plain seconds.
pub(crate) fn parse_ttl_secs(raw: &str) -> Result<u64, String> {
    let s = raw.trim();
    if s.is_empty() {
        return Err("ttl is empty".into());
    }
    let (digits, unit) = match s.char_indices().find(|(_, c)| !c.is_ascii_digit()) {
        Some((i, _)) => (&s[..i], s[i..].trim()),
        None => (s, ""),
    };
    let n: u64 = digits
        .parse()
        .map_err(|_| format!("ttl {raw:?} must be a number with an optional s/m/h/d suffix"))?;
    let mult = match unit {
        "" | "s" | "sec" | "secs" => 1,
        "m" | "min" | "mins" => 60,
        "h" | "hr" | "hrs" => 3600,
        "d" | "day" | "days" => 86_400,
        _ => {
            return Err(format!(
                "ttl {raw:?}: unknown unit {unit:?} (use s, m, h, d)"
            ))
        }
    };
    n.checked_mul(mult)
        .ok_or_else(|| format!("ttl {raw:?} is too large"))
}

/// What Tailscale Serve says about the mobile listener (Phase 2,
/// docs/mobile-remote-control.md §9). Read-only: `tailscale serve status --json`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TailnetServe {
    /// `https://<host>[:port][/path]` proxies to the listener. `funnel` means
    /// the same host is also published to the public internet, which the
    /// mobile listener refuses to serve (no identity header).
    Served { base: String, funnel: bool },
    /// Tailscale answered, but nothing proxies to the listener.
    NotServed,
}

/// `127.0.0.1:9877` out of `http://127.0.0.1:9877/t/<id>`.
pub(crate) fn listener_addr_from_url(url: &str) -> Option<String> {
    let rest = url.strip_prefix("http://")?;
    let host_port = rest.split('/').next()?;
    (!host_port.is_empty()).then(|| host_port.to_string())
}

/// Parse `tailscale serve status --json`. The shape is Tailscale's
/// `ipn.ServeConfig`: `Web` maps `host:port` to `{Handlers: {path: {Proxy}}}`
/// and `AllowFunnel` maps the same `host:port` keys to booleans.
pub(crate) fn parse_serve_status(status: &Value, listener_addr: &str) -> TailnetServe {
    let listener_port = listener_addr.rsplit(':').next().unwrap_or("");
    let proxies_listener = |proxy: &str| {
        let target = proxy
            .strip_prefix("http://")
            .or_else(|| proxy.strip_prefix("https://"))
            .unwrap_or(proxy);
        let target = target.trim_end_matches('/');
        let (host, port) = match target.rsplit_once(':') {
            Some((h, p)) => (h, p),
            None => (target, ""),
        };
        matches!(host, "127.0.0.1" | "localhost" | "[::1]" | "::1") && port == listener_port
    };
    let Some(web) = status.get("Web").and_then(Value::as_object) else {
        return TailnetServe::NotServed;
    };
    for (host_port, site) in web {
        let Some(handlers) = site.get("Handlers").and_then(Value::as_object) else {
            continue;
        };
        for (path, handler) in handlers {
            let Some(proxy) = handler.get("Proxy").and_then(Value::as_str) else {
                continue;
            };
            if !proxies_listener(proxy) {
                continue;
            }
            let (host, port) = host_port
                .rsplit_once(':')
                .unwrap_or((host_port.as_str(), "443"));
            let mut base = format!("https://{host}");
            if port != "443" {
                base.push(':');
                base.push_str(port);
            }
            let mount = path.trim_end_matches('/');
            if !mount.is_empty() {
                base.push_str(mount);
            }
            let funnel = status
                .get("AllowFunnel")
                .and_then(|f| f.get(host_port))
                .and_then(Value::as_bool)
                .unwrap_or(false);
            return TailnetServe::Served { base, funnel };
        }
    }
    TailnetServe::NotServed
}

pub(crate) fn tailscale_binary() -> Option<PathBuf> {
    if let Ok(path_var) = env::var("PATH") {
        for dir in path_var.split(':').filter(|d| !d.is_empty()) {
            let candidate = Path::new(dir).join("tailscale");
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    let app = PathBuf::from("/Applications/Tailscale.app/Contents/MacOS/Tailscale");
    app.is_file().then_some(app)
}

pub(crate) fn tailscale_serve_status() -> Option<Value> {
    let bin = tailscale_binary()?;
    let out = std::process::Command::new(bin)
        .args(["serve", "status", "--json"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    serde_json::from_slice(&out.stdout).ok()
}

/// Human lines for the tailnet side of a loopback listener URL. Empty when
/// Tailscale is absent or does not answer: the loopback URL is still right.
pub(crate) fn remote_tailnet_lines(listener_url: &str, surface_id: &str) -> Vec<String> {
    let Some(addr) = listener_addr_from_url(listener_url) else {
        return Vec::new();
    };
    let Some(status) = tailscale_serve_status() else {
        return Vec::new();
    };
    tailnet_lines_for(&parse_serve_status(&status, &addr), &addr, surface_id)
}

pub(crate) fn tailnet_lines_for(
    serve: &TailnetServe,
    listener_addr: &str,
    surface_id: &str,
) -> Vec<String> {
    match serve {
        TailnetServe::Served { base, funnel } => {
            let mut lines = vec![format!("tailnet: {base}/t/{surface_id}")];
            if *funnel {
                lines.push(
                    "warning: Funnel is enabled for this host; the listener refuses public \
                     requests (no Tailscale identity). Run: tailscale funnel off"
                        .to_string(),
                );
            }
            lines
        }
        TailnetServe::NotServed => {
            let port = listener_addr.rsplit(':').next().unwrap_or("9877");
            vec![format!(
                "tailnet: not served yet; on this Mac run: tailscale serve --bg {port}"
            )]
        }
    }
}

pub(crate) fn format_remote_relative(expires_at: u64) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let left = expires_at.saturating_sub(now);
    if left >= 86_400 {
        format!("{}d {}h", left / 86_400, (left % 86_400) / 3600)
    } else if left >= 3600 {
        format!("{}h {}m", left / 3600, (left % 3600) / 60)
    } else {
        format!("{}m", left / 60)
    }
}

#[cfg(test)]
mod remote_command_tests {
    use super::*;

    #[test]
    fn ttl_accepts_units_and_plain_seconds() {
        assert_eq!(parse_ttl_secs("90").unwrap(), 90);
        assert_eq!(parse_ttl_secs("90s").unwrap(), 90);
        assert_eq!(parse_ttl_secs("30m").unwrap(), 1800);
        assert_eq!(parse_ttl_secs("12h").unwrap(), 43_200);
        assert_eq!(parse_ttl_secs("2d").unwrap(), 172_800);
        assert_eq!(parse_ttl_secs(" 1 h ").unwrap(), 3600);
        assert!(parse_ttl_secs("").is_err());
        assert!(parse_ttl_secs("h").is_err());
        assert!(parse_ttl_secs("12w").is_err());
        assert!(parse_ttl_secs("99999999999999999999d").is_err());
    }

    #[test]
    fn surface_flag_wins_over_env_and_missing_is_an_error() {
        assert_eq!(
            remote_surface_from(Some(" abc "), Some("env"), false).unwrap(),
            "abc"
        );
        assert_eq!(
            remote_surface_from(Some("  "), Some("env"), false).unwrap(),
            "env"
        );
        assert_eq!(
            remote_surface_from(None, Some("env"), false).unwrap(),
            "env"
        );
        assert!(remote_surface_from(None, None, false)
            .unwrap_err()
            .contains("--surface"));
        assert!(remote_surface_from(None, Some(" "), false).is_err());
    }

    #[test]
    fn background_session_refuses_the_inherited_surface() {
        let err = remote_surface_from(None, Some("env"), true).unwrap_err();
        assert!(err.contains("background session"));
        assert_eq!(
            remote_surface_from(Some("abc"), Some("env"), true).unwrap(),
            "abc"
        );
    }

    /// The Bash tool of a background session has `CLAUDE_JOB_DIR` but not
    /// `CLAUDE_CODE_SESSION_KIND`; a pane session has neither.
    #[test]
    fn a_background_session_is_recognized_from_what_its_tools_see() {
        let detect = |vars: &[(&str, &str)]| {
            let vars: Vec<(String, String)> = vars
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect();
            is_claude_background_session(&|name| {
                vars.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone())
            })
        };
        assert!(detect(&[(
            "CLAUDE_JOB_DIR",
            "/Users/me/.claude/jobs/99e1e8fa"
        )]));
        assert!(detect(&[("CLAUDE_CODE_SESSION_KIND", "bg")]));
        assert!(!detect(&[("CLAUDE_CODE_SESSION_KIND", "interactive")]));
        assert!(!detect(&[("CLAUDE_JOB_DIR", " ")]));
        assert!(!detect(&[]));
    }

    #[test]
    fn app_socket_prefers_pane_socket_path_then_app_typed_socket() {
        assert_eq!(
            remote_app_socket_from(Some("/tmp/term-mesh.sock"), Some("/tmp/term-meshd.sock")),
            Some("/tmp/term-mesh.sock".into())
        );
        // TERMMESH_SOCKET pointing at a daemon socket is not an app socket.
        assert_eq!(
            remote_app_socket_from(None, Some("/tmp/term-meshd.sock")),
            None
        );
        assert_eq!(
            remote_app_socket_from(None, Some("/tmp/term-mesh-debug-x.sock")),
            Some("/tmp/term-mesh-debug-x.sock".into())
        );
        assert_eq!(remote_app_socket_from(Some("relative.sock"), None), None);
        assert_eq!(remote_app_socket_from(None, None), None);
    }

    #[test]
    fn agent_target_defaults_to_this_panes_agent_unless_the_pane_flow_is_forced() {
        // Bare `remote on` inside a team agent pane exposes that agent.
        assert_eq!(
            remote_agent_target(None, Some("reviewer"), false, false)
                .unwrap()
                .as_deref(),
            Some("reviewer")
        );
        // Outside a team it is the plain pane.
        assert_eq!(remote_agent_target(None, None, false, false).unwrap(), None);
        assert_eq!(
            remote_agent_target(None, Some(" "), false, false).unwrap(),
            None
        );
        // `--terminal`, `--leader`, and `--surface` keep the surface flow.
        assert_eq!(
            remote_agent_target(None, Some("reviewer"), false, true).unwrap(),
            None
        );
        assert_eq!(
            remote_agent_target(None, Some("reviewer"), true, false).unwrap(),
            None
        );
        // `--agent NAME` always names, `--agent` alone borrows the pane's name.
        assert_eq!(
            remote_agent_target(Some(" other "), Some("reviewer"), true, true)
                .unwrap()
                .as_deref(),
            Some("other")
        );
        assert_eq!(
            remote_agent_target(Some(""), Some("reviewer"), false, false)
                .unwrap()
                .as_deref(),
            Some("reviewer")
        );
        assert!(remote_agent_target(Some(""), None, false, false)
            .unwrap_err()
            .contains("--agent <name>"));
    }

    #[test]
    fn leader_detection_needs_token_and_no_worker_name() {
        assert!(remote_leader_from(Some("tok"), None));
        assert!(remote_leader_from(Some("tok"), Some("")));
        assert!(!remote_leader_from(Some("tok"), Some("worker-1")));
        assert!(!remote_leader_from(None, None));
        assert!(!remote_leader_from(Some(" "), None));
    }

    #[test]
    fn codex_remote_prefers_the_active_thread_over_the_parent_session() {
        let id = remote_session_id_from("codex", |key| match key {
            "CODEX_THREAD_ID" => Some("active-thread".into()),
            "CODEX_SESSION_ID" => Some("parent-session".into()),
            _ => None,
        });
        assert_eq!(id.as_deref(), Some("active-thread"));
    }

    #[test]
    fn serve_status_maps_the_listener_to_its_tailnet_base() {
        let status = json!({
            "TCP": {"443": {"HTTPS": true}},
            "Web": {"mac.tail5b1e6.ts.net:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:9877"}}}},
            "AllowFunnel": {}
        });
        assert_eq!(
            parse_serve_status(&status, "127.0.0.1:9877"),
            TailnetServe::Served {
                base: "https://mac.tail5b1e6.ts.net".into(),
                funnel: false
            }
        );
        // A different port is somebody else's serve.
        assert_eq!(
            parse_serve_status(&status, "127.0.0.1:9876"),
            TailnetServe::NotServed
        );
        assert_eq!(
            parse_serve_status(&json!({}), "127.0.0.1:9877"),
            TailnetServe::NotServed
        );

        let mounted = json!({
            "Web": {"mac.tail5b1e6.ts.net:8443": {"Handlers": {"/rc/": {"Proxy": "http://localhost:9877"}}}},
            "AllowFunnel": {"mac.tail5b1e6.ts.net:8443": true}
        });
        assert_eq!(
            parse_serve_status(&mounted, "127.0.0.1:9877"),
            TailnetServe::Served {
                base: "https://mac.tail5b1e6.ts.net:8443/rc".into(),
                funnel: true
            }
        );
    }

    #[test]
    fn tailnet_lines_name_the_url_or_the_command_to_run() {
        let served = TailnetServe::Served {
            base: "https://mac.ts.net".into(),
            funnel: false,
        };
        assert_eq!(
            tailnet_lines_for(&served, "127.0.0.1:9877", "abc"),
            vec!["tailnet: https://mac.ts.net/t/abc".to_string()]
        );
        let funnel = TailnetServe::Served {
            base: "https://mac.ts.net".into(),
            funnel: true,
        };
        let lines = tailnet_lines_for(&funnel, "127.0.0.1:9877", "abc");
        assert_eq!(lines.len(), 2);
        assert!(lines[1].contains("tailscale funnel off"));
        let not = tailnet_lines_for(&TailnetServe::NotServed, "127.0.0.1:20226", "abc");
        assert_eq!(
            not,
            vec![
                "tailnet: not served yet; on this Mac run: tailscale serve --bg 20226".to_string()
            ]
        );
        assert_eq!(
            listener_addr_from_url("http://127.0.0.1:9877/t/abc").as_deref(),
            Some("127.0.0.1:9877")
        );
        assert_eq!(listener_addr_from_url("https://x/t/abc"), None);
    }

    #[test]
    fn default_title_is_the_cwd_basename() {
        assert_eq!(
            remote_default_title("/Users/me/work/term-mesh"),
            "term-mesh"
        );
        assert_eq!(remote_default_title("/"), "pane");
        assert_eq!(remote_default_title(""), "pane");
    }
}
