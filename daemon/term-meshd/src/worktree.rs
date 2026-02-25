use git2::Repository;
use serde::{Deserialize, Serialize};

use uuid::Uuid;

#[derive(Debug, Deserialize)]
pub struct CreateParams {
    /// Path to the source git repository
    pub repo_path: String,
    /// Optional custom branch name (defaults to generated UUID-based name)
    pub branch: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct WorktreeInfo {
    pub name: String,
    pub path: String,
    pub branch: String,
}

/// Create a new git worktree sandbox for an agent session.
///
/// Worktrees are created at `../term-mesh_wt_<UUID>` relative to the repo,
/// matching the PRD spec (F-01).
pub fn create(params: serde_json::Value) -> Result<WorktreeInfo, String> {
    let params: CreateParams =
        serde_json::from_value(params).map_err(|e| format!("invalid params: {e}"))?;

    let repo = Repository::open(&params.repo_path)
        .map_err(|e| format!("cannot open repo at {}: {e}", params.repo_path))?;

    let short_id = &Uuid::new_v4().to_string()[..8];
    let wt_name = format!("term-mesh_wt_{short_id}");

    let branch_name = params
        .branch
        .unwrap_or_else(|| format!("term-mesh/{short_id}"));

    // Resolve HEAD to create the branch
    let head = repo
        .head()
        .map_err(|e| format!("cannot resolve HEAD: {e}"))?;
    let commit = head
        .peel_to_commit()
        .map_err(|e| format!("HEAD is not a commit: {e}"))?;

    // Create branch
    repo.branch(&branch_name, &commit, false)
        .map_err(|e| format!("cannot create branch '{branch_name}': {e}"))?;

    // Worktree path: sibling directory to the repo
    let repo_root = repo
        .workdir()
        .ok_or("bare repos not supported")?;
    let parent = repo_root
        .parent()
        .ok_or("repo has no parent directory")?;
    let wt_path = parent.join(&wt_name);

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

    tracing::info!("created worktree {wt_name} at {}", wt_path.display());

    Ok(WorktreeInfo {
        name: wt_name,
        path: wt_path.to_string_lossy().into_owned(),
        branch: branch_name,
    })
}

/// Remove a worktree by name.
pub fn remove(params: serde_json::Value) -> Result<(), String> {
    #[derive(Deserialize)]
    struct RemoveParams {
        repo_path: String,
        name: String,
    }

    let params: RemoveParams =
        serde_json::from_value(params).map_err(|e| format!("invalid params: {e}"))?;

    let repo = Repository::open(&params.repo_path)
        .map_err(|e| format!("cannot open repo: {e}"))?;

    // Find and prune the worktree
    let wt = repo
        .find_worktree(&params.name)
        .map_err(|e| format!("worktree '{}' not found: {e}", params.name))?;

    wt.prune(Some(
        git2::WorktreePruneOptions::new()
            .working_tree(true)
            .valid(true),
    ))
    .map_err(|e| format!("cannot prune worktree: {e}"))?;

    // Also remove the directory
    let repo_root = repo.workdir().ok_or("bare repos not supported")?;
    let parent = repo_root.parent().ok_or("repo has no parent directory")?;
    let wt_path = parent.join(&params.name);
    if wt_path.exists() {
        std::fs::remove_dir_all(&wt_path)
            .map_err(|e| format!("cannot remove directory: {e}"))?;
    }

    tracing::info!("removed worktree {}", params.name);
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

/// Check if a worktree name follows the term-mesh convention.
pub fn is_term_mesh_worktree(name: &str) -> bool {
    name.starts_with("term-mesh_wt_")
}

fn worktree_branch(repo: &Repository, wt_name: &str) -> String {
    // Open the worktree's repo to read its HEAD
    let repo_root = match repo.workdir() {
        Some(r) => r,
        None => return "unknown".into(),
    };
    let parent = match repo_root.parent() {
        Some(p) => p,
        None => return "unknown".into(),
    };
    let wt_path = parent.join(wt_name);
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
    fn is_term_mesh_worktree_name() {
        assert!(is_term_mesh_worktree("term-mesh_wt_abcd1234"));
        assert!(!is_term_mesh_worktree("other_worktree"));
        assert!(!is_term_mesh_worktree(""));
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
}
