use std::process::Command;

fn main() {
    // Embed git SHA at build time
    let sha = Command::new("git")
        .args(["rev-parse", "--short=9", "HEAD"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .unwrap_or_default()
        .trim()
        .to_string();
    println!("cargo:rustc-env=TM_GIT_SHA={sha}");

    // Embed build timestamp
    let ts = Command::new("date")
        .args(["+%Y-%m-%dT%H:%M:%S"])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .unwrap_or_default()
        .trim()
        .to_string();
    println!("cargo:rustc-env=TM_BUILD_DATE={ts}");

    // Cargo otherwise keeps a stale embedded SHA when the current branch
    // advances: .git/HEAD contains only `ref: ...` and its bytes do not
    // change on every commit. Ask git for the real paths so this also works
    // in linked worktrees where `.git` is a file.
    watch_git_path("HEAD");
    if let Some(current_ref) = git_stdout(&["symbolic-ref", "-q", "HEAD"]) {
        watch_git_path(&current_ref);
    }
}

fn git_stdout(args: &[&str]) -> Option<String> {
    let output = Command::new("git").args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8(output.stdout).ok()?.trim().to_string();
    (!value.is_empty()).then_some(value)
}

fn watch_git_path(revision_path: &str) {
    if let Some(path) = git_stdout(&["rev-parse", "--git-path", revision_path]) {
        println!("cargo:rerun-if-changed={path}");
    }
}
