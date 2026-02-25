mod pty;
mod rpc;

use std::env;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();

    if args.len() < 2 {
        print_usage();
        return ExitCode::from(1);
    }

    match args[1].as_str() {
        "run" => {
            if args.len() < 3 {
                eprintln!("term-mesh-run: missing command");
                eprintln!("Usage: term-mesh-run [--sandbox] <command> [args...]");
                return ExitCode::from(1);
            }

            // Parse --sandbox flag
            let (sandbox, cmd_start) = if args[2] == "--sandbox" {
                if args.len() < 4 {
                    eprintln!("term-mesh-run --sandbox: missing command");
                    eprintln!("Usage: term-mesh-run --sandbox <command> [args...]");
                    return ExitCode::from(1);
                }
                (true, 3)
            } else {
                (false, 2)
            };

            let cmd = &args[cmd_start];
            let cmd_args: Vec<&str> = args[cmd_start + 1..].iter().map(|s| s.as_str()).collect();

            if sandbox {
                run_sandboxed(cmd, &cmd_args)
            } else {
                match pty::run_with_pty(cmd, &cmd_args, None) {
                    Ok((code, _pid)) => ExitCode::from(code as u8),
                    Err(e) => {
                        eprintln!("term-mesh-run: {}", e);
                        ExitCode::from(1)
                    }
                }
            }
        }
        "help" | "--help" | "-h" => {
            print_usage();
            ExitCode::SUCCESS
        }
        other => {
            eprintln!("term-mesh-run: unknown command '{}'", other);
            print_usage();
            ExitCode::from(1)
        }
    }
}

/// Run a command in a sandboxed git worktree.
///
/// 1. Detect git repo
/// 2. Connect to daemon (fallback to plain PTY if unavailable)
/// 3. Create worktree via RPC
/// 4. Watch the worktree directory
/// 5. Run the command in the worktree via PTY
/// 6. Cleanup: untrack, unwatch, remove worktree
fn run_sandboxed(cmd: &str, args: &[&str]) -> ExitCode {
    let repo_path = match detect_git_repo() {
        Some(p) => p,
        None => {
            eprintln!("term-mesh-run: --sandbox requires a git repository");
            eprintln!("  (not inside a git repo, falling back to plain PTY)");
            return match pty::run_with_pty(cmd, args, None) {
                Ok((code, _)) => ExitCode::from(code as u8),
                Err(e) => {
                    eprintln!("term-mesh-run: {}", e);
                    ExitCode::from(1)
                }
            };
        }
    };

    let mut client = match rpc::RpcClient::connect() {
        Some(c) => c,
        None => {
            eprintln!("term-mesh-run: daemon not running, falling back to plain PTY");
            eprintln!("  (start term-meshd for full sandbox support)");
            return match pty::run_with_pty(cmd, args, None) {
                Ok((code, _)) => ExitCode::from(code as u8),
                Err(e) => {
                    eprintln!("term-mesh-run: {}", e);
                    ExitCode::from(1)
                }
            };
        }
    };

    // Create worktree
    let wt_info = match client.call(
        "worktree.create",
        serde_json::json!({ "repo_path": repo_path }),
    ) {
        Ok(info) => info,
        Err(e) => {
            eprintln!("term-mesh-run: failed to create worktree: {}", e);
            eprintln!("  (falling back to plain PTY)");
            return match pty::run_with_pty(cmd, args, None) {
                Ok((code, _)) => ExitCode::from(code as u8),
                Err(e) => {
                    eprintln!("term-mesh-run: {}", e);
                    ExitCode::from(1)
                }
            };
        }
    };

    let wt_path = wt_info
        .get("path")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let wt_name = wt_info
        .get("name")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    if wt_path.is_empty() || wt_name.is_empty() {
        eprintln!("term-mesh-run: invalid worktree response from daemon");
        return ExitCode::from(1);
    }

    eprintln!(
        "term-mesh-run: sandbox created at {}",
        wt_path
    );

    // Watch the worktree directory
    let _ = client.call("watcher.watch", serde_json::json!({ "path": &wt_path }));

    // Run the command in the worktree
    let result = pty::run_with_pty(cmd, args, Some(&wt_path));

    let (exit_code, child_pid) = match result {
        Ok((code, pid)) => (code, Some(pid)),
        Err(e) => {
            eprintln!("term-mesh-run: {}", e);
            (1, None)
        }
    };

    // Cleanup (best-effort)
    cleanup_sandbox(&repo_path, &wt_name, &wt_path, child_pid);

    ExitCode::from(exit_code as u8)
}

/// Best-effort cleanup of sandbox resources.
fn cleanup_sandbox(repo_path: &str, wt_name: &str, wt_path: &str, child_pid: Option<u32>) {
    eprintln!("term-mesh-run: cleaning up sandbox...");

    // Reconnect (the previous connection may have been dropped)
    let mut client = match rpc::RpcClient::connect() {
        Some(c) => c,
        None => {
            eprintln!("term-mesh-run: daemon not available for cleanup");
            return;
        }
    };

    // Untrack the child process
    if let Some(pid) = child_pid {
        let _ = client.call("monitor.untrack", serde_json::json!({ "pid": pid }));
    }

    // Unwatch the directory
    let _ = client.call("watcher.unwatch", serde_json::json!({ "path": wt_path }));

    // Remove the worktree
    match client.call(
        "worktree.remove",
        serde_json::json!({
            "repo_path": repo_path,
            "name": wt_name,
        }),
    ) {
        Ok(_) => eprintln!("term-mesh-run: sandbox removed"),
        Err(e) => eprintln!("term-mesh-run: failed to remove worktree: {}", e),
    }
}

/// Detect the root of the current git repository.
fn detect_git_repo() -> Option<String> {
    let output = std::process::Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let path = String::from_utf8(output.stdout).ok()?;
    let trimmed = path.trim().to_string();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    }
}

fn print_usage() {
    eprintln!("term-mesh-run — PTY wrapper for AI agents");
    eprintln!();
    eprintln!("Usage:");
    eprintln!("  term-mesh-run <command> [args...]            Run command in a PTY wrapper");
    eprintln!("  term-mesh-run --sandbox <command> [args...]  Run in a git worktree sandbox");
    eprintln!("  term-mesh-run help                           Show this help");
    eprintln!();
    eprintln!("Sandbox mode:");
    eprintln!("  Creates a temporary git worktree, runs the command there, and cleans up");
    eprintln!("  on exit. Requires term-meshd daemon and a git repository.");
    eprintln!();
    eprintln!("Examples:");
    eprintln!("  term-mesh-run claude code");
    eprintln!("  term-mesh-run --sandbox claude code");
    eprintln!("  term-mesh-run -- kiro-cli chat \"fix this bug\"");
}
