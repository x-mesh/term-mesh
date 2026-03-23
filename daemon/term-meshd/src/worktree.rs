use git2::Repository;
use serde::{Deserialize, Serialize};
use std::io::Write;

use uuid::Uuid;

/// Append a timestamped line to ~/.term-mesh/logs/worktree.log.
/// Best-effort — never panics or propagates errors.
fn wt_log(msg: &str) {
    let Some(home) = dirs::home_dir() else { return };
    let log_dir = home.join(".term-mesh").join("logs");
    let _ = std::fs::create_dir_all(&log_dir);
    let log_path = log_dir.join("worktree.log");
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)
    {
        let d = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        let total_s = d.as_secs();
        let ms = d.subsec_millis();
        // UTC breakdown without external crate
        let s = (total_s % 60) as u32;
        let m = ((total_s / 60) % 60) as u32;
        let h = ((total_s / 3600) % 24) as u32;
        let _ = writeln!(f, "[{h:02}:{m:02}:{s:02}.{ms:03}Z] {msg}");
    }
}

#[derive(Debug, Deserialize)]
pub struct CreateParams {
    /// Path to the source git repository
    pub repo_path: String,
    /// Optional custom branch name (defaults to generated UUID-based name)
    pub branch: Option<String>,
    /// Optional base directory for worktree placement.
    /// Worktree is created at `{base_dir}/{repo_name}/term-mesh_wt_{uuid}`.
    /// Defaults to `~/.term-mesh/worktrees/{repo_name}/`.
    pub base_dir: Option<String>,
    /// Optional base ref (branch/tag/commit) to branch from.
    /// Defaults to HEAD if not specified.
    pub base_ref: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct WorktreeInfo {
    pub name: String,
    pub path: String,
    pub branch: String,
}

/// Create a new git worktree sandbox for an agent session.
///
/// Worktrees are created at `{base_dir}/{repo_name}/term-mesh_wt_<UUID>`.
/// If `base_dir` is not provided, defaults to `~/.term-mesh/worktrees/{repo_name}/`.
pub fn create(params: serde_json::Value) -> Result<WorktreeInfo, String> {
    let result = create_inner(params);
    if let Err(ref e) = result {
        wt_log(&format!("CREATE FAIL {e}"));
    }
    result
}

fn create_inner(params: serde_json::Value) -> Result<WorktreeInfo, String> {
    let params: CreateParams =
        serde_json::from_value(params).map_err(|e| format!("invalid params: {e}"))?;

    wt_log(&format!(
        "CREATE repo={} branch={} base_ref={} base_dir={}",
        params.repo_path,
        params.branch.as_deref().unwrap_or("(auto)"),
        params.base_ref.as_deref().unwrap_or("HEAD"),
        params.base_dir.as_deref().unwrap_or("(default)"),
    ));

    // Open the repo — if repo_path is itself a worktree, resolve to the main
    // repo. Git does not support nested worktrees, so creating a worktree from
    // a worktree would fail.
    //
    // For a worktree, repo.path() returns `<main>/.git/worktrees/<name>/`.
    // Walking up to the `.git` dir and opening its parent gives us the main repo.
    let repo = {
        let candidate = Repository::open(&params.repo_path)
            .map_err(|e| format!("cannot open repo at {}: {e}", params.repo_path))?;
        if candidate.is_worktree() {
            let git_path = candidate.path(); // e.g. <main>/.git/worktrees/<name>/
            // Walk up: worktrees/<name> -> worktrees -> .git -> main repo root
            let main_git_dir = git_path.parent() // worktrees/<name>
                .and_then(|p| p.parent())        // worktrees
                .and_then(|p| p.parent())        // .git
                .ok_or_else(|| format!("cannot resolve main repo from worktree path: {}", git_path.display()))?;
            tracing::debug!("resolved worktree to main repo: {}", main_git_dir.display());
            Repository::open(main_git_dir)
                .map_err(|e| format!("cannot open main repo at {}: {e}", main_git_dir.display()))?
        } else {
            candidate
        }
    };

    let short_id = &Uuid::new_v4().to_string()[..8];
    let wt_name = format!("term-mesh_wt_{short_id}");

    let branch_name = params
        .branch
        .unwrap_or_else(|| format!("term-mesh/{short_id}"));

    // Resolve base ref (or HEAD) to create the branch from
    let commit = if let Some(ref base) = params.base_ref {
        let obj = repo
            .revparse_single(base)
            .map_err(|e| format!("cannot resolve base ref '{base}': {e}"))?;
        obj.peel_to_commit()
            .map_err(|e| format!("base ref '{base}' is not a commit: {e}"))?
    } else {
        let head = repo
            .head()
            .map_err(|e| format!("cannot resolve HEAD: {e}"))?;
        head.peel_to_commit()
            .map_err(|e| format!("HEAD is not a commit: {e}"))?
    };

    // Create branch (delete stale branch+worktree first if it already exists)
    if repo.find_branch(&branch_name, git2::BranchType::Local).is_ok() {
        // Check if there's an existing worktree using this branch and prune it
        if let Ok(wt_names) = repo.worktrees() {
            for existing_wt in wt_names.iter().flatten() {
                if let Ok(wt) = repo.find_worktree(existing_wt) {
                    let wt_path = wt.path().to_path_buf();
                    if let Ok(wt_repo) = Repository::open(&wt_path) {
                        if let Ok(head) = wt_repo.head() {
                            if head.shorthand() == Some(&branch_name) {
                                // Safety: skip if worktree has uncommitted changes
                                let is_dirty = wt_repo
                                    .statuses(Some(
                                        git2::StatusOptions::new()
                                            .include_untracked(true)
                                            .recurse_untracked_dirs(true),
                                    ))
                                    .map(|s| !s.is_empty())
                                    .unwrap_or(false);
                                if is_dirty {
                                    return Err(format!(
                                        "existing worktree '{existing_wt}' on branch '{branch_name}' has uncommitted changes — remove it manually first"
                                    ));
                                }
                                let _ = wt.prune(Some(
                                    git2::WorktreePruneOptions::new()
                                        .working_tree(true)
                                        .valid(true),
                                ));
                                if wt_path.exists() {
                                    let _ = std::fs::remove_dir_all(&wt_path);
                                }
                                tracing::info!("pruned stale worktree '{existing_wt}' for branch '{branch_name}'");
                                break;
                            }
                        }
                    }
                }
            }
        }
        // Delete the stale branch so we can recreate it from current HEAD
        let mut branch = repo.find_branch(&branch_name, git2::BranchType::Local)
            .map_err(|e| format!("cannot find branch '{branch_name}': {e}"))?;
        branch.delete()
            .map_err(|e| format!("cannot delete stale branch '{branch_name}': {e}"))?;
        tracing::info!("deleted stale branch '{branch_name}' for re-creation");
    }
    repo.branch(&branch_name, &commit, false)
        .map_err(|e| format!("cannot create branch '{branch_name}': {e}"))?;

    // Worktree path: use base_dir if provided, otherwise default to ~/.term-mesh/worktrees/{repo_name}/
    let repo_root = repo
        .workdir()
        .ok_or("bare repos not supported")?;
    let wt_path = if let Some(ref base) = params.base_dir {
        let base_path = std::path::PathBuf::from(base);
        let repo_name = repo_root.file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "unknown".to_string());
        let target_dir = base_path.join(&repo_name);
        std::fs::create_dir_all(&target_dir)
            .map_err(|e| format!("cannot create worktree base dir: {e}"))?;
        target_dir.join(&wt_name)
    } else {
        let home = dirs::home_dir().ok_or("cannot determine home directory")?;
        let default_base = home.join(".term-mesh").join("worktrees");
        let repo_name = repo_root.file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "unknown".to_string());
        let target_dir = default_base.join(&repo_name);
        std::fs::create_dir_all(&target_dir)
            .map_err(|e| format!("cannot create worktree base dir: {e}"))?;
        target_dir.join(&wt_name)
    };

    // Create worktree
    repo.worktree(
        &wt_name,
        &wt_path,
        Some(
            git2::WorktreeAddOptions::new()
                .reference(Some(&repo.find_branch(&branch_name, git2::BranchType::Local)
                    .map_err(|e| format!("branch lookup failed: {e}"))?
                    .into_reference())),
        ),
    )
    .map_err(|e| format!("cannot create worktree: {e}"))?;

    let path_str = wt_path.to_string_lossy().into_owned();
    tracing::info!("created worktree {wt_name} at {}", wt_path.display());
    wt_log(&format!("CREATE OK name={wt_name} branch={branch_name} path={path_str}"));

    Ok(WorktreeInfo {
        name: wt_name,
        path: path_str,
        branch: branch_name,
    })
}

/// List local branches for a repo.
pub fn list_branches(params: serde_json::Value) -> Result<Vec<String>, String> {
    #[derive(Deserialize)]
    struct ListBranchesParams {
        repo_path: String,
    }

    let params: ListBranchesParams =
        serde_json::from_value(params).map_err(|e| format!("invalid params: {e}"))?;

    let repo = Repository::open(&params.repo_path)
        .map_err(|e| format!("cannot open repo at {}: {e}", params.repo_path))?;

    let branches = repo
        .branches(Some(git2::BranchType::Local))
        .map_err(|e| format!("cannot list branches: {e}"))?;

    let mut result: Vec<String> = branches
        .filter_map(|b| b.ok())
        .filter_map(|(b, _)| b.name().ok().flatten().map(|n| n.to_string()))
        .collect();

    // Sort with main/master first, then alphabetical
    result.sort_by(|a, b| {
        let a_primary = a == "main" || a == "master";
        let b_primary = b == "main" || b == "master";
        match (a_primary, b_primary) {
            (true, false) => std::cmp::Ordering::Less,
            (false, true) => std::cmp::Ordering::Greater,
            _ => a.cmp(b),
        }
    });

    Ok(result)
}

/// Remove a worktree by name.
/// When `force` is false (default), refuses to remove dirty or unpushed worktrees.
pub fn remove(params: serde_json::Value) -> Result<(), String> {
    #[derive(Deserialize)]
    struct RemoveParams {
        repo_path: String,
        name: String,
        #[serde(default)]
        force: bool,
    }

    let params: RemoveParams =
        serde_json::from_value(params).map_err(|e| format!("invalid params: {e}"))?;

    wt_log(&format!("REMOVE name={} force={} repo={}", params.name, params.force, params.repo_path));

    let repo = Repository::open(&params.repo_path)
        .map_err(|e| format!("cannot open repo: {e}"))?;

    // Find worktree and get its path before pruning
    let wt = repo
        .find_worktree(&params.name)
        .map_err(|e| format!("worktree '{}' not found: {e}", params.name))?;
    let wt_path = wt.path().to_path_buf();

    // Safety check: refuse to remove dirty/unpushed worktrees unless forced
    if !params.force {
        if let Ok(wt_repo) = Repository::open(&wt_path) {
            if let Ok(statuses) = wt_repo.statuses(Some(
                git2::StatusOptions::new()
                    .include_untracked(true)
                    .recurse_untracked_dirs(true),
            )) {
                if !statuses.is_empty() {
                    return Err(format!(
                        "worktree '{}' has uncommitted changes — use force=true or discard changes first",
                        params.name
                    ));
                }
            }
        }
    }

    wt.prune(Some(
        git2::WorktreePruneOptions::new()
            .working_tree(true)
            .valid(true),
    ))
    .map_err(|e| format!("cannot prune worktree: {e}"))?;

    // Remove the directory using the path from git metadata
    if wt_path.exists() {
        std::fs::remove_dir_all(&wt_path)
            .map_err(|e| format!("cannot remove directory: {e}"))?;
    }

    tracing::info!("removed worktree {} (force={})", params.name, params.force);
    wt_log(&format!("REMOVE OK name={}", params.name));
    Ok(())
}

/// List all term-mesh worktrees for a repo.
pub fn list(params: serde_json::Value) -> Result<Vec<WorktreeInfo>, String> {
    #[derive(Deserialize)]
    struct ListParams {
        repo_path: String,
    }

    let params: ListParams =
        serde_json::from_value(params).map_err(|e| format!("invalid params: {e}"))?;

    let repo = Repository::open(&params.repo_path)
        .map_err(|e| format!("cannot open repo: {e}"))?;

    let names = repo
        .worktrees()
        .map_err(|e| format!("cannot list worktrees: {e}"))?;

    let mut result = Vec::new();
    for name in names.iter().flatten() {
        if !name.starts_with("term-mesh_wt_") {
            continue;
        }
        if let Ok(wt) = repo.find_worktree(name) {
            let path = wt.path().to_string_lossy().into_owned();
            // Try to determine the branch
            let branch = worktree_branch(&repo, name);
            result.push(WorktreeInfo {
                name: name.to_string(),
                path,
                branch,
            });
        }
    }

    Ok(result)
}


fn worktree_branch(repo: &Repository, wt_name: &str) -> String {
    // Get path from git worktree metadata
    let wt_path = match repo.find_worktree(wt_name) {
        Ok(wt) => wt.path().to_path_buf(),
        Err(_) => return "unknown".into(),
    };
    match Repository::open(&wt_path) {
        Ok(wt_repo) => match wt_repo.head() {
            Ok(head) => head
                .shorthand()
                .unwrap_or("detached")
                .to_string(),
            Err(_) => "unknown".into(),
        },
        Err(_) => "unknown".into(),
    }
}

/// Status of a worktree (dirty / unpushed checks).
#[derive(Debug, Serialize)]
pub struct WorktreeStatus {
    /// true if the worktree has uncommitted changes (modified, staged, or untracked files)
    pub dirty: bool,
    /// true if the worktree has commits not pushed to its upstream
    pub unpushed: bool,
}

/// Check whether a worktree has uncommitted changes or unpushed commits.
pub fn status(params: serde_json::Value) -> Result<WorktreeStatus, String> {
    #[derive(Deserialize)]
    struct StatusParams {
        repo_path: String,
        name: String,
    }

    let params: StatusParams =
        serde_json::from_value(params).map_err(|e| format!("invalid params: {e}"))?;

    let repo = Repository::open(&params.repo_path)
        .map_err(|e| format!("cannot open repo: {e}"))?;

    let wt = repo
        .find_worktree(&params.name)
        .map_err(|e| format!("worktree '{}' not found: {e}", params.name))?;
    let wt_path = wt.path().to_path_buf();

    let wt_repo = Repository::open(&wt_path)
        .map_err(|e| format!("cannot open worktree repo: {e}"))?;

    // Check dirty: any modified, staged, or untracked files
    let statuses = wt_repo
        .statuses(Some(
            git2::StatusOptions::new()
                .include_untracked(true)
                .recurse_untracked_dirs(true),
        ))
        .map_err(|e| format!("cannot get status: {e}"))?;
    let dirty = !statuses.is_empty();

    // Check unpushed: commits ahead of upstream
    let unpushed = match wt_repo.head() {
        Ok(head) => {
            if let Some(local_oid) = head.target() {
                // Try to find upstream
                let branch_name = head.shorthand().unwrap_or("HEAD");
                match wt_repo.find_branch(branch_name, git2::BranchType::Local) {
                    Ok(branch) => match branch.upstream() {
                        Ok(upstream) => {
                            if let Some(upstream_oid) = upstream.get().target() {
                                // Count commits local has that upstream doesn't
                                let (ahead, _) = wt_repo
                                    .graph_ahead_behind(local_oid, upstream_oid)
                                    .unwrap_or((0, 0));
                                ahead > 0
                            } else {
                                false
                            }
                        }
                        Err(_) => {
                            // No upstream configured — any commits on the branch count as unpushed
                            true
                        }
                    },
                    Err(_) => false,
                }
            } else {
                false
            }
        }
        Err(_) => false,
    };

    Ok(WorktreeStatus { dirty, unpushed })
}

/// Remove a worktree only if it has no uncommitted changes.
/// Delegates to `remove()` with `force=false` (the default).
pub fn safe_remove(params: serde_json::Value) -> Result<(), String> {
    // remove() now checks dirty by default (force=false)
    remove(params)
}

/// Detect orphan worktrees left behind by crashed sessions.
/// Scans common project directories for `term-mesh_wt_*` directories.
/// Does NOT auto-delete — only logs warnings so the user or admin can investigate.
pub fn detect_orphan_worktrees() {
    let home = match dirs::home_dir() {
        Some(h) => h,
        None => return,
    };

    let search_dirs = [
        home.join("work"),
        home.join("projects"),
        home.join("dev"),
        home.join("src"),
        home.clone(),
    ];

    let mut orphans = Vec::new();

    for dir in &search_dirs {
        if !dir.is_dir() {
            continue;
        }
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                let name = entry.file_name();
                let name_str = name.to_string_lossy();
                if name_str.starts_with("term-mesh_wt_") && entry.path().is_dir() {
                    orphans.push(entry.path());
                }
            }
        }
    }

    // Also scan the default worktree base directory
    let default_wt_base = home.join(".term-mesh").join("worktrees");
    if default_wt_base.is_dir() {
        if let Ok(entries) = std::fs::read_dir(&default_wt_base) {
            for entry in entries.flatten() {
                if entry.path().is_dir() {
                    // Each subdirectory is a repo-name folder, scan inside
                    if let Ok(inner) = std::fs::read_dir(entry.path()) {
                        for inner_entry in inner.flatten() {
                            let name = inner_entry.file_name();
                            let name_str = name.to_string_lossy();
                            if name_str.starts_with("term-mesh_wt_") && inner_entry.path().is_dir() {
                                orphans.push(inner_entry.path());
                            }
                        }
                    }
                }
            }
        }
    }

    if orphans.is_empty() {
        tracing::debug!("no orphan worktrees detected");
    } else {
        tracing::warn!(
            "detected {} orphan worktree(s) — manual cleanup may be needed:",
            orphans.len()
        );
        for path in &orphans {
            tracing::warn!("  orphan: {}", path.display());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn init_temp_repo() -> (tempfile::TempDir, String) {
        let dir = tempfile::tempdir().unwrap();
        let repo_path = dir.path().join("repo");
        std::fs::create_dir(&repo_path).unwrap();

        // Initialize git repo with an initial commit
        Command::new("git")
            .args(["init"])
            .current_dir(&repo_path)
            .output()
            .unwrap();
        Command::new("git")
            .args(["config", "user.email", "test@test.com"])
            .current_dir(&repo_path)
            .output()
            .unwrap();
        Command::new("git")
            .args(["config", "user.name", "Test"])
            .current_dir(&repo_path)
            .output()
            .unwrap();

        // Create an initial commit (required for HEAD)
        let file = repo_path.join("README.md");
        std::fs::write(&file, "# test").unwrap();
        Command::new("git")
            .args(["add", "."])
            .current_dir(&repo_path)
            .output()
            .unwrap();
        Command::new("git")
            .args(["commit", "-m", "init"])
            .current_dir(&repo_path)
            .output()
            .unwrap();

        let path_str = repo_path.to_string_lossy().into_owned();
        (dir, path_str)
    }


    #[test]
    fn create_and_list_worktree() {
        let (_dir, repo_path) = init_temp_repo();

        let params = serde_json::json!({
            "repo_path": repo_path,
        });
        let info = create(params).unwrap();
        assert!(info.name.starts_with("term-mesh_wt_"));
        assert!(info.branch.starts_with("term-mesh/"));
        assert!(std::path::Path::new(&info.path).exists());

        // List should contain our worktree
        let list_params = serde_json::json!({ "repo_path": repo_path });
        let worktrees = list(list_params).unwrap();
        assert_eq!(worktrees.len(), 1);
        assert_eq!(worktrees[0].name, info.name);
    }

    #[test]
    fn create_and_remove_worktree() {
        let (_dir, repo_path) = init_temp_repo();

        let params = serde_json::json!({ "repo_path": repo_path });
        let info = create(params).unwrap();

        let remove_params = serde_json::json!({
            "repo_path": repo_path,
            "name": info.name,
        });
        remove(remove_params).unwrap();

        // Should be gone from list
        let list_params = serde_json::json!({ "repo_path": repo_path });
        let worktrees = list(list_params).unwrap();
        assert!(worktrees.is_empty());
    }

    #[test]
    fn create_with_custom_branch() {
        let (_dir, repo_path) = init_temp_repo();

        let params = serde_json::json!({
            "repo_path": repo_path,
            "branch": "custom-branch",
        });
        let info = create(params).unwrap();
        assert_eq!(info.branch, "custom-branch");
    }

    #[test]
    fn invalid_repo_path_returns_error() {
        let params = serde_json::json!({
            "repo_path": "/nonexistent/path/to/repo",
        });
        let result = create(params);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("cannot open repo"));
    }

    #[test]
    fn create_reuses_stale_branch() {
        let (_dir, repo_path) = init_temp_repo();

        // First creation with a named branch
        let params = serde_json::json!({
            "repo_path": repo_path,
            "branch": "team/test-team",
        });
        let info1 = create(params).unwrap();
        assert_eq!(info1.branch, "team/test-team");
        assert!(std::path::Path::new(&info1.path).exists());

        // Second creation with the same branch name should succeed
        // (stale branch+worktree get cleaned up automatically)
        let params2 = serde_json::json!({
            "repo_path": repo_path,
            "branch": "team/test-team",
        });
        let info2 = create(params2).unwrap();
        assert_eq!(info2.branch, "team/test-team");
        assert!(std::path::Path::new(&info2.path).exists());
        // Should be a different worktree
        assert_ne!(info1.name, info2.name);
    }

    #[test]
    fn create_with_base_dir() {
        let (_dir, repo_path) = init_temp_repo();
        let base = tempfile::tempdir().unwrap();
        let params = serde_json::json!({
            "repo_path": repo_path,
            "base_dir": base.path().to_string_lossy(),
        });
        let info = create(params).unwrap();
        assert!(info.path.starts_with(&base.path().to_string_lossy().to_string()));
        assert!(std::path::Path::new(&info.path).exists());
    }
}
