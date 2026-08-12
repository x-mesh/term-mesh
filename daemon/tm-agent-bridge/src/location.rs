//! Move a child process behind SSH when the native pane hosts a peer agent.
//!
//! The shell this assembles is why a peer agent sees the environment it sees,
//! which makes it the highest-stakes string in the bridge. It was also the
//! subject of a real outage: five workers went silent because their provider
//! key lived in `~/.bashrc`, and `~/.bashrc` returns early for a
//! non-interactive shell — so the `-lc` below never reached the export. The
//! fix was `agent-env`, which is loaded here on purpose and is the only file
//! in this chain that a non-interactive login shell is guaranteed to read.
//!
//! Environment values arrive as an argument rather than being read from the
//! process. The Python original read them inline and its tests had to patch a
//! global to compensate; passing them in keeps the assembly a pure function,
//! which is the part worth testing.

// Consumed once a bridge launches a child; until then the compiler is right
// that nothing calls any of it.
#![allow(dead_code)]

use std::collections::BTreeMap;
use std::env;

/// `~/.profile` could not be sourced.
pub const PROFILE_LOAD_EXIT: i32 = 77;
/// `~/.config/term-mesh/agent-env` could not be sourced.
pub const AGENT_ENV_LOAD_EXIT: i32 = 78;

/// term-mesh fixes the remote `PATH` rather than inheriting one, so a peer
/// host's CLI paths are configured explicitly instead of by shell startup.
pub const REMOTE_PATH: &str = "$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:\
/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";

/// `PATH` for a remote launch: [`REMOTE_PATH`], then a host's configured
/// directories.
///
/// A `PATH` saved for a peer host used to be dropped outright — the baseline
/// was authoritative and that was the end of it. But a CLI installed somewhere
/// the baseline does not list (`~/.npm-global/bin`, `~/bin`, a pyenv shim) then
/// had no way to be reached at all, while the readiness probe searched a wider
/// set and happily reported it present. The pane opened and the agent inside
/// it never started.
///
/// Configured directories are searched **after** the baseline, not before it.
/// That order is the whole safety property: the baseline is what guarantees
/// the binaries term-mesh installs are the ones that run, and a host setting
/// that could shadow `/usr/bin` or a term-mesh CLI with a same-named file
/// would take that guarantee away. Appending still solves what the setting is
/// for — a directory the baseline never lists is now reachable — because
/// nothing earlier in the search can answer for a CLI that only lives there.
/// To pin a *particular* binary, configure that CLI's absolute path instead;
/// that is what the CLI path settings are.
///
/// Entries are used verbatim, so `$HOME` and `~` expand as the launching shell
/// would. Empty segments are dropped; they would silently mean "current
/// directory" to the shell.
pub fn path_with_extra(extra: Option<&str>) -> String {
    let Some(extra) = extra else {
        return REMOTE_PATH.to_string();
    };
    let suffix: Vec<&str> = extra
        .split(':')
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .collect();
    if suffix.is_empty() {
        return REMOTE_PATH.to_string();
    }
    format!("{}:{}", REMOTE_PATH, suffix.join(":"))
}

/// Turn wrapper-only exit codes into safe, actionable UI messages.
///
/// Safe meaning: it names the file, never its contents. A profile that failed
/// to load is reported without echoing anything it might have set.
pub fn remote_launch_failure(code: Option<i32>) -> Option<&'static str> {
    match code {
        Some(PROFILE_LOAD_EXIT) => Some("remote agent could not load ~/.profile"),
        Some(AGENT_ENV_LOAD_EXIT) => {
            Some("remote agent could not load ~/.config/term-mesh/agent-env")
        }
        _ => None,
    }
}

/// The variables the app sets when a pane's agent belongs to a peer.
#[derive(Debug, Default, Clone)]
pub struct RemoteEnv {
    pub ssh_args: Option<String>,
    pub cwd: Option<String>,
    pub env: Option<String>,
    /// A 0600 shell fragment staged on the peer. Its contents never enter the
    /// local ssh argv; the remote shell sources and removes it before launch.
    pub env_file: Option<String>,
}

impl RemoteEnv {
    // Unused until a bridge actually launches a child; kept here because
    // reading the process environment is this module's job, not the caller's.
    #[allow(dead_code)]
    pub fn from_process() -> Self {
        // An empty value means "not remote", same as absent: the Python
        // original tested the string for truthiness, and a launch line that
        // exports an empty variable must not become half-remote.
        fn var(name: &str) -> Option<String> {
            env::var(name).ok().filter(|v| !v.is_empty())
        }
        Self {
            ssh_args: var("TERMMESH_REMOTE_NATIVE_SSH_ARGS"),
            cwd: var("TERMMESH_REMOTE_NATIVE_CWD"),
            env: var("TERMMESH_REMOTE_NATIVE_ENV"),
            env_file: var("TERMMESH_REMOTE_NATIVE_ENV_FILE"),
        }
    }
}

/// Where a child process actually runs.
#[derive(Debug, PartialEq, Eq)]
pub struct Location {
    pub argv: Vec<String>,
    /// `None` once the command carries its own `cd`; the caller must not set a
    /// working directory that only exists on this machine.
    pub cwd: Option<String>,
}

pub fn process_location(
    remote: &RemoteEnv,
    argv: &[String],
    cwd: &str,
) -> Result<Location, String> {
    let Some(raw) = remote.ssh_args.as_deref() else {
        return Ok(Location {
            argv: argv.to_vec(),
            cwd: Some(cwd.to_string()),
        });
    };

    let ssh: Vec<String> = match serde_json::from_str::<serde_json::Value>(raw) {
        Ok(serde_json::Value::Array(items)) => {
            let parsed: Option<Vec<String>> = items
                .iter()
                .map(|v| v.as_str().map(str::to_string))
                .collect();
            match parsed {
                Some(list) if !list.is_empty() => list,
                _ => return Err("invalid remote SSH arguments".into()),
            }
        }
        Ok(_) => return Err("invalid remote SSH arguments".into()),
        Err(e) => return Err(format!("invalid remote SSH arguments: {e}")),
    };

    let remote_cwd = remote.cwd.clone().unwrap_or_else(|| cwd.to_string());
    let quoted_cwd = shell_quote(&remote_cwd);

    let mut remote_env: BTreeMap<String, String> = BTreeMap::new();
    if let Some(raw_env) = remote.env.as_deref() {
        match serde_json::from_str::<serde_json::Value>(raw_env) {
            Ok(serde_json::Value::Object(map)) => {
                for (key, value) in map {
                    match value.as_str() {
                        Some(v) => {
                            remote_env.insert(key, v.to_string());
                        }
                        None => return Err("invalid remote environment".into()),
                    }
                }
            }
            Ok(_) => return Err("invalid remote environment".into()),
            Err(e) => return Err(format!("invalid remote environment: {e}")),
        }
    }

    // Sorted so the same inputs always produce the same command — a launch
    // line that reorders between runs is one nobody can diff. BTreeMap does
    // the sorting. PATH is pulled out of the assignments because it is not
    // one: see `path_with_extra`.
    let extra_path = remote_env.get("PATH").cloned();
    let assignments: Vec<String> = remote_env
        .into_iter()
        .filter(|(key, _)| key != "PATH" && is_env_name(key))
        .map(|(key, value)| format!("{key}={value}"))
        .collect();

    // `-l` loads the account's shell-specific login profile. Bash skips
    // `.profile` when `.bash_profile`/`.bash_login` exists, and zsh never
    // reads it, so the literal `.profile` is added only for those two cases —
    // sourcing it for the plain bash/sh fallback would run it twice.
    //
    // `agent-env` is a Bourne-compatible opt-in fragment, loaded after the
    // profiles and before explicit host values so the host's word is final.
    // Sourced stdout is discarded: it would otherwise land in app-server's
    // JSON-RPC stream and corrupt the protocol.
    let mut inner = login_environment_prelude(
        &format!("exit {PROFILE_LOAD_EXIT}"),
        &format!("exit {AGENT_ENV_LOAD_EXIT}"),
    );
    if let Some(env_file) = remote.env_file.as_deref() {
        let quoted = shell_quote(env_file);
        inner.push_str(&format!(
            "[ -f {quoted} ] || exit 79; set -a; . {quoted} >/dev/null 2>&1 || exit 79; rm -f -- {quoted}; set +a; "
        ));
    }
    if !assignments.is_empty() {
        inner.push_str("export ");
        inner.push_str(&shell_join(&assignments));
        inner.push_str("; ");
    }
    inner.push_str(&environment_diagnostic_event());
    inner.push_str(&format!(
        r#"export PATH="{}"; "#,
        path_with_extra(extra_path.as_deref())
    ));

    // Peer-hosted terminal surfaces already carry IS_SANDBOX. Claude uses it
    // to permit explicitly requested bypass mode under root; the native SSH
    // path must keep the same host contract rather than behave differently.
    inner.push_str("exec env IS_SANDBOX=1 ");
    inner.push_str(&shell_join(argv));

    let command = format!(
        "mkdir -p {quoted_cwd} && cd {quoted_cwd} && exec \"${{SHELL:-/bin/sh}}\" -lc {}",
        shell_quote(&inner)
    );

    let mut out = ssh;
    out.push(command);
    Ok(Location {
        argv: out,
        cwd: None,
    })
}

/// Bourne-compatible login-environment load chain shared by the SSH bridge
/// and daemon-owned native agent processes. Callers append their explicit
/// environment and final `exec` after this string, which preserves the
/// required precedence: login profile < literal `~/.profile` fallback <
/// `agent-env` < explicit values.
///
/// Failure actions are fixed caller-owned snippets. Every sourced byte from
/// stdout and stderr is discarded before they run, so neither a noisy profile
/// nor a failing assignment can disclose environment values into an agent
/// protocol stream or daemon log.
pub fn login_environment_prelude(
    profile_failure_action: &str,
    agent_env_failure_action: &str,
) -> String {
    let profile = "$HOME/.profile";
    let agent_env = "$HOME/.config/term-mesh/agent-env";
    let mut inner = String::new();
    inner.push_str("term_mesh_profile_fallback=skipped; term_mesh_agent_env=missing; ");
    inner.push_str(r#"case "${SHELL##*/}" in "#);
    inner.push_str(&format!(
        r#"bash) if {{ [ -f "$HOME/.bash_profile" ] || [ -f "$HOME/.bash_login" ]; }} && [ -f "{profile}" ]; then term_mesh_profile_fallback=loaded; . "{profile}" >/dev/null 2>&1 || {{ {profile_failure_action}; }}; fi ;; "#
    ));
    inner.push_str(&format!(
        r#"zsh) if [ -f "{profile}" ]; then term_mesh_profile_fallback=loaded; . "{profile}" >/dev/null 2>&1 || {{ {profile_failure_action}; }}; else term_mesh_profile_fallback=missing; fi ;; "#
    ));
    inner.push_str("esac; ");
    inner.push_str(&format!(
        r#"if [ -f "{agent_env}" ]; then set -a; term_mesh_agent_env=loaded; . "{agent_env}" >/dev/null 2>&1 || {{ {agent_env_failure_action}; }}; set +a; fi; "#
    ));
    inner
}

/// One value-free NDJSON fact emitted by the exact shell that launches an
/// agent. Key names are a fixed allowlist; values and hashes never cross the
/// protocol boundary.
pub fn environment_diagnostic_event() -> String {
    const KEYS: &[&str] = &[
        "AI_MESH_API_KEY",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_API_KEY",
        "OPENAI_BASE_URL",
        "OPENAI_API_KEY",
    ];
    let mut script = String::from(
        r#"term_mesh_shell=${SHELL##*/}; case "$term_mesh_shell" in bash|zsh|sh|dash|fish) ;; *) term_mesh_shell=other;; esac; printf '%s' '{"type":"system","subtype":"environment","shell":"'; printf '%s' "$term_mesh_shell"; printf '%s' '","login":true,"interactive":false,"profile_fallback":"'; printf '%s' "$term_mesh_profile_fallback"; printf '%s' '","agent_env":"'; printf '%s' "$term_mesh_agent_env"; printf '%s' '","present_keys":['; term_mesh_sep=; "#,
    );
    for key in KEYS {
        script.push_str(&format!(
            r#"if [ "${{{key}+x}}" = x ]; then printf '%s"%s"' "$term_mesh_sep" {key}; term_mesh_sep=,; fi; "#
        ));
    }
    script.push_str("printf '%s\\n' ']}'; ");
    script
}

pub fn is_environment_diagnostic(value: &serde_json::Value) -> bool {
    value.get("type").and_then(serde_json::Value::as_str) == Some("system")
        && value.get("subtype").and_then(serde_json::Value::as_str) == Some("environment")
}

/// A name `env` will accept as an assignment rather than treat as a command.
fn is_env_name(key: &str) -> bool {
    let mut chars = key.chars();
    match chars.next() {
        None => false,
        Some(first) if first.is_numeric() => false,
        Some(first) if !(first.is_alphanumeric() || first == '_') => false,
        Some(_) => chars.all(|c| c.is_alphanumeric() || c == '_'),
    }
}

/// `shlex.quote`, matching the Python bridge character for character.
///
/// Both implementations have to produce the same command string while they
/// ship side by side, so this follows CPython's rule rather than inventing a
/// tidier one: leave the safe set alone, otherwise single-quote and escape
/// embedded quotes the long way.
pub fn shell_quote(value: &str) -> String {
    if value.is_empty() {
        return "''".to_string();
    }
    let safe = value.chars().all(|c| {
        c.is_alphanumeric()
            || matches!(c, '_' | '@' | '%' | '+' | '=' | ':' | ',' | '.' | '/' | '-')
    });
    if safe {
        return value.to_string();
    }
    format!("'{}'", value.replace('\'', r#"'"'"'"#))
}

pub fn shell_join(parts: &[String]) -> String {
    parts
        .iter()
        .map(|p| shell_quote(p))
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::Path;
    use std::process::Command;

    fn remote_command(
        remote_cwd: &str,
        remote_env: Option<&[(&str, &str)]>,
        child: &[&str],
    ) -> String {
        let env_json = remote_env.map(|pairs| {
            let map: serde_json::Map<String, serde_json::Value> = pairs
                .iter()
                .map(|(k, v)| (k.to_string(), serde_json::Value::String(v.to_string())))
                .collect();
            serde_json::to_string(&map).unwrap()
        });
        let remote = RemoteEnv {
            ssh_args: Some(r#"["/usr/bin/ssh", "root@peer"]"#.to_string()),
            cwd: Some(remote_cwd.to_string()),
            env: env_json,
            env_file: None,
        };
        let argv: Vec<String> = child.iter().map(|s| s.to_string()).collect();
        let located = process_location(&remote, &argv, "/local/project").unwrap();

        assert_eq!(located.cwd, None, "a remote command carries its own cd");
        located.argv.last().unwrap().clone()
    }

    fn run_remote_command(command: &str, shell: &str, home: &Path) -> std::process::Output {
        Command::new("/bin/sh")
            .arg("-c")
            .arg(command)
            .env("HOME", home)
            .env("SHELL", shell)
            .output()
            .expect("shell runs")
    }

    fn temp_home(name: &str) -> std::path::PathBuf {
        let dir = env::temp_dir().join(format!("tm-bridge-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_local_child_is_left_where_it_is() {
        let argv = vec!["codex".to_string(), "app-server".to_string()];
        let located = process_location(&RemoteEnv::default(), &argv, "/local/project").unwrap();

        assert_eq!(located.argv, argv);
        assert_eq!(located.cwd.as_deref(), Some("/local/project"));
    }

    #[test]
    fn command_loads_agent_env_before_explicit_host_environment() {
        let command = remote_command(
            "/remote/project",
            Some(&[("AI_MESH_API_KEY", "from-host")]),
            &["codex", "app-server"],
        );

        let source = r#". "$HOME/.config/term-mesh/agent-env""#;
        let explicit = "AI_MESH_API_KEY=from-host";
        assert!(command.contains(r#"exec "${SHELL:-/bin/sh}" -lc"#));
        assert!(command.contains(r#"[ -f "$HOME/.config/term-mesh/agent-env" ]"#));
        assert!(command.contains(source));
        assert!(command.contains(">/dev/null 2>&1 || { exit 78; }"));
        assert!(
            command.find(source).unwrap() < command.find(explicit).unwrap(),
            "the host's own value has to win, so it is applied last"
        );
    }

    #[test]
    fn command_sources_and_removes_staged_environment_without_embedding_it() {
        let remote = RemoteEnv {
            ssh_args: Some(r#"["/usr/bin/ssh", "root@peer"]"#.to_string()),
            cwd: Some("/remote/project".to_string()),
            env_file: Some("/home/peer/.cache/term-mesh/agent-env/agent-test.env".to_string()),
            ..Default::default()
        };
        let located = process_location(
            &remote,
            &["codex".to_string(), "app-server".to_string()],
            "/local/project",
        )
        .unwrap();
        let command = located.argv.last().unwrap();

        assert!(command.contains("agent-test.env"));
        assert!(command.contains("rm -f --"));
        assert!(!command.contains("TERMMESH_LEADER_GRANT_ID"));
    }

    #[test]
    fn bash_executes_profile_agent_env_and_explicit_precedence() {
        let home = temp_home("precedence");
        fs::write(home.join(".bash_profile"), "export LOGIN_PROFILE=loaded\n").unwrap();
        fs::write(
            home.join(".profile"),
            "export LITERAL_PROFILE=loaded\nexport ORDER=profile\nprintf 'profile-noise\\n'\n",
        )
        .unwrap();
        let agent_env = home.join(".config/term-mesh/agent-env");
        fs::create_dir_all(agent_env.parent().unwrap()).unwrap();
        fs::write(&agent_env, "AGENT_ONLY=loaded\nORDER=agent\nprintf 'agent-noise\\n'\n").unwrap();

        let command = remote_command(
            home.join("project").to_str().unwrap(),
            Some(&[("ORDER", "host")]),
            &["/usr/bin/env"],
        );
        let result = run_remote_command(&command, "/bin/bash", &home);
        let stdout = String::from_utf8_lossy(&result.stdout);

        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
        let values: BTreeMap<&str, &str> = stdout
            .lines()
            .filter_map(|line| line.split_once('='))
            .collect();
        assert_eq!(values.get("LOGIN_PROFILE"), Some(&"loaded"));
        assert_eq!(values.get("LITERAL_PROFILE"), Some(&"loaded"));
        assert_eq!(values.get("AGENT_ONLY"), Some(&"loaded"));
        assert_eq!(values.get("ORDER"), Some(&"host"));
        // Anything a profile prints would be read as a protocol frame.
        assert!(!stdout.contains("profile-noise"));
        assert!(!stdout.contains("agent-noise"));

        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn bash_does_not_double_source_profile_fallback() {
        let home = temp_home("double-source");
        fs::write(
            home.join(".profile"),
            "PROFILE_COUNT=$(( ${PROFILE_COUNT:-0} + 1 ))\nexport PROFILE_COUNT\n",
        )
        .unwrap();

        let command = remote_command(
            home.join("project").to_str().unwrap(),
            None,
            &["/usr/bin/env"],
        );
        let result = run_remote_command(&command, "/bin/bash", &home);
        let stdout = String::from_utf8_lossy(&result.stdout);

        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
        assert!(
            stdout.lines().any(|l| l == "PROFILE_COUNT=1"),
            "bash without .bash_profile already reads .profile: {stdout}"
        );

        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn zsh_loads_literal_profile_after_zprofile() {
        if !Path::new("/bin/zsh").exists() {
            return;
        }
        let home = temp_home("zsh-profile");
        fs::write(home.join(".zprofile"), "export ZPROFILE_LOADED=yes\n").unwrap();
        fs::write(home.join(".profile"), "export LITERAL_PROFILE=yes\n").unwrap();

        let command = remote_command(
            home.join("project").to_str().unwrap(),
            None,
            &["/usr/bin/env"],
        );
        let result = run_remote_command(&command, "/bin/zsh", &home);
        let stdout = String::from_utf8_lossy(&result.stdout);

        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
        assert!(stdout.lines().any(|l| l == "ZPROFILE_LOADED=yes"));
        assert!(stdout.lines().any(|l| l == "LITERAL_PROFILE=yes"));

        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn profile_and_agent_env_failures_use_reserved_exit_codes() {
        let home = temp_home("exit-codes");
        fs::write(home.join(".bash_profile"), "").unwrap();
        fs::write(home.join(".profile"), "false\n").unwrap();
        let command = remote_command(
            home.join("project").to_str().unwrap(),
            None,
            &["/usr/bin/env"],
        );
        let profile_result = run_remote_command(&command, "/bin/bash", &home);

        fs::write(home.join(".profile"), "").unwrap();
        let agent_env = home.join(".config/term-mesh/agent-env");
        fs::create_dir_all(agent_env.parent().unwrap()).unwrap();
        fs::write(&agent_env, "false\n").unwrap();
        let agent_result = run_remote_command(&command, "/bin/bash", &home);

        assert_eq!(profile_result.status.code(), Some(PROFILE_LOAD_EXIT));
        assert_eq!(agent_result.status.code(), Some(AGENT_ENV_LOAD_EXIT));
        assert_eq!(
            remote_launch_failure(profile_result.status.code()),
            Some("remote agent could not load ~/.profile")
        );
        assert_eq!(
            remote_launch_failure(agent_result.status.code()),
            Some("remote agent could not load ~/.config/term-mesh/agent-env")
        );

        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn malformed_remote_configuration_is_refused_rather_than_guessed() {
        let argv = vec!["codex".to_string()];
        let bad_ssh = |raw: &str| {
            process_location(
                &RemoteEnv {
                    ssh_args: Some(raw.to_string()),
                    ..Default::default()
                },
                &argv,
                "/tmp",
            )
        };
        assert!(bad_ssh("not json").is_err());
        assert!(bad_ssh("{}").is_err());
        assert!(bad_ssh("[]").is_err(), "an empty argv cannot launch ssh");
        assert!(bad_ssh("[1, 2]").is_err());

        let bad_env = process_location(
            &RemoteEnv {
                ssh_args: Some(r#"["ssh", "peer"]"#.to_string()),
                env: Some(r#"{"KEY": 1}"#.to_string()),
                ..Default::default()
            },
            &argv,
            "/tmp",
        );
        assert!(bad_env.is_err());
    }

    #[test]
    fn an_assignment_env_would_not_accept_is_dropped() {
        let command = remote_command(
            "/remote/project",
            Some(&[
                ("GOOD_ONE", "keep"),
                ("2BAD", "drop"),
                ("has-dash", "drop"),
                ("PATH", "drop"),
                ("", "drop"),
            ]),
            &["codex"],
        );

        assert!(command.contains("GOOD_ONE=keep"));
        assert!(!command.contains("2BAD"));
        assert!(!command.contains("has-dash"));
        assert!(!command.contains("PATH=drop"));
    }

    #[test]
    fn compiled_bridge_reports_environment_after_explicit_overlay() {
        let command = remote_command(
            "/remote/project",
            Some(&[
                ("AI_MESH_API_KEY", "from-host"),
                ("TERMMESH_AGENT_NAME", "ai"),
            ]),
            &["codex", "app-server"],
        );

        let overlay = command.find("export AI_MESH_API_KEY=from-host").unwrap();
        let diagnostic = command.find("present_keys").unwrap();
        let launch = command
            .find("exec env IS_SANDBOX=1 codex app-server")
            .unwrap();
        assert!(overlay < diagnostic);
        assert!(diagnostic < launch);
        assert!(command.contains("$HOME/.config/term-mesh/agent-env"));
        assert!(command.contains("present_keys"));
    }

    #[test]
    fn quoting_matches_the_python_bridge() {
        assert_eq!(shell_quote(""), "''");
        assert_eq!(shell_quote("plain"), "plain");
        assert_eq!(shell_quote("/a/b-c_d.e"), "/a/b-c_d.e");
        assert_eq!(shell_quote("has space"), "'has space'");
        assert_eq!(shell_quote("it's"), r#"'it'"'"'s'"#);
        assert_eq!(shell_join(&["a".into(), "b c".into()]), "a 'b c'");
    }
}

#[cfg(test)]
mod path_extra_tests {
    use super::*;

    #[test]
    fn no_configured_path_is_the_baseline() {
        assert_eq!(path_with_extra(None), REMOTE_PATH);
        assert_eq!(path_with_extra(Some("")), REMOTE_PATH);
        assert_eq!(path_with_extra(Some("  ")), REMOTE_PATH);
    }

    /// Configured directories are reachable, and the baseline is searched
    /// first. A host setting must not be able to answer for `/usr/bin` or for
    /// a term-mesh CLI with a same-named file placed earlier in the search.
    #[test]
    fn configured_directories_are_searched_after_the_baseline() {
        let path = path_with_extra(Some("/opt/foo/bin:$HOME/.npm-global/bin"));
        assert!(path.starts_with(REMOTE_PATH));
        assert!(path.ends_with(":/opt/foo/bin:$HOME/.npm-global/bin"));
    }

    /// An empty segment means "the current directory" to a shell, which is
    /// never what a trailing colon in a settings field was meant to say.
    #[test]
    fn empty_segments_are_dropped() {
        assert_eq!(path_with_extra(Some("/opt/foo/bin::")), format!("{REMOTE_PATH}:/opt/foo/bin"));
        assert_eq!(path_with_extra(Some(":/opt/foo/bin")), format!("{REMOTE_PATH}:/opt/foo/bin"));
        assert_eq!(path_with_extra(Some(" /opt/foo/bin ")), format!("{REMOTE_PATH}:/opt/foo/bin"));
    }
}
