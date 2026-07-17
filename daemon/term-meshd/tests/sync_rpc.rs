#[path = "../src/sync/mod.rs"]
mod sync;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use sync::{
    OperationError, OperationKind, OperationManager, OperationResult, OperationRetryParams,
    OperationRunner, OperationSpec, OperationStartParams, OperationState, ProjectRegistry,
    MAX_OPERATION_ENVELOPE_BYTES,
};

struct ImmediateRunner;

impl OperationRunner for ImmediateRunner {
    fn run(
        &self,
        _spec: &OperationSpec,
        cancelled: Arc<AtomicBool>,
    ) -> Result<OperationResult, String> {
        if cancelled.load(Ordering::Acquire) {
            return Err("cancelled".to_string());
        }
        Ok(OperationResult {
            manifest_root: "00".repeat(32),
            entries: 1,
        })
    }
}

struct BlockingRunner {
    release: Arc<AtomicBool>,
}

struct NeverRunner;

struct FailingRunner {
    code: String,
}

impl OperationRunner for FailingRunner {
    fn run(
        &self,
        _spec: &OperationSpec,
        _cancelled: Arc<AtomicBool>,
    ) -> Result<OperationResult, String> {
        Err(self.code.clone())
    }
}

impl OperationRunner for NeverRunner {
    fn run(
        &self,
        _spec: &OperationSpec,
        _cancelled: Arc<AtomicBool>,
    ) -> Result<OperationResult, String> {
        panic!("cancelled pending operation must not reach runner")
    }
}

impl OperationRunner for BlockingRunner {
    fn run(
        &self,
        _spec: &OperationSpec,
        cancelled: Arc<AtomicBool>,
    ) -> Result<OperationResult, String> {
        while !self.release.load(Ordering::Acquire) {
            if cancelled.load(Ordering::Acquire) {
                return Err("cancelled".to_string());
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        Ok(OperationResult {
            manifest_root: "11".repeat(32),
            entries: 2,
        })
    }
}

fn params(request_byte: u8, project_id: &str) -> OperationStartParams {
    OperationStartParams {
        request_id: format!("{request_byte:02x}").repeat(16),
        project_id: project_id.to_string(),
        kind: OperationKind::ManifestScan,
        peer: None,
    }
}

fn registry_with_root(
    temp: &tempfile::TempDir,
    root: &std::path::Path,
) -> (Arc<ProjectRegistry>, String) {
    let state = temp.path().join("registry-state");
    std::fs::create_dir_all(&state).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&state, std::fs::Permissions::from_mode(0o700)).unwrap();
    let registry = Arc::new(ProjectRegistry::open(state.join("registry.db")).unwrap());
    let project = registry.add(root).unwrap();
    (registry, project.project_id.to_string())
}

fn operation_db(temp: &tempfile::TempDir) -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt;

    let state = temp.path().join("sync-state");
    std::fs::create_dir_all(&state).unwrap();
    std::fs::set_permissions(&state, std::fs::Permissions::from_mode(0o700)).unwrap();
    state.join("operations.db")
}

async fn wait_for(
    manager: &OperationManager,
    operation_id: &str,
    project_id: &str,
    predicate: impl Fn(OperationState) -> bool,
) -> sync::OperationRecord {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let record = manager.status(operation_id, project_id).unwrap();
        if predicate(record.state) {
            return record;
        }
        assert!(Instant::now() < deadline, "operation state timeout");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
}

#[tokio::test]
async fn request_id_is_idempotent_and_bound_to_project_kind_and_root() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("root");
    let other = temp.path().join("other");
    let moved = temp.path().join("moved");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(&other).unwrap();
    std::fs::create_dir_all(&moved).unwrap();
    let (registry, project_id) = registry_with_root(&temp, &root);
    let manager = OperationManager::open_with_runner_and_limits(
        operation_db(&temp),
        registry.clone(),
        Arc::new(ImmediateRunner),
        1,
        4,
    )
    .unwrap();
    let request = params(1, &project_id);
    let first = manager.start(request.clone()).await.unwrap();
    let duplicate = manager.start(request.clone()).await.unwrap();
    assert_eq!(first.operation_id, duplicate.operation_id);
    let terminal = wait_for(
        &manager,
        &first.operation_id,
        &project_id,
        OperationState::is_terminal,
    )
    .await;
    assert_eq!(terminal.state, OperationState::Succeeded);
    assert_eq!(
        manager
            .cancel(&first.operation_id, &project_id)
            .unwrap()
            .state,
        OperationState::Succeeded
    );

    let mut mismatched_project = request.clone();
    let second_project = registry.add(&other).unwrap().project_id.to_string();
    mismatched_project.project_id = second_project.clone();
    assert_eq!(
        manager.start(mismatched_project).await,
        Err(OperationError::IdempotencyMismatch)
    );
    assert_eq!(
        manager.status(&first.operation_id, &second_project),
        Err(OperationError::ProjectMismatch)
    );
    assert_eq!(
        manager.cancel(&first.operation_id, &second_project),
        Err(OperationError::ProjectMismatch)
    );
    assert_eq!(
        manager
            .retry(OperationRetryParams {
                operation_id: first.operation_id.clone(),
                request_id: "03".repeat(16),
                project_id: second_project,
            })
            .await,
        Err(OperationError::ProjectMismatch)
    );
    registry
        .relocate(
            sync::ProjectId::from_bytes(hex::decode(&project_id).unwrap().try_into().unwrap()),
            &moved,
        )
        .unwrap();
    let mismatched_root = request;
    assert_eq!(
        manager.start(mismatched_root).await,
        Err(OperationError::IdempotencyMismatch)
    );
}

#[tokio::test]
async fn cancellation_race_is_terminal_and_retry_creates_a_new_operation() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("root");
    std::fs::create_dir_all(&root).unwrap();
    let (registry, project_id) = registry_with_root(&temp, &root);
    let release = Arc::new(AtomicBool::new(false));
    let manager = OperationManager::open_with_runner_and_limits(
        operation_db(&temp),
        registry,
        Arc::new(BlockingRunner {
            release: release.clone(),
        }),
        1,
        4,
    )
    .unwrap();
    let started = manager.start(params(4, &project_id)).await.unwrap();
    wait_for(&manager, &started.operation_id, &project_id, |state| {
        state == OperationState::Running
    })
    .await;
    manager.cancel(&started.operation_id, &project_id).unwrap();
    release.store(true, Ordering::Release);
    let cancelled = wait_for(
        &manager,
        &started.operation_id,
        &project_id,
        OperationState::is_terminal,
    )
    .await;
    assert_eq!(cancelled.state, OperationState::Cancelled);
    assert_eq!(
        manager
            .cancel(&started.operation_id, &project_id)
            .unwrap()
            .state,
        OperationState::Cancelled
    );
    assert_eq!(
        manager
            .retry(OperationRetryParams {
                operation_id: started.operation_id.clone(),
                request_id: started.request_id.clone(),
                project_id: project_id.clone(),
            })
            .await,
        Err(OperationError::IdempotencyMismatch)
    );

    let retried = manager
        .retry(OperationRetryParams {
            operation_id: started.operation_id.clone(),
            request_id: "06".repeat(16),
            project_id: project_id.clone(),
        })
        .await
        .unwrap();
    assert_ne!(retried.operation_id, started.operation_id);
}

#[tokio::test]
async fn reopen_marks_nonterminal_interrupted_and_old_worker_cannot_overwrite_it() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("root");
    let database = operation_db(&temp);
    std::fs::create_dir_all(&root).unwrap();
    let (registry, project_id) = registry_with_root(&temp, &root);
    let release = Arc::new(AtomicBool::new(false));
    let first = OperationManager::open_with_runner_and_limits(
        &database,
        registry.clone(),
        Arc::new(BlockingRunner {
            release: release.clone(),
        }),
        1,
        4,
    )
    .unwrap();
    let started = first.start(params(7, &project_id)).await.unwrap();
    wait_for(&first, &started.operation_id, &project_id, |state| {
        state == OperationState::Running
    })
    .await;

    let reopened = OperationManager::open_with_runner_and_limits(
        &database,
        registry,
        Arc::new(ImmediateRunner),
        1,
        4,
    )
    .unwrap();
    assert_eq!(
        reopened
            .status(&started.operation_id, &project_id)
            .unwrap()
            .state,
        OperationState::Interrupted
    );
    release.store(true, Ordering::Release);
    tokio::time::sleep(Duration::from_millis(30)).await;
    assert_eq!(
        reopened
            .status(&started.operation_id, &project_id)
            .unwrap()
            .state,
        OperationState::Interrupted
    );
}

#[tokio::test]
async fn blocking_work_does_not_stall_status_and_queue_caps_fail_closed() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("root");
    let other = temp.path().join("other");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::create_dir_all(&other).unwrap();
    let (registry, project_id) = registry_with_root(&temp, &root);
    let other_project_id = registry.add(&other).unwrap().project_id.to_string();
    let release = Arc::new(AtomicBool::new(false));
    let manager = OperationManager::open_with_runner_and_limits(
        operation_db(&temp),
        registry,
        Arc::new(BlockingRunner {
            release: release.clone(),
        }),
        1,
        2,
    )
    .unwrap();
    let running = manager.start(params(10, &project_id)).await.unwrap();
    wait_for(&manager, &running.operation_id, &project_id, |state| {
        state == OperationState::Running
    })
    .await;
    let status_started = Instant::now();
    manager.status(&running.operation_id, &project_id).unwrap();
    assert!(status_started.elapsed() < Duration::from_millis(50));

    manager.start(params(11, &project_id)).await.unwrap();
    manager.start(params(12, &project_id)).await.unwrap();
    let duplicate = manager.start(params(10, &project_id)).await.unwrap();
    assert_eq!(duplicate.operation_id, running.operation_id);
    assert_eq!(
        manager.start(params(10, &other_project_id)).await,
        Err(OperationError::IdempotencyMismatch)
    );
    assert_eq!(
        manager.start(params(13, &project_id)).await,
        Err(OperationError::ResourceExhausted)
    );
    release.store(true, Ordering::Release);
}

#[tokio::test]
async fn runner_error_allowlist_survives_retry_and_unknown_messages_are_redacted() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("root");
    std::fs::create_dir(&root).unwrap();
    let (registry, project_id) = registry_with_root(&temp, &root);
    let manager = OperationManager::open_with_runner_and_limits(
        operation_db(&temp),
        registry,
        Arc::new(FailingRunner {
            code: "root_identity_changed".to_string(),
        }),
        1,
        4,
    )
    .unwrap();
    let first = manager.start(params(20, &project_id)).await.unwrap();
    let failed = wait_for(
        &manager,
        &first.operation_id,
        &project_id,
        OperationState::is_terminal,
    )
    .await;
    assert_eq!(failed.state, OperationState::Failed);
    assert_eq!(failed.error_code.as_deref(), Some("root_identity_changed"));
    let retried = manager
        .retry(OperationRetryParams {
            operation_id: first.operation_id,
            request_id: "21".repeat(16),
            project_id: project_id.clone(),
        })
        .await
        .unwrap();
    let retried = wait_for(
        &manager,
        &retried.operation_id,
        &project_id,
        OperationState::is_terminal,
    )
    .await;
    assert_eq!(retried.error_code.as_deref(), Some("root_identity_changed"));

    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("root");
    std::fs::create_dir(&root).unwrap();
    let (registry, project_id) = registry_with_root(&temp, &root);
    let secret = format!("secret:{}", "x".repeat(MAX_OPERATION_ENVELOPE_BYTES));
    let manager = OperationManager::open_with_runner_and_limits(
        operation_db(&temp),
        registry,
        Arc::new(FailingRunner { code: secret }),
        1,
        4,
    )
    .unwrap();
    let started = manager.start(params(22, &project_id)).await.unwrap();
    let failed = wait_for(
        &manager,
        &started.operation_id,
        &project_id,
        OperationState::is_terminal,
    )
    .await;
    assert_eq!(failed.error_code.as_deref(), Some("operation_failed"));
    assert!(serde_json::to_vec(&failed).unwrap().len() < MAX_OPERATION_ENVELOPE_BYTES);
}

#[tokio::test]
async fn typed_params_envelopes_and_focus_observable_are_bounded() {
    let unknown = serde_json::json!({
        "request_id": "01".repeat(16),
        "project_id": "02".repeat(32),
        "kind": "manifest_scan",
        "root": "/tmp",
        "raw_content": "must reject"
    });
    assert!(serde_json::from_value::<OperationStartParams>(unknown).is_err());

    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("root");
    std::fs::create_dir_all(&root).unwrap();
    let (registry, project_id) = registry_with_root(&temp, &root);
    let manager = OperationManager::open_with_runner_and_limits(
        operation_db(&temp),
        registry,
        Arc::new(ImmediateRunner),
        1,
        4,
    )
    .unwrap();
    assert_eq!(manager.focus_events_emitted(), 0);
    let record = manager.start(params(14, &project_id)).await.unwrap();
    assert!(serde_json::to_vec(&record).unwrap().len() < MAX_OPERATION_ENVELOPE_BYTES);

    let mut oversized = params(15, &project_id);
    oversized.project_id = "x".repeat(MAX_OPERATION_ENVELOPE_BYTES);
    assert_eq!(
        manager.start(oversized).await,
        Err(OperationError::InvalidParams)
    );
}

#[tokio::test]
async fn production_manifest_scan_kind_is_read_only_and_returns_a_bounded_digest() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("root");
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("file.txt"), b"read only input").unwrap();
    let (registry, project_id) = registry_with_root(&temp, &root);
    let manager = OperationManager::open(operation_db(&temp), registry).unwrap();
    let started = manager.start(params(16, &project_id)).await.unwrap();
    let completed = wait_for(
        &manager,
        &started.operation_id,
        &project_id,
        OperationState::is_terminal,
    )
    .await;
    assert_eq!(completed.state, OperationState::Succeeded);
    let result = completed.result.unwrap();
    assert_eq!(result.manifest_root.len(), 64);
    assert_eq!(result.entries, 1);
    assert_eq!(
        std::fs::read(root.join("file.txt")).unwrap(),
        b"read only input"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn pending_cancel_wins_exact_transition_barrier_and_is_terminal_immutable() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("root");
    std::fs::create_dir(&root).unwrap();
    let (registry, project_id) = registry_with_root(&temp, &root);
    let manager = OperationManager::open_with_runner_and_limits(
        operation_db(&temp),
        registry,
        Arc::new(NeverRunner),
        1,
        4,
    )
    .unwrap();
    let reached = Arc::new(std::sync::Barrier::new(2));
    let release = Arc::new(std::sync::Barrier::new(2));
    manager.set_transition_barriers(reached.clone(), release.clone());
    let started = manager.start(params(17, &project_id)).await.unwrap();
    tokio::task::spawn_blocking(move || reached.wait())
        .await
        .unwrap();
    assert_eq!(
        manager
            .cancel(&started.operation_id, &project_id)
            .unwrap()
            .state,
        OperationState::CancelRequested
    );
    tokio::task::spawn_blocking(move || release.wait())
        .await
        .unwrap();
    let terminal = wait_for(
        &manager,
        &started.operation_id,
        &project_id,
        OperationState::is_terminal,
    )
    .await;
    assert_eq!(terminal.state, OperationState::Cancelled);
    assert_eq!(
        manager
            .cancel(&started.operation_id, &project_id)
            .unwrap()
            .state,
        OperationState::Cancelled
    );
    let deadline = Instant::now() + Duration::from_secs(1);
    while manager.cancellation_count() != 0 {
        assert!(
            Instant::now() < deadline,
            "cancellation registration leaked"
        );
        tokio::task::yield_now().await;
    }
}

#[tokio::test]
async fn terminal_persistence_failure_marks_manager_unhealthy_and_cleans_cancellation() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("root");
    std::fs::create_dir(&root).unwrap();
    let (registry, project_id) = registry_with_root(&temp, &root);
    let release = Arc::new(AtomicBool::new(false));
    let manager = OperationManager::open_with_runner_and_limits(
        operation_db(&temp),
        registry,
        Arc::new(BlockingRunner {
            release: release.clone(),
        }),
        1,
        4,
    )
    .unwrap();
    let started = manager.start(params(18, &project_id)).await.unwrap();
    wait_for(&manager, &started.operation_id, &project_id, |state| {
        state == OperationState::Running
    })
    .await;
    manager.set_storage_query_only();
    release.store(true, Ordering::Release);
    let deadline = Instant::now() + Duration::from_secs(1);
    while manager.cancellation_count() != 0 {
        assert!(
            Instant::now() < deadline,
            "cancellation registration leaked"
        );
        tokio::task::yield_now().await;
    }
    assert_eq!(
        manager.start(params(19, &project_id)).await,
        Err(OperationError::Storage)
    );
}

#[test]
fn operation_database_requires_private_regular_files_and_strict_schema() {
    use std::os::unix::fs::{symlink, MetadataExt, PermissionsExt};

    let cwd_sidecars = || {
        std::fs::read_dir(".")
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.file_name())
            .filter(|name| name.to_string_lossy().ends_with("-shm"))
            .collect::<std::collections::BTreeSet<_>>()
    };
    let sidecars_before = cwd_sidecars();
    let good = tempfile::tempdir().unwrap();
    let root = good.path().join("root");
    std::fs::create_dir(&root).unwrap();
    let (registry, _) = registry_with_root(&good, &root);
    let database = operation_db(&good);
    let manager = OperationManager::open(&database, registry).unwrap();
    assert_eq!(std::fs::metadata(&database).unwrap().mode() & 0o777, 0o600);
    drop(manager);
    let registry =
        Arc::new(ProjectRegistry::open(good.path().join("registry-state/registry.db")).unwrap());
    for _ in 0..8 {
        drop(OperationManager::open(&database, registry.clone()).unwrap());
    }
    let first = OperationManager::open(&database, registry.clone()).unwrap();
    let second = OperationManager::open(&database, registry).unwrap();
    drop((first, second));

    for suffix in ["", "-wal", "-shm"] {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("root");
        std::fs::create_dir(&root).unwrap();
        let (registry, _) = registry_with_root(&temp, &root);
        let database = operation_db(&temp);
        let target = temp.path().join(format!("target{suffix}"));
        std::fs::write(&target, b"not sqlite").unwrap();
        symlink(&target, format!("{}{suffix}", database.display())).unwrap();
        assert!(matches!(
            OperationManager::open(&database, registry),
            Err(OperationError::Security)
        ));
    }

    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("root");
    std::fs::create_dir(&root).unwrap();
    let (registry, _) = registry_with_root(&temp, &root);
    let database = operation_db(&temp);
    std::fs::write(&database, b"wrong mode").unwrap();
    std::fs::set_permissions(&database, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(matches!(
        OperationManager::open(&database, registry),
        Err(OperationError::Security)
    ));

    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("root");
    std::fs::create_dir(&root).unwrap();
    let (registry, _) = registry_with_root(&temp, &root);
    let database = operation_db(&temp);
    drop(OperationManager::open(&database, registry.clone()).unwrap());
    rusqlite::Connection::open(&database)
        .unwrap()
        .execute_batch("ALTER TABLE sync_operations ADD COLUMN schema_drift TEXT;")
        .unwrap();
    for _ in 0..8 {
        match OperationManager::open(&database, registry.clone()) {
            Err(error) => assert_eq!(error, OperationError::Schema),
            Ok(_) => panic!("schema drift must be rejected"),
        }
    }
    assert_eq!(cwd_sidecars(), sidecars_before);
}
