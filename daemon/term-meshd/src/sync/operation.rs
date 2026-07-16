use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use tokio::sync::Semaphore;

use super::secure_sqlite::{SecureSqlite, SecureSqliteError};
use super::{
    HeldProjectRoot, ManifestScanner, ProjectId, ProjectRegistry, ScanError, ScanLimits, ScanReason,
};

pub const MAX_OPERATION_ENVELOPE_BYTES: usize = 64 * 1024;
const MAX_PROJECT_ID_BYTES: usize = 64;
const DEFAULT_MAX_WORKERS: usize = 2;
const DEFAULT_MAX_QUEUED: usize = 64;
const OPERATION_APPLICATION_ID: i64 = 0x544d_4f50;
const OPERATION_SCHEMA_VERSION: i64 = 1;
const OPERATION_SCHEMA: &str = "CREATE TABLE sync_operations(
 operation_id TEXT PRIMARY KEY NOT NULL CHECK(length(operation_id)=32),
 request_id TEXT NOT NULL UNIQUE CHECK(length(request_id)=32),
 project_id TEXT NOT NULL CHECK(length(project_id)=64),
 kind TEXT NOT NULL CHECK(kind IN ('manifest_scan')),
 root TEXT NOT NULL CHECK(length(root)>0 AND length(root)<=4096),
 state TEXT NOT NULL CHECK(state IN ('pending','running','cancel_requested','succeeded','failed','cancelled','interrupted')),
 result_root TEXT CHECK(result_root IS NULL OR length(result_root)=64),
 result_entries INTEGER CHECK(result_entries IS NULL OR result_entries>=0),
 error_code TEXT CHECK(error_code IS NULL OR length(error_code)<=64),
 created_at_ms INTEGER NOT NULL CHECK(created_at_ms>=0),
 updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms>=created_at_ms)
) STRICT;";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OperationKind {
    ManifestScan,
}

impl OperationKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::ManifestScan => "manifest_scan",
        }
    }

    fn parse(value: &str) -> Result<Self, OperationError> {
        match value {
            "manifest_scan" => Ok(Self::ManifestScan),
            _ => Err(OperationError::CorruptState),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OperationState {
    Pending,
    Running,
    CancelRequested,
    Succeeded,
    Failed,
    Cancelled,
    Interrupted,
}

impl OperationState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Running => "running",
            Self::CancelRequested => "cancel_requested",
            Self::Succeeded => "succeeded",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
            Self::Interrupted => "interrupted",
        }
    }

    fn parse(value: &str) -> Result<Self, OperationError> {
        match value {
            "pending" => Ok(Self::Pending),
            "running" => Ok(Self::Running),
            "cancel_requested" => Ok(Self::CancelRequested),
            "succeeded" => Ok(Self::Succeeded),
            "failed" => Ok(Self::Failed),
            "cancelled" => Ok(Self::Cancelled),
            "interrupted" => Ok(Self::Interrupted),
            _ => Err(OperationError::CorruptState),
        }
    }

    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            Self::Succeeded | Self::Failed | Self::Cancelled | Self::Interrupted
        )
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OperationStartParams {
    pub request_id: String,
    pub project_id: String,
    pub kind: OperationKind,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OperationIdParams {
    pub operation_id: String,
    pub project_id: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OperationRetryParams {
    pub operation_id: String,
    pub request_id: String,
    pub project_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct OperationRecord {
    pub operation_id: String,
    pub request_id: String,
    pub project_id: String,
    pub kind: OperationKind,
    pub root: String,
    pub state: OperationState,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<OperationResult>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
    pub created_at_ms: u64,
    pub updated_at_ms: u64,
    pub focus_events_emitted: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct OperationResult {
    pub manifest_root: String,
    pub entries: u64,
}

#[derive(Debug, Clone)]
pub struct OperationSpec {
    pub project_id: String,
    pub kind: OperationKind,
    pub root: PathBuf,
    pub held_root: HeldProjectRoot,
}

pub trait OperationRunner: Send + Sync + 'static {
    fn run(
        &self,
        spec: &OperationSpec,
        cancelled: Arc<AtomicBool>,
    ) -> Result<OperationResult, String>;
}

struct ManifestScanRunner;

impl OperationRunner for ManifestScanRunner {
    fn run(
        &self,
        spec: &OperationSpec,
        cancelled: Arc<AtomicBool>,
    ) -> Result<OperationResult, String> {
        if cancelled.load(Ordering::Acquire) {
            return Err("cancelled".to_string());
        }
        match spec.kind {
            OperationKind::ManifestScan => {
                spec.held_root
                    .revalidate()
                    .map_err(|_| "root_identity_changed".to_string())?;
                let scanner =
                    ManifestScanner::with_cancellation(ScanLimits::default(), cancelled.clone())
                        .map_err(|_| "scan_initialization_failed".to_string())?;
                let (manifest, _) = scanner
                    .scan_descriptor(spec.held_root.descriptor(), ScanReason::Initial)
                    .map_err(|error| match error {
                        ScanError::Cancelled => "cancelled".to_string(),
                        _ => "manifest_scan_failed".to_string(),
                    })?;
                if cancelled.load(Ordering::Acquire) {
                    return Err("cancelled".to_string());
                }
                spec.held_root
                    .revalidate()
                    .map_err(|_| "root_identity_changed".to_string())?;
                Ok(OperationResult {
                    manifest_root: hex::encode(manifest.root.0),
                    entries: manifest.entry_count,
                })
            }
        }
    }
}

struct Inner {
    database: Mutex<SecureSqlite>,
    registry: Arc<ProjectRegistry>,
    runner: Arc<dyn OperationRunner>,
    workers: Arc<Semaphore>,
    queued: AtomicUsize,
    max_queued: usize,
    cancellations: Mutex<HashMap<String, Arc<AtomicBool>>>,
    unhealthy: AtomicBool,
    #[cfg(test)]
    transition_barriers: Mutex<Option<(Arc<std::sync::Barrier>, Arc<std::sync::Barrier>)>>,
}

#[derive(Clone)]
pub struct OperationManager {
    inner: Arc<Inner>,
}

struct Admission {
    inner: Arc<Inner>,
}

impl Drop for Admission {
    fn drop(&mut self) {
        self.inner.queued.fetch_sub(1, Ordering::AcqRel);
    }
}

struct CancellationRegistration {
    inner: Arc<Inner>,
    operation_id: String,
}

impl Drop for CancellationRegistration {
    fn drop(&mut self) {
        self.inner
            .cancellations
            .lock()
            .unwrap()
            .remove(&self.operation_id);
    }
}

impl OperationManager {
    pub fn open(
        path: impl AsRef<Path>,
        registry: Arc<ProjectRegistry>,
    ) -> Result<Self, OperationError> {
        Self::open_with_runner_and_limits(
            path,
            registry,
            Arc::new(ManifestScanRunner),
            DEFAULT_MAX_WORKERS,
            DEFAULT_MAX_QUEUED,
        )
    }

    pub fn open_with_runner_and_limits(
        path: impl AsRef<Path>,
        registry: Arc<ProjectRegistry>,
        runner: Arc<dyn OperationRunner>,
        max_workers: usize,
        max_queued: usize,
    ) -> Result<Self, OperationError> {
        if max_workers == 0 || max_queued == 0 {
            return Err(OperationError::ResourceExhausted);
        }
        let database = SecureSqlite::open(path.as_ref()).map_err(map_secure_error)?;
        let initialization = (|| {
            database
                .execute_batch(
                    "PRAGMA journal_mode=WAL;
                 PRAGMA synchronous=FULL;
                 PRAGMA foreign_keys=ON;",
                )
                .map_err(|_| OperationError::Storage)?;
            initialize_or_validate_schema(&database)?;
            database.validate_files().map_err(map_secure_error)?;
            let now = now_ms();
            let changed = database.execute(
                "UPDATE sync_operations SET state='interrupted', error_code='daemon_restarted', updated_at_ms=?1
                 WHERE state IN ('pending','running','cancel_requested')",
                params![now],
            )
            .map_err(|_| OperationError::Storage)?;
            let _ = changed;
            Ok::<(), OperationError>(())
        })();
        if let Err(error) = initialization {
            drop(database);
            return Err(error);
        }
        Ok(Self {
            inner: Arc::new(Inner {
                database: Mutex::new(database),
                registry,
                runner,
                workers: Arc::new(Semaphore::new(max_workers)),
                queued: AtomicUsize::new(0),
                max_queued,
                cancellations: Mutex::new(HashMap::new()),
                unhealthy: AtomicBool::new(false),
                #[cfg(test)]
                transition_barriers: Mutex::new(None),
            }),
        })
    }

    pub async fn start(
        &self,
        params: OperationStartParams,
    ) -> Result<OperationRecord, OperationError> {
        validate_hex_id(&params.request_id, 16)?;
        let project_id = parse_project_id(&params.project_id)?;
        if params.project_id.len() > MAX_PROJECT_ID_BYTES {
            return Err(OperationError::InvalidParams);
        }
        if let Some(existing) = self.by_request_id(&params.request_id)? {
            if existing.project_id != params.project_id || existing.kind != params.kind {
                return Err(OperationError::IdempotencyMismatch);
            }
            let registered_root = self
                .inner
                .registry
                .get(project_id)
                .map_err(|_| OperationError::ProjectNotFound)?
                .ok_or(OperationError::ProjectNotFound)?
                .root_path
                .to_string_lossy()
                .into_owned();
            if existing.root == registered_root {
                return Ok(existing);
            }
            return Err(OperationError::IdempotencyMismatch);
        }
        if self.inner.unhealthy.load(Ordering::Acquire) {
            return Err(OperationError::Storage);
        }
        let admission = self.admit()?;
        let registry = self.inner.registry.clone();
        let held_root = tokio::task::spawn_blocking(move || registry.resolve_root(project_id))
            .await
            .map_err(|_| OperationError::WorkerFailed)?
            .map_err(|_| OperationError::ProjectNotFound)?;
        let root_string = held_root.canonical_path().to_string_lossy().into_owned();
        let spec = OperationSpec {
            project_id: params.project_id.clone(),
            kind: params.kind,
            root: held_root.canonical_path().to_path_buf(),
            held_root,
        };

        let operation_id = random_id()?;
        let created = now_ms();
        let insert = self.inner.database.lock().unwrap().execute(
            "INSERT INTO sync_operations(operation_id,request_id,project_id,kind,root,state,created_at_ms,updated_at_ms)
             VALUES(?1,?2,?3,?4,?5,'pending',?6,?6)",
            params![
                operation_id,
                params.request_id,
                params.project_id,
                params.kind.as_str(),
                root_string,
                created
            ],
        );
        if insert != Ok(1) {
            if let Some(existing) = self.by_request_id(&params.request_id)? {
                if existing.project_id == params.project_id
                    && existing.kind == params.kind
                    && existing.root == root_string
                {
                    return Ok(existing);
                }
                return Err(OperationError::IdempotencyMismatch);
            }
            return Err(OperationError::Storage);
        }
        let cancelled = Arc::new(AtomicBool::new(false));
        self.inner
            .cancellations
            .lock()
            .unwrap()
            .insert(operation_id.clone(), cancelled.clone());
        self.spawn_operation(operation_id.clone(), spec, cancelled, admission);
        self.status(&operation_id, &params.project_id)
    }

    fn admit(&self) -> Result<Admission, OperationError> {
        let queued = self.inner.queued.fetch_add(1, Ordering::AcqRel);
        if queued >= self.inner.max_queued {
            self.inner.queued.fetch_sub(1, Ordering::AcqRel);
            return Err(OperationError::ResourceExhausted);
        }
        Ok(Admission {
            inner: self.inner.clone(),
        })
    }

    fn spawn_operation(
        &self,
        operation_id: String,
        spec: OperationSpec,
        cancelled: Arc<AtomicBool>,
        admission: Admission,
    ) {
        let manager = self.clone();
        tokio::spawn(async move {
            let _cancellation_registration = CancellationRegistration {
                inner: manager.inner.clone(),
                operation_id: operation_id.clone(),
            };
            let permit = manager.inner.workers.clone().acquire_owned().await;
            drop(admission);
            let Ok(_permit) = permit else {
                manager.persist_finish(
                    &operation_id,
                    OperationState::Interrupted,
                    None,
                    Some("worker_closed"),
                );
                return;
            };
            if cancelled.load(Ordering::Acquire) {
                manager.persist_finish(
                    &operation_id,
                    OperationState::Cancelled,
                    None,
                    Some("cancelled"),
                );
                return;
            }
            #[cfg(test)]
            if let Some((reached, release)) =
                manager.inner.transition_barriers.lock().unwrap().clone()
            {
                reached.wait();
                release.wait();
            }
            match manager.transition_running(&operation_id) {
                Ok(TransitionRunning::Running) => {}
                Ok(TransitionRunning::Cancelled) => return,
                Err(error) => {
                    manager.persist_finish(
                        &operation_id,
                        OperationState::Failed,
                        None,
                        Some("transition_failed"),
                    );
                    if error == OperationError::Storage {
                        manager.mark_unhealthy("transition_running");
                    }
                    return;
                }
            }
            let runner = manager.inner.runner.clone();
            let cancel_for_worker = cancelled.clone();
            let result =
                tokio::task::spawn_blocking(move || runner.run(&spec, cancel_for_worker)).await;
            match result {
                Ok(Ok(output)) => {
                    if cancelled.load(Ordering::Acquire) {
                        manager.persist_finish(
                            &operation_id,
                            OperationState::Cancelled,
                            None,
                            Some("cancelled"),
                        );
                    } else {
                        manager.persist_finish(
                            &operation_id,
                            OperationState::Succeeded,
                            Some(output),
                            None,
                        );
                    }
                }
                Ok(Err(code)) => {
                    if cancelled.load(Ordering::Acquire) || code == "cancelled" {
                        manager.persist_finish(
                            &operation_id,
                            OperationState::Cancelled,
                            None,
                            Some("cancelled"),
                        );
                    } else {
                        let error_code = normalize_runner_error(&code);
                        manager.persist_finish(
                            &operation_id,
                            OperationState::Failed,
                            None,
                            Some(error_code),
                        );
                    }
                }
                Err(_) => {
                    manager.persist_finish(
                        &operation_id,
                        OperationState::Failed,
                        None,
                        Some("worker_failed"),
                    );
                }
            }
        });
    }

    fn transition_running(&self, operation_id: &str) -> Result<TransitionRunning, OperationError> {
        let changed = self.inner
            .database
            .lock()
            .unwrap()
            .execute(
                "UPDATE sync_operations SET state='running',updated_at_ms=?2 WHERE operation_id=?1 AND state='pending'",
                params![operation_id, now_ms()],
            )
            .map_err(|_| OperationError::Storage)?;
        if changed == 1 {
            return Ok(TransitionRunning::Running);
        }
        let state = self
            .query_one("operation_id", operation_id)?
            .ok_or(OperationError::NotFound)?
            .state;
        if state == OperationState::CancelRequested {
            let changed = self.inner.database.lock().unwrap().execute(
                "UPDATE sync_operations SET state='cancelled',error_code='cancelled',updated_at_ms=?2
                 WHERE operation_id=?1 AND state='cancel_requested'",
                params![operation_id, now_ms()],
            ).map_err(|_| OperationError::Storage)?;
            if changed == 1
                || self
                    .query_one("operation_id", operation_id)?
                    .is_some_and(|record| record.state.is_terminal())
            {
                return Ok(TransitionRunning::Cancelled);
            }
        } else if state.is_terminal() {
            return Ok(TransitionRunning::Cancelled);
        }
        Err(OperationError::InvalidTransition)
    }

    fn persist_finish(
        &self,
        operation_id: &str,
        state: OperationState,
        result: Option<OperationResult>,
        error_code: Option<&str>,
    ) {
        if let Err(error) = self.finish(operation_id, state, result, error_code) {
            if error == OperationError::Storage {
                self.mark_unhealthy("finish");
            }
            tracing::error!(
                operation_id,
                ?state,
                ?error,
                "operation terminal persistence failed"
            );
        }
    }

    fn mark_unhealthy(&self, stage: &'static str) {
        self.inner.unhealthy.store(true, Ordering::Release);
        tracing::error!(stage, "operation manager marked unhealthy");
    }

    fn finish(
        &self,
        operation_id: &str,
        state: OperationState,
        result: Option<OperationResult>,
        error_code: Option<&str>,
    ) -> Result<(), OperationError> {
        let (root, entries) = result
            .map(|result| (Some(result.manifest_root), Some(result.entries)))
            .unwrap_or((None, None));
        let changed = self.inner.database.lock().unwrap().execute(
            "UPDATE sync_operations SET state=?2,result_root=?3,result_entries=?4,error_code=?5,updated_at_ms=?6
             WHERE operation_id=?1 AND state IN ('pending','running','cancel_requested')",
            params![operation_id, state.as_str(), root, entries, error_code, now_ms()],
        ).map_err(|_| OperationError::Storage)?;
        if changed != 1 {
            return Err(OperationError::InvalidTransition);
        }
        Ok(())
    }

    pub fn status(
        &self,
        operation_id: &str,
        project_id: &str,
    ) -> Result<OperationRecord, OperationError> {
        validate_hex_id(operation_id, 16)?;
        parse_project_id(project_id)?;
        let record = self
            .query_one("operation_id", operation_id)?
            .ok_or(OperationError::NotFound)?;
        if record.project_id != project_id {
            return Err(OperationError::ProjectMismatch);
        }
        Ok(record)
    }

    pub fn cancel(
        &self,
        operation_id: &str,
        project_id: &str,
    ) -> Result<OperationRecord, OperationError> {
        validate_hex_id(operation_id, 16)?;
        let before = self.status(operation_id, project_id)?;
        if let Some(flag) = self
            .inner
            .cancellations
            .lock()
            .unwrap()
            .get(operation_id)
            .cloned()
        {
            flag.store(true, Ordering::Release);
        }
        let changed = self
            .inner
            .database
            .lock()
            .unwrap()
            .execute(
                "UPDATE sync_operations SET state='cancel_requested',updated_at_ms=?2
             WHERE operation_id=?1 AND state IN ('pending','running')",
                params![operation_id, now_ms()],
            )
            .map_err(|_| OperationError::Storage)?;
        if changed == 0 {
            let after = self.status(operation_id, project_id)?;
            if after.state.is_terminal() || after.state == OperationState::CancelRequested {
                return Ok(after);
            }
            if !before.state.is_terminal() {
                return Err(OperationError::InvalidTransition);
            }
        }
        self.status(operation_id, project_id)
    }

    pub async fn retry(
        &self,
        params: OperationRetryParams,
    ) -> Result<OperationRecord, OperationError> {
        validate_hex_id(&params.request_id, 16)?;
        let source = self.status(&params.operation_id, &params.project_id)?;
        if !source.state.is_terminal() || source.state == OperationState::Succeeded {
            return Err(OperationError::InvalidTransition);
        }
        if params.request_id == source.request_id {
            return Err(OperationError::IdempotencyMismatch);
        }
        self.start(OperationStartParams {
            request_id: params.request_id,
            project_id: source.project_id,
            kind: source.kind,
        })
        .await
    }

    pub fn focus_events_emitted(&self) -> u64 {
        0
    }

    #[cfg(test)]
    pub fn set_transition_barriers(
        &self,
        reached: Arc<std::sync::Barrier>,
        release: Arc<std::sync::Barrier>,
    ) {
        *self.inner.transition_barriers.lock().unwrap() = Some((reached, release));
    }

    #[cfg(test)]
    pub fn cancellation_count(&self) -> usize {
        self.inner.cancellations.lock().unwrap().len()
    }

    #[cfg(test)]
    pub fn set_storage_query_only(&self) {
        self.inner
            .database
            .lock()
            .unwrap()
            .execute_batch("PRAGMA query_only=ON")
            .unwrap();
    }

    fn by_request_id(&self, request_id: &str) -> Result<Option<OperationRecord>, OperationError> {
        self.query_one("request_id", request_id)
    }

    fn query_one(
        &self,
        column: &str,
        value: &str,
    ) -> Result<Option<OperationRecord>, OperationError> {
        let sql = format!(
            "SELECT operation_id,request_id,project_id,kind,root,state,result_root,result_entries,error_code,created_at_ms,updated_at_ms
             FROM sync_operations WHERE {column}=?1"
        );
        self.inner
            .database
            .lock()
            .unwrap()
            .query_row(&sql, params![value], row_to_record)
            .optional()
            .map_err(|_| OperationError::Storage)
    }
}

enum TransitionRunning {
    Running,
    Cancelled,
}

fn normalize_runner_error(code: &str) -> &'static str {
    match code {
        "root_identity_changed" => "root_identity_changed",
        "manifest_scan_failed" => "manifest_scan_failed",
        "scan_initialization_failed" => "scan_initialization_failed",
        _ => "operation_failed",
    }
}

fn row_to_record(row: &rusqlite::Row<'_>) -> rusqlite::Result<OperationRecord> {
    let kind: String = row.get(3)?;
    let state: String = row.get(5)?;
    let result_root: Option<String> = row.get(6)?;
    let result_entries: Option<u64> = row.get(7)?;
    Ok(OperationRecord {
        operation_id: row.get(0)?,
        request_id: row.get(1)?,
        project_id: row.get(2)?,
        kind: OperationKind::parse(&kind).map_err(|_| rusqlite::Error::InvalidQuery)?,
        root: row.get(4)?,
        state: OperationState::parse(&state).map_err(|_| rusqlite::Error::InvalidQuery)?,
        result: result_root.map(|manifest_root| OperationResult {
            manifest_root,
            entries: result_entries.unwrap_or(0),
        }),
        error_code: row.get(8)?,
        created_at_ms: row.get(9)?,
        updated_at_ms: row.get(10)?,
        focus_events_emitted: 0,
    })
}

fn validate_hex_id(value: &str, bytes: usize) -> Result<(), OperationError> {
    if value.len() != bytes * 2 || hex::decode(value).map_or(true, |decoded| decoded.len() != bytes)
    {
        return Err(OperationError::InvalidParams);
    }
    Ok(())
}

fn parse_project_id(value: &str) -> Result<ProjectId, OperationError> {
    validate_hex_id(value, 32)?;
    let bytes = hex::decode(value).map_err(|_| OperationError::InvalidParams)?;
    Ok(ProjectId::from_bytes(
        bytes
            .try_into()
            .map_err(|_| OperationError::InvalidParams)?,
    ))
}

fn map_secure_error(error: SecureSqliteError) -> OperationError {
    match error {
        SecureSqliteError::Security => OperationError::Security,
        SecureSqliteError::Io(_) | SecureSqliteError::Sql(_) => OperationError::Storage,
    }
}

fn initialize_or_validate_schema(connection: &Connection) -> Result<(), OperationError> {
    let actual: Option<String> = connection
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='sync_operations'",
            [],
            |row| row.get(0),
        )
        .optional()
        .map_err(|_| OperationError::Storage)?;
    match actual {
        None => connection
            .execute_batch(&format!(
                "{OPERATION_SCHEMA} PRAGMA application_id={OPERATION_APPLICATION_ID}; PRAGMA user_version={OPERATION_SCHEMA_VERSION};"
            ))
            .map_err(|_| OperationError::Schema)?,
        Some(actual) => {
            let normalize = |sql: &str| {
                sql.trim_end_matches(';')
                    .split_whitespace()
                    .collect::<String>()
            };
            if normalize(&actual) != normalize(OPERATION_SCHEMA) {
                return Err(OperationError::Schema);
            }
        }
    }
    let strict: i64 = connection
        .query_row(
            "SELECT strict FROM pragma_table_list('sync_operations') WHERE schema='main'",
            [],
            |row| row.get(0),
        )
        .map_err(|_| OperationError::Schema)?;
    if strict != 1 {
        return Err(OperationError::Schema);
    }
    let application_id: i64 = connection
        .query_row("PRAGMA application_id", [], |row| row.get(0))
        .map_err(|_| OperationError::Schema)?;
    let user_version: i64 = connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .map_err(|_| OperationError::Schema)?;
    let quick_check: String = connection
        .query_row("PRAGMA quick_check(1)", [], |row| row.get(0))
        .map_err(|_| OperationError::Schema)?;
    if application_id != OPERATION_APPLICATION_ID
        || user_version != OPERATION_SCHEMA_VERSION
        || quick_check != "ok"
    {
        return Err(OperationError::Schema);
    }
    let mut statement = connection
        .prepare("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY name")
        .map_err(|_| OperationError::Schema)?;
    let entries = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, Option<String>>(3)?,
            ))
        })
        .map_err(|_| OperationError::Schema)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| OperationError::Schema)?;
    let table_ok = entries.iter().any(|entry| {
        entry.0 == "table"
            && entry.1 == "sync_operations"
            && entry.2 == "sync_operations"
            && entry.3.as_deref().is_some_and(|sql| {
                sql.trim_end_matches(';')
                    .split_whitespace()
                    .collect::<String>()
                    == OPERATION_SCHEMA
                        .trim_end_matches(';')
                        .split_whitespace()
                        .collect::<String>()
            })
    });
    let indexes = entries
        .iter()
        .filter(|entry| entry.0 == "index" && entry.2 == "sync_operations" && entry.3.is_none())
        .count();
    if !table_ok || indexes != 2 || entries.len() != 3 {
        return Err(OperationError::Schema);
    }
    Ok(())
}

fn random_id() -> Result<String, OperationError> {
    let mut bytes = [0u8; 16];
    getrandom::getrandom(&mut bytes).map_err(|_| OperationError::Entropy)?;
    Ok(hex::encode(bytes))
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OperationError {
    InvalidParams,
    IdempotencyMismatch,
    NotFound,
    InvalidTransition,
    ResourceExhausted,
    Storage,
    WorkerFailed,
    Entropy,
    CorruptState,
    ProjectNotFound,
    ProjectMismatch,
    Security,
    Schema,
}

impl std::fmt::Display for OperationError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{self:?}")
    }
}

impl std::error::Error for OperationError {}

pub fn default_operation_db_path() -> PathBuf {
    if let Some(path) = std::env::var_os("TERMMESH_SYNC_OPERATION_DB") {
        if !path.is_empty() {
            return PathBuf::from(path);
        }
    }
    dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("term-mesh")
        .join("sync")
        .join("sync_operations.db")
}
