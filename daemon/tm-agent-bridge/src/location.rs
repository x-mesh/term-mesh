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

use std::collections::BTreeMap;
use std::env;

/// `~/.profile` could not be sourced.
pub const PROFILE_LOAD_EXIT: i32 = 77;
/// `~/.config/term-mesh/agent-env` could not be sourced.
pub const AGENT_ENV_LOAD_EXIT: i32 = 78;

/// term-mesh fixes the remote `PATH` rather than inheriting one, so a peer
/// host's CLI paths are configured explicitly instead of by shell startup.
const REMOTE_PATH: &str = "$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:\
/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";

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

/// The three variables the app sets when a pane's agent belongs to a peer.
#[derive(Debug, Default, Clone)]
pub struct RemoteEnv {
    pub ssh_args: Option<String>,
    pub cwd: Option<String>,
    pub env: Option<String>,
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
    // the sorting; PATH is dropped because REMOTE_PATH below is authoritative.
    let assignments: Vec<String> = remote_env
        .into_iter()
        .filter(|(key, _)| key != "PATH" && is_env_name(key))
        .map(|(key, value)| format!("{key}={value}"))
        .collect();

    let profile = "$HOME/.profile";
    let agent_env = "$HOME/.config/term-mesh/agent-env";

    // `-l` loads the account's shell-specific login profile. Bash skips
    // `.profile` when `.bash_profile`/`.bash_login` exists, and zsh never
    // reads it, so the literal `.profile` is added only for those two cases —
    // sourcing it for the plain bash/sh fallback would run it twice.
    //
    // `agent-env` is a Bourne-compatible opt-in fragment, loaded after the
    // profiles and before explicit host values so the host's word is final.
    // Sourced stdout is discarded: it would otherwise land in app-server's
    // JSON-RPC stream and corrupt the protocol.
    let mut inner = String::new();
    inner.push_str(r#"case "${SHELL##*/}" in "#);
    inner.push_str(&format!(
        r#"bash) if {{ [ -f "$HOME/.bash_profile" ] || [ -f "$HOME/.bash_login" ]; }} && [ -f "{profile}" ]; then . "{profile}" >/dev/null || exit {PROFILE_LOAD_EXIT}; fi ;; "#
    ));
    inner.push_str(&format!(
        r#"zsh) if [ -f "{profile}" ]; then . "{profile}" >/dev/null || exit {PROFILE_LOAD_EXIT}; fi ;; "#
    ));
    inner.push_str("esac; ");
    inner.push_str(&format!(
        r#"if [ -f "{agent_env}" ]; then set -a; . "{agent_env}" >/dev/null || exit {AGENT_ENV_LOAD_EXIT}; set +a; fi; "#
    ));
    inner.push_str(&format!(r#"export PATH="{REMOTE_PATH}"; "#));

    // Peer-hosted terminal surfaces already carry IS_SANDBOX. Claude uses it
    // to permit explicitly requested bypass mode under root; the native SSH
    // path must keep the same host contract rather than behave differently.
    let mut tail: Vec<String> = assignments;
    tail.extend(argv.iter().cloned());
    inner.push_str("exec env IS_SANDBOX=1 ");
    inner.push_str(&shell_join(&tail));

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
fn shell_quote(value: &str) -> String {
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

fn shell_join(parts: &[String]) -> String {
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
        assert!(command.contains(">/dev/null || exit 78"));
        assert!(
            command.find(source).unwrap() < command.find(explicit).unwrap(),
            "the host's own value has to win, so it is applied last"
        );
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

    /// The two bridges ship side by side, so a peer agent must get the same
    /// shell either way. This is the literal output of the Python
    /// `process_location` for these inputs, captured by running it — not
    /// retyped from reading it. Any drift between the implementations shows up
    /// here as a diff rather than as an agent that behaves differently on
    /// Tuesday.
    #[test]
    fn the_command_matches_the_python_bridge_byte_for_byte() {
        let command = remote_command(
            "/remote/project",
            Some(&[
                ("AI_MESH_API_KEY", "from-host"),
                ("TERMMESH_AGENT_NAME", "ai"),
            ]),
            &["codex", "app-server"],
        );

        assert_eq!(
            command,
            r#"mkdir -p /remote/project && cd /remote/project && exec "${SHELL:-/bin/sh}" -lc 'case "${SHELL##*/}" in bash) if { [ -f "$HOME/.bash_profile" ] || [ -f "$HOME/.bash_login" ]; } && [ -f "$HOME/.profile" ]; then . "$HOME/.profile" >/dev/null || exit 77; fi ;; zsh) if [ -f "$HOME/.profile" ]; then . "$HOME/.profile" >/dev/null || exit 77; fi ;; esac; if [ -f "$HOME/.config/term-mesh/agent-env" ]; then set -a; . "$HOME/.config/term-mesh/agent-env" >/dev/null || exit 78; set +a; fi; export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"; exec env IS_SANDBOX=1 AI_MESH_API_KEY=from-host TERMMESH_AGENT_NAME=ai codex app-server'"#
        );
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
