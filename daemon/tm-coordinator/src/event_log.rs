use crate::model::IntentEvent;
use anyhow::{bail, Context, Result};
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub trait EventLog: Send + Sync {
    fn append(&self, event: &IntentEvent) -> Result<()>;
    fn read_all(&self) -> Result<Vec<IntentEvent>>;
    fn health(&self) -> serde_json::Value;

    /// Whether this log can append and read at all. A backend that fails
    /// every call is not a degraded log, it is an absent one, and a client
    /// has to be able to say so out loud: every mutation the coordinator
    /// accepts is written here first, so an unavailable log means nothing
    /// can be recorded. `health()` carries the same fact, but only as prose
    /// a client would have to pattern-match on — this is the machine answer.
    fn is_available(&self) -> bool;
}

pub struct MemMeshUnavailableEventLog;

impl EventLog for MemMeshUnavailableEventLog {
    fn append(&self, _event: &IntentEvent) -> Result<()> {
        bail!("mem_mesh_unavailable: no verified ordered append/read event-log contract")
    }

    fn read_all(&self) -> Result<Vec<IntentEvent>> {
        bail!("mem_mesh_unavailable: no verified ordered append/read event-log contract")
    }

    fn health(&self) -> serde_json::Value {
        serde_json::json!({
            "status": "mem_mesh_unavailable",
            "reason": "verified MCP/config exposes memory search/add tools, not canonical ordered append/read event log"
        })
    }

    fn is_available(&self) -> bool {
        false
    }
}

pub struct LocalJournalEventLog {
    path: PathBuf,
    lock: Mutex<()>,
}

impl LocalJournalEventLog {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            lock: Mutex::new(()),
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl EventLog for LocalJournalEventLog {
    fn append(&self, event: &IntentEvent) -> Result<()> {
        let _guard = self.lock.lock().expect("local journal mutex poisoned");
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("create journal dir {}", parent.display()))?;
        }
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
            .with_context(|| format!("open journal {}", self.path.display()))?;
        serde_json::to_writer(&mut file, event)?;
        file.write_all(b"\n")?;
        file.sync_data()?;
        Ok(())
    }

    fn read_all(&self) -> Result<Vec<IntentEvent>> {
        let _guard = self.lock.lock().expect("local journal mutex poisoned");
        if !self.path.exists() {
            return Ok(Vec::new());
        }
        let file = File::open(&self.path)?;
        let reader = BufReader::new(file);
        let mut events = Vec::new();
        for line in reader.lines() {
            let line = line?;
            if line.trim().is_empty() {
                continue;
            }
            events.push(serde_json::from_str(&line)?);
        }
        Ok(events)
    }

    fn health(&self) -> serde_json::Value {
        serde_json::json!({
            "status": "local_journal_dev_only",
            "canonical": false,
            "path": self.path
        })
    }

    /// Available but not canonical: a single machine's file cannot be the
    /// shared ordering several machines agree on. Availability answers "can
    /// the coordinator record anything at all", which this backend can —
    /// `health().canonical` is where the weaker guarantee is stated.
    fn is_available(&self) -> bool {
        true
    }
}
