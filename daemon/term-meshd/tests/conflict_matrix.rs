#[path = "../src/sync/mod.rs"]
mod sync;

use sync::{
    detect_path_conflicts, merge_file, ConflictContent, ConflictError, ConflictKind,
    ConflictRecord, ConflictResolution, ConflictSet, MergeOutcome, ObjectDomain, ObjectId,
    ObjectType, PathChange, ProjectId, ThreeWayFile,
};

fn domain() -> ObjectDomain {
    ObjectDomain {
        project_id: ProjectId::from_bytes([91; 32]),
        object_type: ObjectType::FILE,
        version: 1,
    }
}

fn content(bytes: &[u8], executable: bool) -> ConflictContent {
    content_in(domain(), bytes, executable)
}

fn content_in(domain: ObjectDomain, bytes: &[u8], executable: bool) -> ConflictContent {
    ConflictContent::new(
        domain,
        ObjectId::for_plaintext(domain, bytes),
        bytes.to_vec(),
        executable,
    )
    .unwrap()
}

fn file(
    path: &str,
    base: Option<ConflictContent>,
    local: Option<ConflictContent>,
    remote: Option<ConflictContent>,
) -> ThreeWayFile {
    ThreeWayFile::new(domain(), path.to_owned(), base, local, remote).unwrap()
}

fn change(base: &str, local: Option<&str>, remote: Option<&str>) -> PathChange {
    PathChange::new(
        base.to_owned(),
        local.map(str::to_owned),
        remote.map(str::to_owned),
    )
    .unwrap()
}

fn conflict(outcome: MergeOutcome) -> ConflictRecord {
    match outcome {
        MergeOutcome::Conflict(conflict) => conflict,
        MergeOutcome::Resolved(value) => panic!("expected conflict, got {value:?}"),
    }
}

#[test]
fn unresolved_text_preserves_base_local_and_remote_bytes_exactly() {
    let base = content(b"base\nall bytes\n", false);
    let local = content(b"local\nkept 100%\n", false);
    let remote = content(b"remote\nkept 100%\n", false);
    let found = conflict(
        merge_file(file(
            "notes.txt",
            Some(base.clone()),
            Some(local.clone()),
            Some(remote.clone()),
        ))
        .unwrap(),
    );
    assert_eq!(found.kind(), &ConflictKind::Text);
    assert_eq!(found.base(), Some(&base));
    assert_eq!(found.local(), Some(&local));
    assert_eq!(found.remote(), Some(&remote));
}

#[test]
fn binary_conflict_preserves_both_verified_content_roots() {
    let base = content(b"\0base", false);
    let local = content(b"\0local-binary", false);
    let remote = content(b"\0remote-binary", false);
    let found = conflict(
        merge_file(file(
            "asset.bin",
            Some(base),
            Some(local.clone()),
            Some(remote.clone()),
        ))
        .unwrap(),
    );
    assert_eq!(found.kind(), &ConflictKind::Binary);
    assert_eq!(found.local().unwrap().content_root(), local.content_root());
    assert_eq!(
        found.remote().unwrap().content_root(),
        remote.content_root()
    );
    assert_eq!(found.local().unwrap().bytes(), local.bytes());
    assert_eq!(found.remote().unwrap().bytes(), remote.bytes());
}

#[test]
fn no_base_add_add_never_overwrites_local_text_or_binary() {
    for (path, local, remote, expected) in [
        (
            "new.txt",
            content(b"local text", false),
            content(b"remote text", false),
            ConflictKind::AddAddText,
        ),
        (
            "new.bin",
            content(b"\0local", false),
            content(b"\0remote", false),
            ConflictKind::AddAddBinary,
        ),
    ] {
        let found = conflict(
            merge_file(file(path, None, Some(local.clone()), Some(remote.clone()))).unwrap(),
        );
        assert_eq!(found.kind(), &expected);
        assert_eq!(found.local(), Some(&local));
        assert_eq!(found.remote(), Some(&remote));
    }
}

#[test]
fn delete_modify_and_executable_bit_are_typed_conflicts() {
    let base = content(b"base", false);
    let modified = content(b"modified", false);
    let deleted_local = conflict(
        merge_file(file(
            "file",
            Some(base.clone()),
            None,
            Some(modified.clone()),
        ))
        .unwrap(),
    );
    assert!(matches!(
        deleted_local.kind(),
        ConflictKind::DeleteModify {
            deleted: sync::ConflictSide::Local
        }
    ));
    let executable = conflict(
        merge_file(file(
            "script",
            Some(base),
            Some(modified),
            Some(content(b"base", true)),
        ))
        .unwrap(),
    );
    assert_eq!(executable.kind(), &ConflictKind::ExecutableBit);
}

#[test]
fn scanner_canonical_key_detects_case_nfc_and_composite_collisions() {
    let conflicts = detect_path_conflicts(
        domain(),
        &[
            change("a", Some("b"), Some("a")),
            change("b", Some("a"), Some("b")),
            change("case", Some("Readme"), Some("README")),
            change("nfc", Some("n/café"), Some("n/cafe\u{301}")),
            change("mixed", Some("m/CAFÉ"), Some("m/cafe\u{301}")),
        ],
    )
    .unwrap();
    for expected in [
        ConflictKind::RenameCycle,
        ConflictKind::CaseCollision,
        ConflictKind::UnicodeNormalization,
        ConflictKind::UnicodeCaseCollision,
    ] {
        assert!(conflicts
            .iter()
            .any(|conflict| conflict.kind() == &expected));
    }
}

#[test]
fn every_base_local_remote_path_is_validated_before_detection() {
    for invalid in ["../escape", "/absolute", "nul\0path", "a//b", "a/./b"] {
        assert_eq!(
            PathChange::new(invalid.to_owned(), Some("ok".to_owned()), None),
            Err(ConflictError::InvalidPath)
        );
        assert_eq!(
            PathChange::new("ok".to_owned(), Some(invalid.to_owned()), None),
            Err(ConflictError::InvalidPath)
        );
        assert_eq!(
            PathChange::new("ok".to_owned(), None, Some(invalid.to_owned())),
            Err(ConflictError::InvalidPath)
        );
        assert!(matches!(
            ThreeWayFile::new(domain(), invalid.to_owned(), None, None, None),
            Err(ConflictError::InvalidPath)
        ));
    }
}

#[test]
fn content_roots_and_conflict_shapes_are_fail_closed() {
    assert_eq!(
        ConflictContent::new(domain(), ObjectId([0; 32]), b"bytes".to_vec(), false),
        Err(ConflictError::ContentRootMismatch)
    );
    assert_eq!(
        ConflictRecord::new(
            domain(),
            ConflictKind::Text,
            vec!["file".to_owned()],
            None,
            None,
            None
        ),
        Err(ConflictError::InvalidConflictShape)
    );
}

#[test]
fn per_item_and_aggregate_budgets_reject_before_merge_cloning() {
    assert!(matches!(
        PathChange::new("x".repeat(sync::MAX_CONFLICT_PATH_BYTES + 1), None, None),
        Err(ConflictError::BudgetExceeded)
    ));
    assert_eq!(
        ConflictContent::new(
            domain(),
            ObjectId([0; 32]),
            vec![0; sync::MAX_CONFLICT_CONTENT_BYTES + 1],
            false
        ),
        Err(ConflictError::BudgetExceeded)
    );

    let chunk = vec![b'x'; 3 * 1024 * 1024];
    let large = || content(&chunk, false);
    assert!(matches!(
        ThreeWayFile::new(
            domain(),
            "large".to_owned(),
            Some(large()),
            Some(large()),
            Some(large())
        ),
        Err(ConflictError::BudgetExceeded)
    ));

    let path = "p".repeat(sync::MAX_CONFLICT_PATH_BYTES - 32);
    let count = sync::MAX_PATH_CHANGE_TOTAL_BYTES / path.len() + 1;
    let changes: Vec<_> = (0..count)
        .map(|index| change(&format!("{index}-{path}"), None, None))
        .collect();
    assert_eq!(
        detect_path_conflicts(domain(), &changes),
        Err(ConflictError::BudgetExceeded)
    );
}

fn large_conflict(path: &str, seed: u8) -> ConflictRecord {
    let make = |marker: u8| {
        let mut bytes = vec![seed; 1024 * 1024];
        bytes[0] = marker;
        let domain = domain();
        ConflictContent::new(
            domain,
            ObjectId::for_plaintext(domain, &bytes),
            bytes,
            false,
        )
        .unwrap()
    };
    conflict(merge_file(file(path, Some(make(1)), Some(make(2)), Some(make(3)))).unwrap())
}

#[test]
fn conflict_set_aggregate_budget_rejects_without_revision_mutation() {
    let mut conflicts = ConflictSet::new(domain()).unwrap();
    conflicts.insert(large_conflict("one", 1)).unwrap();
    conflicts.insert(large_conflict("two", 2)).unwrap();
    let revision = conflicts.revision();
    let len = conflicts.len();
    assert_eq!(
        conflicts.insert(large_conflict("three", 3)),
        Err(ConflictError::BudgetExceeded)
    );
    assert_eq!(conflicts.revision(), revision);
    assert_eq!(conflicts.len(), len);
}

#[test]
fn duplicate_insert_and_stale_resolution_have_exact_revision_semantics() {
    let first = conflict(
        merge_file(file(
            "file",
            Some(content(b"base", false)),
            Some(content(b"local", false)),
            Some(content(b"remote", false)),
        ))
        .unwrap(),
    );
    let second = conflict(
        merge_file(file(
            "other",
            Some(content(b"base2", false)),
            Some(content(b"local2", false)),
            Some(content(b"remote2", false)),
        ))
        .unwrap(),
    );
    let mut conflicts = ConflictSet::new(domain()).unwrap();
    let first_precondition = conflicts.insert(first.clone()).unwrap();
    let inserted_revision = conflicts.revision();
    assert_eq!(conflicts.insert(first.clone()).unwrap(), first_precondition);
    assert_eq!(conflicts.revision(), inserted_revision);

    let wrong_precondition = second.precondition();
    let before_len = conflicts.len();
    assert_eq!(
        conflicts.resolve(wrong_precondition, ConflictResolution::KeepRemote),
        Err(ConflictError::StaleResolution)
    );
    assert_eq!(conflicts.revision(), inserted_revision);
    assert_eq!(conflicts.len(), before_len);
    assert_eq!(conflicts.get(first.conflict_id()), Some(&first));

    let resolved = conflicts
        .resolve(first_precondition, ConflictResolution::KeepLocal)
        .unwrap();
    assert_eq!(resolved.content(), first.local());
    let resolved_revision = conflicts.revision();
    assert_eq!(
        conflicts.resolve(first_precondition, ConflictResolution::KeepRemote),
        Err(ConflictError::StaleResolution)
    );
    assert_eq!(conflicts.revision(), resolved_revision);
}

#[test]
fn distinct_sources_targeting_the_same_exact_path_are_typed_conflicts() {
    let conflicts = detect_path_conflicts(
        domain(),
        &[
            change("source-a", Some("shared-target"), None),
            change("source-b", None, Some("shared-target")),
        ],
    )
    .unwrap();
    let collision = conflicts
        .iter()
        .find(|conflict| conflict.kind() == &ConflictKind::ExactPathCollision)
        .expect("exact duplicate target must conflict");
    assert_eq!(
        collision.paths(),
        &["shared-target", "source-a", "source-b"]
    );
    assert_eq!(collision.path_origins().len(), 2);
    assert_eq!(collision.path_origins()[0].source_path(), "source-a");
    assert_eq!(collision.path_origins()[0].target_path(), "shared-target");
    assert_eq!(
        collision.path_origins()[0].side(),
        sync::ConflictSide::Local
    );
    assert_eq!(collision.path_origins()[1].source_path(), "source-b");
    assert_eq!(
        collision.path_origins()[1].side(),
        sync::ConflictSide::Remote
    );
}

#[test]
fn ten_thousand_rename_chain_is_iterative_and_does_not_overflow_the_stack() {
    let changes: Vec<_> = (0..10_000)
        .map(|index| {
            change(
                &format!("node-{index:05}"),
                Some(&format!("node-{:05}", index + 1)),
                None,
            )
        })
        .collect();
    let conflicts = detect_path_conflicts(domain(), &changes).unwrap();
    assert!(!conflicts
        .iter()
        .any(|conflict| conflict.kind() == &ConflictKind::RenameCycle));
}

#[test]
fn conflict_domains_and_file_object_type_are_enforced_at_every_boundary() {
    let foreign_domain = ObjectDomain {
        project_id: ProjectId::from_bytes([92; 32]),
        ..domain()
    };
    let non_file_domain = ObjectDomain {
        object_type: ObjectType::CONFLICT,
        ..domain()
    };
    let non_file_root = ObjectId::for_plaintext(non_file_domain, b"bytes");
    assert_eq!(
        ConflictContent::new(non_file_domain, non_file_root, b"bytes".to_vec(), false),
        Err(ConflictError::InvalidObjectDomain)
    );

    let foreign = content_in(foreign_domain, b"foreign", false);
    assert!(matches!(
        ThreeWayFile::new(
            domain(),
            "file".to_owned(),
            Some(content(b"base", false)),
            Some(foreign.clone()),
            Some(content(b"remote", false)),
        ),
        Err(ConflictError::InvalidObjectDomain)
    ));
    assert_eq!(
        ConflictRecord::new(
            domain(),
            ConflictKind::Text,
            vec!["file".to_owned()],
            Some(content(b"base", false)),
            Some(foreign.clone()),
            Some(content(b"remote", false)),
        ),
        Err(ConflictError::InvalidObjectDomain)
    );

    let foreign_conflict = conflict(
        merge_file(
            ThreeWayFile::new(
                foreign_domain,
                "foreign".to_owned(),
                Some(content_in(foreign_domain, b"base", false)),
                Some(content_in(foreign_domain, b"local", false)),
                Some(content_in(foreign_domain, b"remote", false)),
            )
            .unwrap(),
        )
        .unwrap(),
    );
    let mut set = ConflictSet::new(domain()).unwrap();
    assert_eq!(
        set.insert(foreign_conflict),
        Err(ConflictError::InvalidObjectDomain)
    );

    let record = conflict(
        merge_file(file(
            "local",
            Some(content(b"base", false)),
            Some(content(b"local", false)),
            Some(content(b"remote", false)),
        ))
        .unwrap(),
    );
    let expected = set.insert(record).unwrap();
    let revision = set.revision();
    assert_eq!(
        set.resolve(expected, ConflictResolution::Content(foreign)),
        Err(ConflictError::InvalidObjectDomain)
    );
    assert_eq!(set.revision(), revision);
    assert_eq!(set.len(), 1);
}
