#[path = "../src/sync/mod.rs"]
mod sync;

use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Stdio};

use git2::{Buf, Oid, Repository, Signature};
use sync::{GitAdvertisement, GitCrashHook, GitError, GitPhase, GitReplicationPlane};
use tempfile::TempDir;

fn commit_file(repository: &Repository, name: &str, content: &[u8]) -> Oid {
    let workdir = repository.workdir().unwrap();
    fs::write(workdir.join(name), content).unwrap();
    let mut index = repository.index().unwrap();
    index.add_path(Path::new(name)).unwrap();
    index.write().unwrap();
    let tree_id = index.write_tree().unwrap();
    let tree = repository.find_tree(tree_id).unwrap();
    let signature = Signature::now("fixture", "fixture@example.invalid").unwrap();
    let parent = repository
        .head()
        .ok()
        .and_then(|head| head.target())
        .and_then(|oid| repository.find_commit(oid).ok());
    let parents = parent.iter().collect::<Vec<_>>();
    repository
        .commit(
            Some("HEAD"),
            &signature,
            &signature,
            "fixture",
            &tree,
            &parents,
        )
        .unwrap()
}

fn pack(repository: &Repository, tip: Oid) -> Vec<u8> {
    let mut builder = repository.packbuilder().unwrap();
    let object = repository.find_object(tip, None).unwrap();
    let graph_tip = if object.kind() == Some(git2::ObjectType::Tag) {
        builder.insert_object(tip, None).unwrap();
        repository.find_tag(tip).unwrap().target_id()
    } else {
        tip
    };
    if repository.find_commit(graph_tip).is_ok() {
        let mut walk = repository.revwalk().unwrap();
        walk.push(graph_tip).unwrap();
        builder.insert_walk(&mut walk).unwrap();
    } else {
        builder.insert_recursive(graph_tip, None).unwrap();
    }
    let mut output = Buf::new();
    builder.write_buf(&mut output).unwrap();
    output.as_ref().to_vec()
}

fn create_state(path: &Path) {
    fs::create_dir(path).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
}

struct Fixture {
    _temp: TempDir,
    source: Repository,
    target_path: std::path::PathBuf,
    state_path: std::path::PathBuf,
    target_head: Oid,
}

impl Fixture {
    fn new() -> Self {
        let temp = TempDir::new().unwrap();
        let source_path = temp.path().join("source");
        let target_path = temp.path().join("target");
        let state_path = temp.path().join("state");
        create_state(&state_path);
        let source = Repository::init(&source_path).unwrap();
        let target = Repository::init(&target_path).unwrap();
        let target_head = commit_file(&target, "local.txt", b"local\n");
        drop(target);
        Self {
            _temp: temp,
            source,
            target_path,
            state_path,
            target_head,
        }
    }

    fn plane(&self) -> GitReplicationPlane {
        GitReplicationPlane::open(&self.target_path, &self.state_path, [0x23; 32]).unwrap()
    }
}

fn protected_snapshot(path: &Path) -> (Oid, Vec<u8>, Vec<u8>, Vec<u8>) {
    let repository = Repository::open(path).unwrap();
    let head = repository.head().unwrap().target().unwrap();
    let index = fs::read(repository.path().join("index")).unwrap();
    let worktree = fs::read(path.join("local.txt")).unwrap();
    let config = fs::read(repository.path().join("config")).unwrap();
    (head, index, worktree, config)
}

fn worktree_snapshot(path: &Path) -> (Oid, Vec<u8>, Vec<u8>) {
    let repository = Repository::open(path).unwrap();
    let head = repository.head().unwrap().target().unwrap();
    (
        head,
        fs::read(repository.path().join("index")).unwrap(),
        fs::read(path.join("local.txt")).unwrap(),
    )
}

#[test]
fn valid_commit_tree_blob_and_annotated_tag_land_only_in_mesh_namespace() {
    let fixture = Fixture::new();
    let commit = commit_file(&fixture.source, "remote.txt", b"remote\n");
    let signature = Signature::now("fixture", "fixture@example.invalid").unwrap();
    let object = fixture.source.find_object(commit, None).unwrap();
    let tag = fixture
        .source
        .tag("v1", &object, &signature, "fixture tag", false)
        .unwrap();
    let bytes = pack(&fixture.source, tag);
    let before = protected_snapshot(&fixture.target_path);
    let plane = fixture.plane();
    let destination = plane
        .replicate(
            [1; 16],
            &GitAdvertisement {
                original_ref: "refs/tags/v1".into(),
                tip: tag,
                expected_mesh_tip: None,
            },
            bytes.as_slice(),
        )
        .unwrap();
    let target = Repository::open(&fixture.target_path).unwrap();
    assert_eq!(target.refname_to_id(&destination).unwrap(), tag);
    assert!(destination.starts_with("refs/mesh/23232323"));
    assert!(target.find_commit(commit).is_ok());
    assert_eq!(protected_snapshot(&fixture.target_path), before);
}

#[test]
fn corrupt_truncated_and_missing_tip_never_create_a_ref() {
    for (index, mutation) in [0u8, 1, 2].into_iter().enumerate() {
        let fixture = Fixture::new();
        let tip = commit_file(&fixture.source, "remote.txt", b"remote\n");
        let mut bytes = pack(&fixture.source, tip);
        let advertised = match mutation {
            0 => {
                bytes[20] ^= 0xff;
                tip
            }
            1 => {
                bytes.truncate(bytes.len() / 2);
                tip
            }
            _ => Oid::from_str("1111111111111111111111111111111111111111").unwrap(),
        };
        let plane = fixture.plane();
        let destination = plane.destination_ref("refs/heads/main").unwrap();
        let result = plane.replicate(
            [10 + index as u8; 16],
            &GitAdvertisement {
                original_ref: "refs/heads/main".into(),
                tip: advertised,
                expected_mesh_tip: None,
            },
            bytes.as_slice(),
        );
        assert!(result.is_err());
        assert!(Repository::open(&fixture.target_path)
            .unwrap()
            .find_reference(&destination)
            .is_err());
    }
}

#[test]
fn hostile_names_are_rejected_before_repository_mutation() {
    let fixture = Fixture::new();
    let plane = fixture.plane();
    let before = protected_snapshot(&fixture.target_path);
    for reference in [
        "HEAD",
        "refs/replace/deadbeef",
        "refs/notes/commits",
        "refs/remotes/origin/main",
        "refs/bisect/bad",
        "refs/heads/../config",
        "refs/heads/main.lock",
        "hooks/pre-commit",
        "objects/info/alternates",
        "info/grafts",
    ] {
        assert!(matches!(
            plane.destination_ref(reference),
            Err(GitError::RefRejected)
        ));
    }
    assert_eq!(protected_snapshot(&fixture.target_path), before);
}

#[test]
fn symbolic_mesh_ref_is_not_followed() {
    let fixture = Fixture::new();
    let tip = commit_file(&fixture.source, "remote.txt", b"remote\n");
    let bytes = pack(&fixture.source, tip);
    let plane = fixture.plane();
    let destination = plane.destination_ref("refs/heads/main").unwrap();
    let target = Repository::open(&fixture.target_path).unwrap();
    target
        .reference_symbolic(&destination, "HEAD", false, "hostile fixture")
        .unwrap();
    drop(target);
    let result = plane.replicate(
        [3; 16],
        &GitAdvertisement {
            original_ref: "refs/heads/main".into(),
            tip,
            expected_mesh_tip: None,
        },
        bytes.as_slice(),
    );
    assert!(matches!(result, Err(GitError::SymbolicRef)));
    assert_eq!(
        Repository::open(&fixture.target_path)
            .unwrap()
            .find_reference(&destination)
            .unwrap()
            .symbolic_target(),
        Some("HEAD")
    );
    assert_eq!(
        Repository::open(&fixture.target_path)
            .unwrap()
            .head()
            .unwrap()
            .target(),
        Some(fixture.target_head)
    );
}

#[test]
fn stale_compare_and_swap_preserves_the_existing_mesh_ref() {
    let fixture = Fixture::new();
    let first = commit_file(&fixture.source, "remote.txt", b"one\n");
    let first_pack = pack(&fixture.source, first);
    let plane = fixture.plane();
    let destination = plane
        .replicate(
            [4; 16],
            &GitAdvertisement {
                original_ref: "refs/heads/main".into(),
                tip: first,
                expected_mesh_tip: None,
            },
            first_pack.as_slice(),
        )
        .unwrap();
    let second = commit_file(&fixture.source, "remote.txt", b"two\n");
    let second_pack = pack(&fixture.source, second);
    let result = plane.replicate(
        [5; 16],
        &GitAdvertisement {
            original_ref: "refs/heads/main".into(),
            tip: second,
            expected_mesh_tip: Some(Oid::zero()),
        },
        second_pack.as_slice(),
    );
    assert!(
        matches!(result, Err(GitError::StaleRef)),
        "unexpected result: {result:?}"
    );
    assert_eq!(
        Repository::open(&fixture.target_path)
            .unwrap()
            .refname_to_id(&destination)
            .unwrap(),
        first
    );
}

#[test]
fn equal_tip_still_rejects_same_operation_with_different_binding() {
    let fixture = Fixture::new();
    let tip = commit_file(&fixture.source, "remote.txt", b"remote\n");
    let bytes = pack(&fixture.source, tip);
    let plane = fixture.plane();
    let advertisement = GitAdvertisement {
        original_ref: "refs/heads/main".into(),
        tip,
        expected_mesh_tip: None,
    };
    plane
        .replicate([0x4a; 16], &advertisement, bytes.as_slice())
        .unwrap();
    let result = plane.replicate(
        [0x4a; 16],
        &GitAdvertisement {
            expected_mesh_tip: Some(Oid::zero()),
            ..advertisement
        },
        [].as_slice(),
    );
    assert!(matches!(result, Err(GitError::JournalCollision)));
}

#[test]
fn crash_after_ref_cas_reconciles_completed_and_releases_orphan_charge() {
    let fixture = Fixture::new();
    let tip = commit_file(&fixture.source, "remote.txt", b"remote\n");
    let bytes = pack(&fixture.source, tip);
    let plane = fixture.plane();
    let advertisement = GitAdvertisement {
        original_ref: "refs/heads/main".into(),
        tip,
        expected_mesh_tip: None,
    };
    assert!(plane
        .replicate_with_hook(
            [0x4b; 16],
            &advertisement,
            bytes.as_slice(),
            &CrashAfter(GitPhase::RefCas),
        )
        .is_err());
    plane
        .replicate([0x4b; 16], &advertisement, [].as_slice())
        .unwrap();
    let journal: serde_json::Value = serde_json::from_slice(
        &fs::read(
            fixture
                .state_path
                .join("git-journals/4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b.json"),
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(journal["phase"], "completed");
    assert_eq!(journal["orphan"], false);
}

#[test]
fn tampered_journal_matrix_is_rejected_before_ref_mutation() {
    for mutation in 0..6u8 {
        let fixture = Fixture::new();
        let tip = commit_file(&fixture.source, "remote.txt", b"remote\n");
        let bytes = pack(&fixture.source, tip);
        let operation = [0xc0 + mutation; 16];
        let advertisement = GitAdvertisement {
            original_ref: "refs/heads/main".into(),
            tip,
            expected_mesh_tip: None,
        };
        let plane = fixture.plane();
        let destination = plane.destination_ref(&advertisement.original_ref).unwrap();
        assert!(plane
            .replicate_with_hook(
                operation,
                &advertisement,
                bytes.as_slice(),
                &CrashAfter(GitPhase::Quarantined),
            )
            .is_err());
        drop(plane);

        let journal_path = fixture
            .state_path
            .join("git-journals")
            .join(format!("{}.json", hex::encode(operation)));
        let mut journal: serde_json::Value =
            serde_json::from_slice(&fs::read(&journal_path).unwrap()).unwrap();
        match mutation {
            0 => journal["pack_checksum"] = serde_json::Value::String("A".repeat(40)),
            1 => journal["pack_bytes"] = serde_json::Value::from(0),
            2 => journal["phase"] = serde_json::Value::String("orphan".into()),
            3 => journal["repository_identity"] = serde_json::Value::String("1:2".into()),
            4 => journal["operation_id"] = serde_json::Value::String("00".repeat(16)),
            5 => {
                journal["target_pack_identity"] =
                    serde_json::Value::String(format!("pack-{}", "0".repeat(40)))
            }
            _ => unreachable!(),
        }
        fs::write(&journal_path, serde_json::to_vec(&journal).unwrap()).unwrap();

        let result = fixture
            .plane()
            .replicate(operation, &advertisement, bytes.as_slice());
        assert!(
            matches!(
                result,
                Err(GitError::CorruptJournal | GitError::JournalCollision)
            ),
            "mutation {mutation} unexpectedly returned {result:?}"
        );
        assert!(Repository::open(&fixture.target_path)
            .unwrap()
            .find_reference(&destination)
            .is_err());
    }
}

struct CrashAfter(GitPhase);
impl GitCrashHook for CrashAfter {
    fn after_phase(&self, phase: GitPhase) -> Result<(), GitError> {
        if phase == self.0 {
            Err(GitError::Crash)
        } else {
            Ok(())
        }
    }
}

#[test]
fn crash_before_ref_keeps_ref_absent_and_after_ref_retry_is_idempotent() {
    for (number, phase) in [GitPhase::Quarantined, GitPhase::Imported]
        .into_iter()
        .enumerate()
    {
        let fixture = Fixture::new();
        let tip = commit_file(&fixture.source, "remote.txt", b"remote\n");
        let bytes = pack(&fixture.source, tip);
        let plane =
            GitReplicationPlane::open(&fixture.target_path, &fixture.state_path, [0x66; 32])
                .unwrap();
        let advertisement = GitAdvertisement {
            original_ref: "refs/heads/main".into(),
            tip,
            expected_mesh_tip: None,
        };
        let destination = plane.destination_ref(&advertisement.original_ref).unwrap();
        assert!(plane
            .replicate_with_hook(
                [20 + number as u8; 16],
                &advertisement,
                bytes.as_slice(),
                &CrashAfter(phase),
            )
            .is_err());
        assert!(Repository::open(&fixture.target_path)
            .unwrap()
            .find_reference(&destination)
            .is_err());
    }

    let fixture = Fixture::new();
    let tip = commit_file(&fixture.source, "remote.txt", b"remote\n");
    let bytes = pack(&fixture.source, tip);
    let plane = fixture.plane();
    let advertisement = GitAdvertisement {
        original_ref: "refs/heads/main".into(),
        tip,
        expected_mesh_tip: None,
    };
    assert!(plane
        .replicate_with_hook(
            [30; 16],
            &advertisement,
            bytes.as_slice(),
            &CrashAfter(GitPhase::RefUpdated),
        )
        .is_err());
    let destination = plane
        .replicate([30; 16], &advertisement, [].as_slice())
        .unwrap();
    assert_eq!(
        Repository::open(&fixture.target_path)
            .unwrap()
            .refname_to_id(&destination)
            .unwrap(),
        tip
    );
}

#[test]
fn hostile_git_metadata_is_byte_identical_after_replication() {
    let fixture = Fixture::new();
    let target = Repository::open(&fixture.target_path).unwrap();
    let git_dir = target.path().to_owned();
    let alternate = Repository::init_bare(fixture._temp.path().join("alternate.git")).unwrap();
    fs::create_dir_all(git_dir.join("hooks")).unwrap();
    fs::create_dir_all(git_dir.join("info")).unwrap();
    fs::create_dir_all(git_dir.join("objects/info")).unwrap();
    fs::write(git_dir.join("hooks/reference-transaction"), b"exit 99\n").unwrap();
    fs::write(
        git_dir.join("info/grafts"),
        format!("{}\n", fixture.target_head),
    )
    .unwrap();
    fs::write(
        git_dir.join("objects/info/alternates"),
        format!("{}objects\n", alternate.path().display()),
    )
    .unwrap();
    target
        .reference(
            "refs/replace/1111111111111111111111111111111111111111",
            fixture.target_head,
            false,
            "fixture",
        )
        .unwrap();
    let paths = [
        git_dir.join("config"),
        git_dir.join("hooks/reference-transaction"),
        git_dir.join("info/grafts"),
        git_dir.join("objects/info/alternates"),
        git_dir.join("refs/replace/1111111111111111111111111111111111111111"),
    ];
    let before = paths.clone().map(|path| fs::read(path).unwrap());
    drop(target);

    let tip = commit_file(&fixture.source, "remote.txt", b"remote\n");
    let bytes = pack(&fixture.source, tip);
    fixture
        .plane()
        .replicate(
            [40; 16],
            &GitAdvertisement {
                original_ref: "refs/heads/main".into(),
                tip,
                expected_mesh_tip: None,
            },
            bytes.as_slice(),
        )
        .unwrap();
    let after = paths.map(|path| fs::read(path).unwrap());
    assert_eq!(after, before);
}

#[test]
fn linked_worktree_uses_the_common_object_database_without_checkout() {
    let fixture = Fixture::new();
    let main = Repository::open(&fixture.target_path).unwrap();
    let commit = main.find_commit(fixture.target_head).unwrap();
    let branch = main.branch("linked", &commit, false).unwrap();
    let linked_path = fixture._temp.path().join("linked");
    let mut options = git2::WorktreeAddOptions::new();
    options.reference(Some(branch.get()));
    main.worktree("linked", &linked_path, Some(&options))
        .unwrap();
    drop(branch);
    drop(commit);
    drop(main);

    let linked_before = worktree_snapshot(&linked_path);
    let main_before = protected_snapshot(&fixture.target_path);
    let tip = commit_file(&fixture.source, "remote.txt", b"remote\n");
    let bytes = pack(&fixture.source, tip);
    let state = fixture._temp.path().join("linked-state");
    create_state(&state);
    let plane = GitReplicationPlane::open(&linked_path, &state, [0x42; 32]).unwrap();
    let destination = plane
        .replicate(
            [50; 16],
            &GitAdvertisement {
                original_ref: "refs/heads/main".into(),
                tip,
                expected_mesh_tip: None,
            },
            bytes.as_slice(),
        )
        .unwrap();
    assert_eq!(
        Repository::open(&fixture.target_path)
            .unwrap()
            .refname_to_id(&destination)
            .unwrap(),
        tip
    );
    assert_eq!(worktree_snapshot(&linked_path), linked_before);
    assert_eq!(protected_snapshot(&fixture.target_path), main_before);
}

#[test]
fn state_and_child_symlinks_never_touch_external_files() {
    let temp = TempDir::new().unwrap();
    let repository_path = temp.path().join("repository");
    Repository::init(&repository_path).unwrap();
    let external = temp.path().join("external");
    create_state(&external);
    let marker = external.join("marker");
    fs::write(&marker, b"keep").unwrap();

    let root_link = temp.path().join("state-link");
    std::os::unix::fs::symlink(&external, &root_link).unwrap();
    assert!(GitReplicationPlane::open(&repository_path, &root_link, [1; 32]).is_err());
    assert_eq!(fs::read(&marker).unwrap(), b"keep");

    let child_state = temp.path().join("child-state");
    create_state(&child_state);
    std::os::unix::fs::symlink(&external, child_state.join("git-journals")).unwrap();
    assert!(GitReplicationPlane::open(&repository_path, &child_state, [1; 32]).is_err());
    assert_eq!(fs::read(&marker).unwrap(), b"keep");

    let quarantine_state = temp.path().join("quarantine-state");
    create_state(&quarantine_state);
    fs::create_dir(quarantine_state.join("git-journals")).unwrap();
    fs::set_permissions(
        quarantine_state.join("git-journals"),
        fs::Permissions::from_mode(0o700),
    )
    .unwrap();
    fs::create_dir(quarantine_state.join("git-quarantine")).unwrap();
    fs::set_permissions(
        quarantine_state.join("git-quarantine"),
        fs::Permissions::from_mode(0o700),
    )
    .unwrap();
    std::os::unix::fs::symlink(
        &external,
        quarantine_state
            .join("git-quarantine")
            .join("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    )
    .unwrap();
    assert!(GitReplicationPlane::open(&repository_path, &quarantine_state, [1; 32]).is_err());
    assert_eq!(fs::read(&marker).unwrap(), b"keep");
}

struct SwapStateRoot {
    path: std::path::PathBuf,
    backup: std::path::PathBuf,
}

impl GitCrashHook for SwapStateRoot {
    fn after_phase(&self, phase: GitPhase) -> Result<(), GitError> {
        if phase == GitPhase::Prepared {
            fs::rename(&self.path, &self.backup).unwrap();
            create_state(&self.path);
        }
        Ok(())
    }
}

#[test]
fn replaced_state_root_is_rejected_before_libgit2_path_write() {
    let fixture = Fixture::new();
    let tip = commit_file(&fixture.source, "remote.txt", b"remote\n");
    let bytes = pack(&fixture.source, tip);
    let backup = fixture._temp.path().join("state-backup");
    let outside = fixture._temp.path().join("outside-marker");
    fs::write(&outside, b"keep").unwrap();
    let result = fixture.plane().replicate_with_hook(
        [0x5b; 16],
        &GitAdvertisement {
            original_ref: "refs/heads/main".into(),
            tip,
            expected_mesh_tip: None,
        },
        bytes.as_slice(),
        &SwapStateRoot {
            path: fixture.state_path.clone(),
            backup,
        },
    );
    assert!(matches!(result, Err(GitError::StateReplaced)));
    assert!(fs::read_dir(&fixture.state_path).unwrap().next().is_none());
    assert_eq!(fs::read(outside).unwrap(), b"keep");
}

#[test]
fn journal_destination_symlink_is_rejected_without_following_it() {
    let fixture = Fixture::new();
    let tip = commit_file(&fixture.source, "remote.txt", b"remote\n");
    let bytes = pack(&fixture.source, tip);
    let external = fixture._temp.path().join("outside");
    fs::write(&external, b"keep").unwrap();
    fs::create_dir(fixture.state_path.join("git-journals")).unwrap();
    fs::set_permissions(
        fixture.state_path.join("git-journals"),
        fs::Permissions::from_mode(0o700),
    )
    .unwrap();
    std::os::unix::fs::symlink(
        &external,
        fixture
            .state_path
            .join("git-journals")
            .join("5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a.json"),
    )
    .unwrap();
    let result = fixture.plane().replicate(
        [0x5a; 16],
        &GitAdvertisement {
            original_ref: "refs/heads/main".into(),
            tip,
            expected_mesh_tip: None,
        },
        bytes.as_slice(),
    );
    assert!(result.is_err());
    assert_eq!(fs::read(external).unwrap(), b"keep");
}

struct ExitAfter(GitPhase);
impl GitCrashHook for ExitAfter {
    fn after_phase(&self, phase: GitPhase) -> Result<(), GitError> {
        if phase == self.0 {
            unsafe { libc::_exit(86) }
        }
        Ok(())
    }
}

#[test]
fn subprocess_crash_helper() {
    let Ok(phase) = std::env::var("TM_GIT_CRASH_PHASE") else {
        return;
    };
    let phase = match phase.as_str() {
        "quarantined" => GitPhase::Quarantined,
        "promoting" => GitPhase::Promoting,
        "imported" => GitPhase::Imported,
        "packed_ref_lock" => GitPhase::PackedRefLock,
        "loose_ref_lock" => GitPhase::LooseRefLock,
        "ref_rename" => GitPhase::RefRename,
        "ref_cas" => GitPhase::RefCas,
        "ref_updated" => GitPhase::RefUpdated,
        _ => panic!("invalid phase"),
    };
    let repository = std::path::PathBuf::from(std::env::var("TM_GIT_REPOSITORY").unwrap());
    let state = std::path::PathBuf::from(std::env::var("TM_GIT_STATE").unwrap());
    let pack = fs::read(std::env::var("TM_GIT_PACK").unwrap()).unwrap();
    let tip = Oid::from_str(&std::env::var("TM_GIT_TIP").unwrap()).unwrap();
    let operation = hex::decode(std::env::var("TM_GIT_OPERATION").unwrap()).unwrap();
    let operation: [u8; 16] = operation.try_into().unwrap();
    GitReplicationPlane::open(&repository, &state, [0x66; 32])
        .unwrap()
        .replicate_with_hook(
            operation,
            &GitAdvertisement {
                original_ref: "refs/heads/main".into(),
                tip,
                expected_mesh_tip: None,
            },
            pack.as_slice(),
            &ExitAfter(phase),
        )
        .unwrap();
    panic!("crash hook did not exit")
}

#[test]
fn subprocess_crash_boundaries_reopen_and_converge() {
    for (index, phase) in [
        "quarantined",
        "promoting",
        "imported",
        "packed_ref_lock",
        "loose_ref_lock",
        "ref_rename",
        "ref_cas",
        "ref_updated",
    ]
    .into_iter()
    .enumerate()
    {
        let fixture = Fixture::new();
        let tip = commit_file(&fixture.source, "remote.txt", b"remote\n");
        let bytes = pack(&fixture.source, tip);
        let pack_path = fixture._temp.path().join("input.pack");
        fs::write(&pack_path, &bytes).unwrap();
        let operation = [0x70 + index as u8; 16];
        let home = fixture._temp.path().join("home");
        let xdg = fixture._temp.path().join("xdg");
        fs::create_dir(&home).unwrap();
        fs::create_dir(&xdg).unwrap();
        let status = Command::new(std::env::current_exe().unwrap())
            .arg("--exact")
            .arg("subprocess_crash_helper")
            .arg("--nocapture")
            .env_clear()
            .env("HOME", &home)
            .env("XDG_CONFIG_HOME", &xdg)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_NO_REPLACE_OBJECTS", "1")
            .env("TM_GIT_CRASH_PHASE", phase)
            .env("TM_GIT_REPOSITORY", &fixture.target_path)
            .env("TM_GIT_STATE", &fixture.state_path)
            .env("TM_GIT_PACK", &pack_path)
            .env("TM_GIT_TIP", tip.to_string())
            .env("TM_GIT_OPERATION", hex::encode(operation))
            .status()
            .unwrap();
        assert_eq!(status.code(), Some(86));

        let plane =
            GitReplicationPlane::open(&fixture.target_path, &fixture.state_path, [0x66; 32])
                .unwrap();
        let destination = plane.destination_ref("refs/heads/main").unwrap();
        let current = Repository::open(&fixture.target_path)
            .unwrap()
            .find_reference(&destination)
            .ok()
            .and_then(|reference| reference.target());
        if matches!(phase, "ref_rename" | "ref_cas" | "ref_updated") {
            assert_eq!(current, Some(tip));
        } else {
            assert_eq!(current, None);
        }
        let destination = plane
            .replicate(
                operation,
                &GitAdvertisement {
                    original_ref: "refs/heads/main".into(),
                    tip,
                    expected_mesh_tip: None,
                },
                bytes.as_slice(),
            )
            .unwrap();
        assert_eq!(
            Repository::open(&fixture.target_path)
                .unwrap()
                .refname_to_id(&destination)
                .unwrap(),
            tip
        );
        assert!(fs::read_dir(fixture.state_path.join("git-quarantine"))
            .unwrap()
            .next()
            .is_none());
    }
}

#[test]
fn repeated_stale_operations_do_not_accumulate_pack_files() {
    let fixture = Fixture::new();
    let tip = commit_file(&fixture.source, "remote.txt", b"remote\n");
    let bytes = pack(&fixture.source, tip);
    let plane = fixture.plane();
    let pack_dir = Repository::open(&fixture.target_path)
        .unwrap()
        .path()
        .join("objects/pack");
    let pack_files_before = fs::read_dir(&pack_dir).unwrap().count();
    let before = Repository::open(&fixture.target_path)
        .unwrap()
        .odb()
        .unwrap()
        .exists(tip);
    for index in 0..20u8 {
        assert!(matches!(
            plane.replicate(
                [0x90 + index; 16],
                &GitAdvertisement {
                    original_ref: "refs/heads/main".into(),
                    tip,
                    expected_mesh_tip: Some(Oid::zero()),
                },
                bytes.as_slice(),
            ),
            Err(GitError::StaleRef)
        ));
    }
    assert_eq!(
        Repository::open(&fixture.target_path)
            .unwrap()
            .odb()
            .unwrap()
            .exists(tip),
        before
    );
    assert_eq!(fs::read_dir(pack_dir).unwrap().count(), pack_files_before);
}

struct RaceMeshRef {
    repository: std::path::PathBuf,
    destination: String,
    next: Oid,
}

impl GitCrashHook for RaceMeshRef {
    fn after_phase(&self, phase: GitPhase) -> Result<(), GitError> {
        if phase == GitPhase::Imported {
            Repository::open(&self.repository)
                .unwrap()
                .reference(&self.destination, self.next, true, "race fixture")
                .unwrap();
        }
        Ok(())
    }
}

#[test]
fn unique_orphan_packs_hit_durable_budget_without_deleting_shared_objects() {
    let fixture = Fixture::new();
    let plane = fixture.plane();
    let destination = plane.destination_ref("refs/heads/main").unwrap();
    let target = Repository::open(&fixture.target_path).unwrap();
    let blocker_a = target.blob(b"blocker-a").unwrap();
    let blocker_b = target.blob(b"blocker-b").unwrap();
    target
        .reference(&destination, blocker_a, false, "fixture")
        .unwrap();
    let pack_dir = target.path().join("objects/pack");
    let initial_packs = fs::read_dir(&pack_dir)
        .unwrap()
        .filter(|entry| entry.as_ref().unwrap().path().extension() == Some("pack".as_ref()))
        .count();
    drop(target);

    let mut current = blocker_a;
    let mut rejected_tip = None;
    for index in 0..24u8 {
        let tip = commit_file(
            &fixture.source,
            &format!("remote-{index}.txt"),
            format!("remote-{index}\n").as_bytes(),
        );
        let bytes = pack(&fixture.source, tip);
        let next = if current == blocker_a {
            blocker_b
        } else {
            blocker_a
        };
        let result = plane.replicate_with_hook(
            [index; 16],
            &GitAdvertisement {
                original_ref: "refs/heads/main".into(),
                tip,
                expected_mesh_tip: Some(current),
            },
            bytes.as_slice(),
            &RaceMeshRef {
                repository: fixture.target_path.clone(),
                destination: destination.clone(),
                next,
            },
        );
        match result {
            Err(GitError::StaleRef) => current = next,
            Err(GitError::OrphanBudgetExceeded) => {
                rejected_tip = Some(tip);
                break;
            }
            other => panic!("unexpected result: {other:?}"),
        }
    }
    if rejected_tip.is_none() {
        let summaries = fs::read_dir(fixture.state_path.join("git-journals"))
            .unwrap()
            .map(|entry| {
                let value: serde_json::Value =
                    serde_json::from_slice(&fs::read(entry.unwrap().path()).unwrap()).unwrap();
                (
                    value["phase"].clone(),
                    value["newly_created"].clone(),
                    value["pack_checksum"].clone(),
                )
            })
            .collect::<Vec<_>>();
        panic!("orphan budget must fail closed: {summaries:?}");
    }
    let rejected_tip = rejected_tip.unwrap();
    assert!(!Repository::open(&fixture.target_path)
        .unwrap()
        .odb()
        .unwrap()
        .exists(rejected_tip));
    let final_packs = fs::read_dir(pack_dir)
        .unwrap()
        .filter(|entry| entry.as_ref().unwrap().path().extension() == Some("pack".as_ref()))
        .count();
    assert!(final_packs <= initial_packs + 16);
    assert_eq!(
        Repository::open(&fixture.target_path)
            .unwrap()
            .odb()
            .unwrap()
            .read(blocker_a)
            .unwrap()
            .data(),
        b"blocker-a"
    );
}

#[test]
fn orphan_budget_is_global_across_sequential_peers() {
    let fixture = Fixture::new();
    for index in 0..16u8 {
        let tip = commit_file(
            &fixture.source,
            &format!("peer-{index}.txt"),
            format!("peer-{index}\n").as_bytes(),
        );
        let bytes = pack(&fixture.source, tip);
        let plane =
            GitReplicationPlane::open(&fixture.target_path, &fixture.state_path, [index + 1; 32])
                .unwrap();
        assert!(plane
            .replicate_with_hook(
                [index; 16],
                &GitAdvertisement {
                    original_ref: "refs/heads/main".into(),
                    tip,
                    expected_mesh_tip: None,
                },
                bytes.as_slice(),
                &CrashAfter(GitPhase::Promoting),
            )
            .is_err());
        drop(plane);
    }

    let tip = commit_file(&fixture.source, "peer-overflow.txt", b"overflow\n");
    let bytes = pack(&fixture.source, tip);
    let result = GitReplicationPlane::open(&fixture.target_path, &fixture.state_path, [0xee; 32])
        .unwrap()
        .replicate(
            [0xee; 16],
            &GitAdvertisement {
                original_ref: "refs/heads/main".into(),
                tip,
                expected_mesh_tip: None,
            },
            bytes.as_slice(),
        );
    assert!(matches!(result, Err(GitError::OrphanBudgetExceeded)));
}

struct SwapRepositoryAtPromoteWrite {
    repository: std::path::PathBuf,
    original: std::path::PathBuf,
    attacker: std::path::PathBuf,
}

struct SwapGitDirAtQuarantined {
    repository: std::path::PathBuf,
    original_git: std::path::PathBuf,
    attacker: std::path::PathBuf,
}

impl GitCrashHook for SwapGitDirAtQuarantined {
    fn after_phase(&self, phase: GitPhase) -> Result<(), GitError> {
        if phase == GitPhase::Quarantined {
            fs::rename(self.repository.join(".git"), &self.original_git).unwrap();
            fs::rename(self.attacker.join(".git"), self.repository.join(".git")).unwrap();
        }
        Ok(())
    }
}

#[test]
fn git_dir_swap_is_rejected_by_descriptor_relative_common_binding() {
    let fixture = Fixture::new();
    let tip = commit_file(&fixture.source, "remote.txt", b"remote\n");
    let bytes = pack(&fixture.source, tip);
    let attacker = fixture._temp.path().join("gitdir-attacker");
    let attacker_repository = Repository::init(&attacker).unwrap();
    let attacker_head = commit_file(&attacker_repository, "attacker.txt", b"keep\n");
    drop(attacker_repository);
    let original_git = fixture._temp.path().join("target-original.git");
    let plane = fixture.plane();
    let destination = plane.destination_ref("refs/heads/main").unwrap();
    let result = plane.replicate_with_hook(
        [0xd0; 16],
        &GitAdvertisement {
            original_ref: "refs/heads/main".into(),
            tip,
            expected_mesh_tip: None,
        },
        bytes.as_slice(),
        &SwapGitDirAtQuarantined {
            repository: fixture.target_path.clone(),
            original_git: original_git.clone(),
            attacker: attacker.clone(),
        },
    );
    assert!(matches!(result, Err(GitError::StateReplaced)));
    drop(plane);

    fs::rename(fixture.target_path.join(".git"), attacker.join(".git")).unwrap();
    fs::rename(&original_git, fixture.target_path.join(".git")).unwrap();
    let attacker_repository = Repository::open(&attacker).unwrap();
    assert_eq!(
        attacker_repository.head().unwrap().target(),
        Some(attacker_head)
    );
    assert!(!attacker_repository.odb().unwrap().exists(tip));
    assert!(attacker_repository.find_reference(&destination).is_err());
    assert!(Repository::open(&fixture.target_path)
        .unwrap()
        .find_reference(&destination)
        .is_err());
}

impl GitCrashHook for SwapRepositoryAtPromoteWrite {
    fn after_phase(&self, phase: GitPhase) -> Result<(), GitError> {
        if phase == GitPhase::PromoteWrite {
            fs::rename(&self.repository, &self.original).unwrap();
            fs::rename(&self.attacker, &self.repository).unwrap();
        }
        Ok(())
    }
}

#[test]
fn swap_after_descriptor_check_cannot_redirect_object_or_ref_writes() {
    let fixture = Fixture::new();
    let tip = commit_file(&fixture.source, "remote.txt", b"remote\n");
    let bytes = pack(&fixture.source, tip);
    let original = fixture._temp.path().join("target-original");
    let attacker = fixture._temp.path().join("attacker");
    let attacker_repository = Repository::init(&attacker).unwrap();
    let attacker_head = commit_file(&attacker_repository, "attacker.txt", b"keep\n");
    drop(attacker_repository);
    let plane = fixture.plane();
    let advertisement = GitAdvertisement {
        original_ref: "refs/heads/main".into(),
        tip,
        expected_mesh_tip: None,
    };
    let destination = plane.destination_ref(&advertisement.original_ref).unwrap();
    let result = plane.replicate_with_hook(
        [0xd1; 16],
        &advertisement,
        bytes.as_slice(),
        &SwapRepositoryAtPromoteWrite {
            repository: fixture.target_path.clone(),
            original: original.clone(),
            attacker: attacker.clone(),
        },
    );
    assert!(matches!(result, Err(GitError::StateReplaced)));
    drop(plane);

    let displaced_attacker = fixture._temp.path().join("attacker-restored");
    fs::rename(&fixture.target_path, &displaced_attacker).unwrap();
    fs::rename(&original, &fixture.target_path).unwrap();
    let attacker_repository = Repository::open(&displaced_attacker).unwrap();
    assert!(!attacker_repository.odb().unwrap().exists(tip));
    assert_eq!(
        attacker_repository.head().unwrap().target(),
        Some(attacker_head)
    );
    assert!(attacker_repository.find_reference(&destination).is_err());
    assert!(Repository::open(&fixture.target_path)
        .unwrap()
        .odb()
        .unwrap()
        .exists(tip));
}

#[test]
fn thin_pack_resolves_existing_base_without_path_writes() {
    let fixture = Fixture::new();
    let base = commit_file(&fixture.source, "remote.txt", b"base\n");
    let base_pack = pack(&fixture.source, base);
    fixture
        .plane()
        .replicate(
            [0xe1; 16],
            &GitAdvertisement {
                original_ref: "refs/heads/base".into(),
                tip: base,
                expected_mesh_tip: None,
            },
            base_pack.as_slice(),
        )
        .unwrap();
    let tip = commit_file(&fixture.source, "remote.txt", b"base plus delta\n");
    let mut child = Command::new("git")
        .args(["pack-objects", "--thin", "--stdout", "--revs"])
        .current_dir(fixture.source.workdir().unwrap())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    writeln!(child.stdin.take().unwrap(), "{tip}\n^{base}").unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    fixture
        .plane()
        .replicate(
            [0xe2; 16],
            &GitAdvertisement {
                original_ref: "refs/heads/main".into(),
                tip,
                expected_mesh_tip: None,
            },
            output.stdout.as_slice(),
        )
        .unwrap();
    assert!(Repository::open(&fixture.target_path)
        .unwrap()
        .find_commit(tip)
        .is_ok());
}

#[test]
fn repeated_pack_ingestion_stays_in_safe_parser_path() {
    let fixture = Fixture::new();
    let tip = commit_file(&fixture.source, "remote.txt", b"remote\n");
    let bytes = pack(&fixture.source, tip);
    for index in 0..8u8 {
        fixture
            .plane()
            .replicate(
                [0xf0 + index; 16],
                &GitAdvertisement {
                    original_ref: format!("refs/heads/branch-{index}"),
                    tip,
                    expected_mesh_tip: None,
                },
                bytes.as_slice(),
            )
            .unwrap();
    }
}

#[test]
fn startup_sweeps_only_validated_loose_object_temps() {
    let fixture = Fixture::new();
    let loose = Repository::open(&fixture.target_path)
        .unwrap()
        .path()
        .join("objects/aa");
    fs::create_dir_all(&loose).unwrap();
    let valid = loose.join(format!(".tmp-{}", "a".repeat(32)));
    fs::write(&valid, b"partial").unwrap();
    let plane = fixture.plane();
    assert!(!valid.exists());
    drop(plane);

    let hostile = Fixture::new();
    let loose = Repository::open(&hostile.target_path)
        .unwrap()
        .path()
        .join("objects/bb");
    fs::create_dir_all(&loose).unwrap();
    let malformed = loose.join(".tmp-not-an-operation");
    fs::write(&malformed, b"keep").unwrap();
    assert!(
        GitReplicationPlane::open(&hostile.target_path, &hostile.state_path, [0x23; 32]).is_err()
    );
    assert_eq!(fs::read(malformed).unwrap(), b"keep");
}

#[test]
fn live_but_aged_ref_lock_is_never_recovered() {
    let fixture = Fixture::new();
    let tip = commit_file(&fixture.source, "remote.txt", b"remote\n");
    let bytes = pack(&fixture.source, tip);
    let operation = [0xb1; 16];
    let plane = fixture.plane();
    let advertisement = GitAdvertisement {
        original_ref: "refs/heads/main".into(),
        tip,
        expected_mesh_tip: None,
    };
    assert!(matches!(
        plane.replicate_with_hook(
            operation,
            &advertisement,
            bytes.as_slice(),
            &CrashAfter(GitPhase::Imported),
        ),
        Err(GitError::Crash)
    ));
    let destination = plane.destination_ref(&advertisement.original_ref).unwrap();
    let common = Repository::open(&fixture.target_path)
        .unwrap()
        .path()
        .to_owned();
    let lock = common.join("packed-refs.lock");
    fs::write(
        &lock,
        format!(
            "term-mesh-ref-lock-v1 {} {} 0 {tip} {destination}\n",
            hex::encode(operation),
            unsafe { libc::getpid() }
        ),
    )
    .unwrap();
    fs::set_permissions(&lock, fs::Permissions::from_mode(0o600)).unwrap();

    assert!(matches!(
        plane.replicate(operation, &advertisement, bytes.as_slice()),
        Err(GitError::RefLocked)
    ));
    assert!(lock.exists());
}

struct RacePackedMeshRef {
    packed_refs: std::path::PathBuf,
    destination: String,
    next: Oid,
}

impl GitCrashHook for RacePackedMeshRef {
    fn after_phase(&self, phase: GitPhase) -> Result<(), GitError> {
        if phase == GitPhase::Imported {
            let contents = fs::read_to_string(&self.packed_refs).unwrap();
            let mut replaced = false;
            let rewritten = contents
                .lines()
                .map(|line| {
                    if line
                        .split_once(' ')
                        .is_some_and(|(_, name)| name == self.destination)
                    {
                        replaced = true;
                        format!("{} {}", self.next, self.destination)
                    } else {
                        line.to_owned()
                    }
                })
                .collect::<Vec<_>>()
                .join("\n");
            assert!(replaced);
            fs::write(&self.packed_refs, format!("{rewritten}\n")).unwrap();
        }
        Ok(())
    }
}

#[test]
fn packed_ref_race_is_rechecked_under_effective_cas_locks() {
    let fixture = Fixture::new();
    let first = commit_file(&fixture.source, "remote.txt", b"first\n");
    let first_pack = pack(&fixture.source, first);
    let plane = fixture.plane();
    let destination = plane
        .replicate(
            [0xa1; 16],
            &GitAdvertisement {
                original_ref: "refs/heads/main".into(),
                tip: first,
                expected_mesh_tip: None,
            },
            first_pack.as_slice(),
        )
        .unwrap();
    let status = Command::new("git")
        .args(["pack-refs", "--all", "--prune"])
        .current_dir(&fixture.target_path)
        .status()
        .unwrap();
    assert!(status.success());
    let common = Repository::open(&fixture.target_path)
        .unwrap()
        .path()
        .to_owned();
    assert!(!common.join(&destination).exists());

    let second = commit_file(&fixture.source, "remote.txt", b"second\n");
    let second_pack = pack(&fixture.source, second);
    let result = plane.replicate_with_hook(
        [0xa2; 16],
        &GitAdvertisement {
            original_ref: "refs/heads/main".into(),
            tip: second,
            expected_mesh_tip: Some(first),
        },
        second_pack.as_slice(),
        &RacePackedMeshRef {
            packed_refs: common.join("packed-refs"),
            destination: destination.clone(),
            next: fixture.target_head,
        },
    );
    assert!(matches!(result, Err(GitError::StaleRef)));
    assert_eq!(
        Repository::open(&fixture.target_path)
            .unwrap()
            .refname_to_id(&destination)
            .unwrap(),
        fixture.target_head
    );
    assert!(!common.join(destination).exists());
}
