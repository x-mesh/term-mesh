use std::collections::HashSet;
use std::fmt;
use std::sync::Arc;

use super::oplog::{OplogError, OplogStore};
use super::{ObjectId, ProjectId};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DeviceStatus {
    pub device_id: [u8; 32],
    pub revoked: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GcSnapshot {
    pub devices: Vec<DeviceStatus>,
    pub roots: Vec<ObjectId>,
}

pub trait GcSnapshotLease: Send {
    /// Re-reads roster and roots while this guard excludes new device
    /// approvals and root activation. The exclusion lasts until drop.
    fn snapshot(&self) -> Result<GcSnapshot, GcError>;
}

pub trait GcCoordinator: Send + Sync {
    /// Best-effort snapshot used only to plan candidates. Every delete is
    /// protected by `acquire_snapshot_lease` and rechecked under that guard.
    fn snapshot(&self, project_id: ProjectId) -> Result<GcSnapshot, GcError>;

    /// Atomically excludes root activation and approved-device roster changes.
    /// `None` means the exclusion is unavailable and deletion must skip.
    fn acquire_snapshot_lease(
        &self,
        project_id: ProjectId,
        object_id: ObjectId,
    ) -> Result<Option<Box<dyn GcSnapshotLease>>, GcError>;
}

pub trait CasGc: Send + Sync {
    fn list_live(&self) -> Result<Vec<ObjectId>, GcError>;

    /// Must be idempotent and return only after unlink + live-directory fsync.
    fn delete_durable(&self, object_id: ObjectId) -> Result<(), GcError>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct GcReport {
    pub deleted: u64,
    pub skipped: u64,
}

pub struct GcEngine {
    oplog: Arc<OplogStore>,
    coordinator: Arc<dyn GcCoordinator>,
    cas: Arc<dyn CasGc>,
}

impl GcEngine {
    pub fn new(
        oplog: Arc<OplogStore>,
        coordinator: Arc<dyn GcCoordinator>,
        cas: Arc<dyn CasGc>,
    ) -> Self {
        Self {
            oplog,
            coordinator,
            cas,
        }
    }

    pub fn run(&self, now_ms: i64) -> Result<GcReport, GcError> {
        if self.oplog.running_gc_run()?.is_some() {
            return self.recover(now_ms);
        }
        let snapshot = self.coordinator.snapshot(self.oplog.project_id())?;
        let protected = self.protected_roots(now_ms, snapshot)?;
        let candidates = self
            .cas
            .list_live()?
            .into_iter()
            .filter(|object_id| !protected.contains(object_id))
            .collect::<Vec<_>>();
        let mut run_id = [0; 16];
        getrandom::getrandom(&mut run_id).map_err(GcError::Random)?;
        self.oplog.begin_gc_run(run_id, &candidates, now_ms)?;
        self.process_run(run_id, now_ms)
    }

    pub fn recover(&self, now_ms: i64) -> Result<GcReport, GcError> {
        let Some(run_id) = self.oplog.running_gc_run()? else {
            return Ok(GcReport {
                deleted: 0,
                skipped: 0,
            });
        };
        self.process_run(run_id, now_ms)
    }

    fn process_run(&self, run_id: [u8; 16], now_ms: i64) -> Result<GcReport, GcError> {
        let mut report = GcReport {
            deleted: 0,
            skipped: 0,
        };
        for candidate in self.oplog.pending_gc_candidates(run_id)? {
            let Some(lease) = self
                .coordinator
                .acquire_snapshot_lease(self.oplog.project_id(), candidate)?
            else {
                self.oplog.mark_gc_candidate(run_id, candidate, "skipped")?;
                report.skipped += 1;
                continue;
            };
            // Recheck roster and roots under the same exclusion guard, then
            // hold it through durable unlink + directory fsync.
            if self
                .protected_roots(now_ms, lease.snapshot()?)?
                .contains(&candidate)
            {
                self.oplog.mark_gc_candidate(run_id, candidate, "skipped")?;
                report.skipped += 1;
                continue;
            }
            self.cas.delete_durable(candidate)?;
            self.oplog.mark_gc_candidate(run_id, candidate, "deleted")?;
            report.deleted += 1;
        }
        self.oplog.complete_gc_run(run_id)?;
        Ok(report)
    }

    fn protected_roots(
        &self,
        now_ms: i64,
        snapshot: GcSnapshot,
    ) -> Result<HashSet<ObjectId>, GcError> {
        let active = snapshot
            .devices
            .into_iter()
            .filter(|device| !device.revoked)
            .map(|device| device.device_id)
            .collect::<Vec<_>>();
        if active.is_empty() {
            return Err(GcError::NoApprovedDevices);
        }
        let mut protected = snapshot.roots.into_iter().collect::<HashSet<_>>();
        protected.extend(self.oplog.protected_tombstone_roots(now_ms, &active)?);
        Ok(protected)
    }
}

#[derive(Debug)]
pub enum GcError {
    Oplog(OplogError),
    Random(getrandom::Error),
    NoApprovedDevices,
    Provider(String),
    Cas(String),
}

impl fmt::Display for GcError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{self:?}")
    }
}

impl std::error::Error for GcError {}

impl From<OplogError> for GcError {
    fn from(error: OplogError) -> Self {
        Self::Oplog(error)
    }
}
