//! Reading a task's diff out of the worktree it was done in.
//!
//! This is what `team.task.diff` answers, and the reason that method was let
//! onto the peer allow-list at all: **the caller names a task, never a path and
//! never a command.** The host looks the worktree up in its own records and
//! runs a fixed sequence of reads. A peer that could pass a directory here
//! would be a peer that could read any repository on this machine; a peer that
//! could pass arguments would be a peer that could run `git` with whatever
//! flags it liked, and `git` has plenty that write.
//!
//! So every string that reaches a command line below comes from this host's own
//! task record, and the argument lists are literals.

use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use serde::Serialize;
use tokio::process::Command;

/// How long any one git read may take before it is stopped. A `git` that never
/// answers must not hold a peer connection open indefinitely.
const GIT_TIMEOUT: Duration = Duration::from_secs(30);

/// The patch is sent over a peer link, so it is bounded. A truncated patch that
/// says so beats a link stalled on a 40MB vendor-directory diff.
const MAX_PATCH_BYTES: usize = 256 * 1024;

/// The same shape a local read produces, deliberately.
///
/// The approval that follows a review cites `diff_digest`, and the coordinator
/// compares it against what was recorded. So the digest is computed here, over
/// the *untruncated* patch bytes — this is the only machine that has them —
/// and `numstat`/`name_status` are sent raw so the app's existing parser
/// builds the file list the same way for a peer task as for a local one. A
/// peer review that produced a differently-shaped patch would be a review
/// whose digest could never match.
#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct TaskDiff {
    pub head_sha: String,
    pub base_sha: String,
    pub branch: String,
    /// `sha256:` + hex over the full patch, never over the truncated `patch`.
    pub diff_digest: String,
    pub numstat: String,
    pub name_status: String,
    pub patch: String,
    pub truncated: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub enum TaskDiffError {
    /// The task exists but was never given a worktree.
    NoWorktree,
    /// It had one and the directory is not there any more.
    WorktreeMissing(String),
    /// git said no.
    Git(String),
    /// git did not answer.
    TimedOut(String),
}

impl TaskDiffError {
    /// The wire code. Distinct from the message so a caller can branch without
    /// matching on prose.
    pub fn code(&self) -> &'static str {
        match self {
            TaskDiffError::NoWorktree | TaskDiffError::WorktreeMissing(_) => "no_worktree",
            TaskDiffError::Git(_) => "git_error",
            TaskDiffError::TimedOut(_) => "timeout",
        }
    }

    pub fn message(&self) -> String {
        match self {
            TaskDiffError::NoWorktree => {
                "this task has no worktree recorded, so there is no diff to read".to_string()
            }
            TaskDiffError::WorktreeMissing(path) => {
                format!("the worktree at {path} is gone — it was removed or never created")
            }
            TaskDiffError::Git(message) => message.clone(),
            TaskDiffError::TimedOut(what) => {
                format!("git {what} did not answer within {}s", GIT_TIMEOUT.as_secs())
            }
        }
    }
}

/// Read the diff for a worktree the host already knows the path of.
///
/// `base_ref` is the branch the work forked from, as recorded on the task. When
/// it is absent or unknown to git, the diff is taken against the worktree's own
/// first parent — an honest "what this commit changed" rather than a silent
/// empty patch.
pub async fn read(
    worktree_path: Option<&str>,
    base_ref: Option<&str>,
) -> Result<TaskDiff, TaskDiffError> {
    let path = worktree_path
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .ok_or(TaskDiffError::NoWorktree)?;
    if !Path::new(path).is_dir() {
        return Err(TaskDiffError::WorktreeMissing(path.to_string()));
    }

    let head_sha = git(path, &["rev-parse", "HEAD"], "rev-parse HEAD").await?;
    let branch = git(path, &["rev-parse", "--abbrev-ref", "HEAD"], "rev-parse --abbrev-ref")
        .await
        .unwrap_or_default();

    let base_sha = resolve_base(path, base_ref, &head_sha).await?;

    // `<base>..HEAD` and not `<base> HEAD`: the two-dot form is what the merge
    // will actually contribute. A plain two-ref diff also shows everything the
    // base gained since the fork, as if this task had reverted it.
    let range = format!("{base_sha}..HEAD");
    let numstat = git(path, &["diff", "--numstat", &range], "diff --numstat").await?;
    let name_status = git(path, &["diff", "--name-status", &range], "diff --name-status").await?;
    // Raw bytes, not the trimmed string the other reads return: the digest has
    // to cover exactly what `git diff` wrote, including its trailing newline.
    let raw = git_bytes(path, &["diff", &range], "diff").await?;
    let diff_digest = digest(&raw);
    let full = String::from_utf8_lossy(&raw).into_owned();

    let truncated = full.len() > MAX_PATCH_BYTES;
    let patch = if truncated {
        let mut cut = MAX_PATCH_BYTES;
        // Never split a UTF-8 sequence; the result has to survive JSON.
        while cut > 0 && !full.is_char_boundary(cut) {
            cut -= 1;
        }
        full[..cut].to_string()
    } else {
        full
    };

    Ok(TaskDiff {
        head_sha,
        base_sha,
        branch,
        diff_digest,
        numstat,
        name_status,
        patch,
        truncated,
    })
}

/// What this work forked from.
///
/// The merge base, not the base branch's tip: a task that started three days
/// ago should show what it changed, not everything the base has gained since.
/// If the recorded base is unknown to this repository — a branch that only
/// exists on the machine that wrote the task record — fall back to the first
/// parent rather than failing, because an unreadable base is not a reason to
/// have no diff at all.
async fn resolve_base(
    path: &str,
    base_ref: Option<&str>,
    head_sha: &str,
) -> Result<String, TaskDiffError> {
    if let Some(base) = base_ref.map(str::trim).filter(|b| !b.is_empty()) {
        // `--` guards a base name that begins with a dash from being read as a
        // flag. The name comes from this host's own records, but a task record
        // is not a reason to relax an argument boundary.
        if let Ok(merge_base) = git(path, &["merge-base", "--", base, head_sha], "merge-base").await
        {
            if !merge_base.is_empty() {
                return Ok(merge_base);
            }
        }
    }
    match git(path, &["rev-parse", "HEAD^"], "rev-parse HEAD^").await {
        Ok(parent) => Ok(parent),
        // A single-commit branch has no parent. The empty tree is git's own
        // answer for "everything is new", which is exactly right here.
        Err(_) => Ok(EMPTY_TREE.to_string()),
    }
}

/// git's hash of the empty tree — the diff base for a repository's first
/// commit.
const EMPTY_TREE: &str = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

/// The digest the coordinator compares an approval against. Defined in one
/// place on each side; the Swift mirror is `ReviewBoardEvidence.digest`.
fn digest(patch: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(patch);
    format!("sha256:{:x}", hasher.finalize())
}

/// One git read, bounded, with the arguments fixed by the caller in this file.
async fn git(dir: &str, args: &[&str], label: &str) -> Result<String, TaskDiffError> {
    let raw = git_bytes(dir, args, label).await?;
    Ok(String::from_utf8_lossy(&raw).trim().to_string())
}

/// The same read, undecoded. A patch that touches a binary file does not
/// survive a round trip through `String`, and a digest that changes depending
/// on whether the bytes happened to decode is not evidence of anything.
async fn git_bytes(dir: &str, args: &[&str], label: &str) -> Result<Vec<u8>, TaskDiffError> {
    let mut command = Command::new("git");
    command
        .args(args)
        .current_dir(dir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let run = command.output();

    let output = match tokio::time::timeout(GIT_TIMEOUT, run).await {
        Err(_) => return Err(TaskDiffError::TimedOut(label.to_string())),
        Ok(Err(e)) => return Err(TaskDiffError::Git(format!("git {label}: {e}"))),
        Ok(Ok(output)) => output,
    };

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(TaskDiffError::Git(if stderr.is_empty() {
            format!("git {label} failed")
        } else {
            stderr
        }));
    }
    Ok(output.stdout)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command as SyncCommand;

    fn git_sync(dir: &Path, args: &[&str]) {
        let out = SyncCommand::new("git")
            .args(args)
            .current_dir(dir)
            .env("GIT_AUTHOR_NAME", "T")
            .env("GIT_AUTHOR_EMAIL", "t@t")
            .env("GIT_COMMITTER_NAME", "T")
            .env("GIT_COMMITTER_EMAIL", "t@t")
            .output()
            .expect("git");
        assert!(
            out.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    /// A repo on `main` with one commit, then a branch with one more.
    fn repo_with_work() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path();
        git_sync(path, &["init", "-q", "-b", "main"]);
        std::fs::write(path.join("a.txt"), "one\n").unwrap();
        git_sync(path, &["add", "-A"]);
        git_sync(path, &["commit", "-qm", "base"]);
        git_sync(path, &["checkout", "-q", "-b", "feat/thing"]);
        std::fs::write(path.join("a.txt"), "one\ntwo\n").unwrap();
        git_sync(path, &["commit", "-qam", "the work"]);
        dir
    }

    #[tokio::test]
    async fn it_reads_the_stat_patch_and_head() {
        let dir = repo_with_work();
        let path = dir.path().to_str().unwrap();
        let diff = read(Some(path), Some("main")).await.expect("a diff");

        assert_eq!(diff.head_sha.len(), 40, "{}", diff.head_sha);
        assert_eq!(diff.branch, "feat/thing");
        assert!(diff.numstat.contains("a.txt"), "{}", diff.numstat);
        assert!(diff.name_status.starts_with('M'), "{}", diff.name_status);
        assert!(diff.diff_digest.starts_with("sha256:"), "{}", diff.diff_digest);
        assert!(diff.patch.contains("+two"), "{}", diff.patch);
        assert!(!diff.truncated);
    }

    /// The base is the merge base, so work the base gained afterwards does not
    /// appear as if this task had reverted it.
    #[tokio::test]
    async fn a_base_that_moved_on_does_not_pollute_the_patch() {
        let dir = repo_with_work();
        let path = dir.path();
        git_sync(path, &["checkout", "-q", "main"]);
        std::fs::write(path.join("unrelated.txt"), "elsewhere\n").unwrap();
        git_sync(path, &["add", "-A"]);
        git_sync(path, &["commit", "-qm", "main moves on"]);
        git_sync(path, &["checkout", "-q", "feat/thing"]);

        let diff = read(Some(path.to_str().unwrap()), Some("main"))
            .await
            .expect("a diff");
        assert!(diff.patch.contains("a.txt"), "{}", diff.patch);
        assert!(
            !diff.patch.contains("unrelated.txt"),
            "the base's own later work must not show up: {}",
            diff.patch
        );
    }

    /// A base this repository has never heard of is not a reason to return no
    /// diff — it falls back to the commit's own parent.
    #[tokio::test]
    async fn an_unknown_base_falls_back_to_the_parent() {
        let dir = repo_with_work();
        let diff = read(Some(dir.path().to_str().unwrap()), Some("no/such/branch"))
            .await
            .expect("a diff");
        assert!(diff.patch.contains("+two"), "{}", diff.patch);
    }

    #[tokio::test]
    async fn a_repository_with_one_commit_diffs_against_the_empty_tree() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path();
        git_sync(path, &["init", "-q", "-b", "main"]);
        std::fs::write(path.join("a.txt"), "one\n").unwrap();
        git_sync(path, &["add", "-A"]);
        git_sync(path, &["commit", "-qm", "only"]);

        let diff = read(Some(path.to_str().unwrap()), None).await.expect("a diff");
        assert_eq!(diff.base_sha, EMPTY_TREE);
        assert!(diff.patch.contains("+one"), "{}", diff.patch);
    }

    // MARK: - Refusals

    #[tokio::test]
    async fn a_task_with_no_worktree_is_an_error_not_an_empty_success() {
        for path in [None, Some(""), Some("   ")] {
            let error = read(path, Some("main")).await.unwrap_err();
            assert_eq!(error, TaskDiffError::NoWorktree);
            assert_eq!(error.code(), "no_worktree");
            assert!(error.message().contains("no worktree recorded"));
        }
    }

    #[tokio::test]
    async fn a_worktree_that_is_gone_names_the_directory() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("removed").to_str().unwrap().to_string();
        let error = read(Some(&path), Some("main")).await.unwrap_err();
        assert_eq!(error, TaskDiffError::WorktreeMissing(path.clone()));
        assert!(error.message().contains(&path));
    }

    /// A directory that exists but is not a repository fails with git's own
    /// words rather than panicking or reporting an empty diff.
    #[tokio::test]
    async fn a_directory_that_is_not_a_repository_reports_gits_reason() {
        let dir = tempfile::tempdir().unwrap();
        let error = read(Some(dir.path().to_str().unwrap()), None)
            .await
            .unwrap_err();
        assert_eq!(error.code(), "git_error");
        // Ask git for the same refusal rather than matching an English string:
        // the message is passed through verbatim, so its wording follows the
        // locale git runs under and a fixed phrase fails on a translated one.
        let refusal = SyncCommand::new("git")
            .args(["rev-parse", "HEAD"])
            .current_dir(dir.path())
            .output()
            .expect("git");
        let refusal = String::from_utf8_lossy(&refusal.stderr).trim().to_string();
        assert!(!refusal.is_empty(), "git produced no stderr to pass through");
        assert_eq!(error.message(), refusal);
    }

    /// The security property `team.task.diff` was allowed on: a caller-supplied
    /// string is a *value*, never an argument. A base ref that looks like a
    /// flag must not become one.
    #[tokio::test]
    async fn a_base_ref_that_looks_like_a_flag_is_not_treated_as_one() {
        let dir = repo_with_work();
        let path = dir.path().to_str().unwrap();

        // `--output=…` would make git write a file if it were read as a flag.
        let escape = dir.path().join("escaped.txt");
        let hostile = format!("--output={}", escape.display());
        let diff = read(Some(path), Some(&hostile)).await.expect("a diff");

        assert!(
            !escape.exists(),
            "a base ref must never reach git as a flag"
        );
        // And the read still produced the honest fallback diff.
        assert!(diff.patch.contains("+two"), "{}", diff.patch);
    }

    #[tokio::test]
    async fn an_upstream_style_ref_expression_is_still_just_a_ref() {
        let dir = repo_with_work();
        // Not a flag, not a path — merge-base simply will not resolve it, and
        // the fallback answers.
        let diff = read(Some(dir.path().to_str().unwrap()), Some("-C"))
            .await
            .expect("a diff");
        assert!(diff.patch.contains("+two"), "{}", diff.patch);
    }
}
