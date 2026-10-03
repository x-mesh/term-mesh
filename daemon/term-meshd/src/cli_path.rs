//! PATH for a CLI the daemon spawns.
//!
//! Lives on its own so `http_mobile` (which `tests/mobile_http.rs` includes by
//! `#[path]`) and the headless agent builder share one answer.

use std::path::PathBuf;

/// Standard user-level bin directories where agent CLIs (codex, gemini, kiro,
/// claude) are commonly installed. Only directories that actually exist are
/// returned, so the composed PATH stays clean.
///
/// Covers: pipx/uv/manual (`~/.local/bin`, where `codex` lands), rust
/// (`~/.cargo/bin`), bun (`~/.bun/bin`), go (`~/go/bin`), npm global prefixes,
/// `~/bin`, and Homebrew (`/opt/homebrew/{bin,sbin}` Apple Silicon,
/// `/usr/local/{bin,sbin}` Intel).
pub(crate) fn user_bin_dirs() -> Vec<String> {
    let mut out: Vec<PathBuf> = Vec::new();
    if let Some(home) = dirs::home_dir() {
        for rel in [
            ".local/bin",
            ".cargo/bin",
            "bin",
            "go/bin",
            ".bun/bin",
            ".npm-global/bin",
            ".npm-packages/bin",
        ] {
            out.push(home.join(rel));
        }
    }
    for abs in [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
    ] {
        out.push(PathBuf::from(abs));
    }
    out.into_iter()
        .filter(|p| p.is_dir())
        .map(|p| p.to_string_lossy().into_owned())
        .collect()
}

/// Compose the PATH for a headless agent subprocess.
///
/// A GUI-launched daemon (Finder/Spotlight/launchd) inherits a minimal PATH that
/// omits user-level bin dirs, so spawning a CLI installed in e.g. `~/.local/bin`
/// (codex) fails with "No such file or directory" — even though it is installed.
/// This prepends the daemon's own `Resources/bin` and the standard user bin dirs
/// ahead of the inherited PATH, deduplicating while preserving order
/// (daemon bin → user bins → inherited PATH).
pub(crate) fn compose_agent_path(daemon_bin_dir: &str, current_path: &str) -> String {
    let mut seen = std::collections::HashSet::new();
    let mut parts: Vec<String> = Vec::new();
    let candidates = std::iter::once(daemon_bin_dir.to_string())
        .chain(user_bin_dirs())
        .chain(current_path.split(':').map(str::to_string));
    for p in candidates {
        if p.is_empty() {
            continue;
        }
        if seen.insert(p.clone()) {
            parts.push(p);
        }
    }
    parts.join(":")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compose_agent_path_prepends_daemon_bin_and_dedupes() {
        // daemon bin already present in inherited PATH must not duplicate, and
        // must sit first. Inherited entries are preserved after user bins.
        let out = compose_agent_path("/app/Resources/bin", "/app/Resources/bin:/usr/bin:/bin");
        let parts: Vec<&str> = out.split(':').collect();
        assert_eq!(parts[0], "/app/Resources/bin", "daemon bin must be first");
        assert_eq!(
            parts.iter().filter(|p| **p == "/app/Resources/bin").count(),
            1,
            "no duplicate daemon bin"
        );
        assert!(parts.contains(&"/usr/bin"));
        assert!(parts.contains(&"/bin"));
    }

    #[test]
    fn compose_agent_path_skips_empty_segments() {
        let out = compose_agent_path("", "::/usr/bin:");
        let parts: Vec<&str> = out.split(':').collect();
        assert!(
            !parts.iter().any(|p| p.is_empty()),
            "no empty PATH segments"
        );
        assert!(parts.contains(&"/usr/bin"));
    }
}
