use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fmt;
use std::str::FromStr;
use uuid::Uuid;

macro_rules! typed_id {
    ($name:ident, $prefix:literal) => {
        #[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
        #[serde(try_from = "String", into = "String")]
        pub struct $name(String);

        impl $name {
            pub fn new_random() -> Self {
                Self(format!("{}{}", $prefix, Uuid::new_v4().simple()))
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl TryFrom<String> for $name {
            type Error = String;

            fn try_from(value: String) -> Result<Self, Self::Error> {
                if value.starts_with($prefix) && value.len() > $prefix.len() {
                    Ok(Self(value))
                } else {
                    Err(format!("expected {} id", $prefix))
                }
            }
        }

        impl From<$name> for String {
            fn from(value: $name) -> Self {
                value.0
            }
        }

        impl FromStr for $name {
            type Err = String;

            fn from_str(value: &str) -> Result<Self, Self::Err> {
                Self::try_from(value.to_string())
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&self.0)
            }
        }
    };
}

typed_id!(ProjectId, "prj_");
typed_id!(TaskId, "tsk_");
typed_id!(AttemptId, "att_");
typed_id!(HostId, "hst_");
typed_id!(FencingToken, "fen_");
typed_id!(EventId, "evt_");
typed_id!(ReviewSnapshotId, "rev_");
typed_id!(MergeQueueId, "mrq_");

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaneRef {
    pub host_id: HostId,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app_socket_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub panel_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActorKind {
    Leader,
    Agent,
    System,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Actor {
    pub kind: ActorKind,
    pub id: String,
}

impl Default for Actor {
    fn default() -> Self {
        Self {
            kind: ActorKind::System,
            id: "tm-coordinator".to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Pending,
    Placed,
    Assigned,
    InProgress,
    Suspect,
    Blocked,
    Quarantined,
    Reassigned,
    ReviewReady,
    Approved,
    Rejected,
    QueuedForMerge,
    Merged,
    Failed,
    Cancelled,
}

impl TaskStatus {
    pub fn can_transition_to(&self, next: &TaskStatus) -> bool {
        use TaskStatus::*;
        match (self, next) {
            (Pending, Placed | Assigned | Suspect | Blocked | Quarantined | Cancelled) => true,
            (
                Placed,
                Assigned | InProgress | Suspect | Blocked | Quarantined | ReviewReady | Cancelled,
            ) => true,
            (Assigned, InProgress | Suspect | Blocked | Quarantined | Cancelled) => true,
            (InProgress, Suspect | Blocked | ReviewReady | Failed | Cancelled) => true,
            (Suspect, Reassigned | Quarantined | Blocked | Cancelled) => true,
            (Blocked, Reassigned | Assigned | InProgress | Quarantined | Cancelled | Failed) => {
                true
            }
            (Quarantined, Reassigned | Cancelled | Failed) => true,
            (Reassigned, Placed | Assigned | InProgress | Blocked | Cancelled) => true,
            (ReviewReady, Approved | Rejected | Blocked | Cancelled) => true,
            (Approved, QueuedForMerge | Merged | Failed) => true,
            (QueuedForMerge, Merged | Failed | Cancelled) => true,
            (Rejected, Reassigned | Assigned | Cancelled) => true,
            (Merged | Failed | Cancelled, _) => false,
            (a, b) if a == b => true,
            _ => false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProjectState {
    Active,
    Archived,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Project {
    pub project_id: ProjectId,
    pub root_path: String,
    pub name: String,
    pub created_at_ms: u64,
    pub updated_at_ms: u64,
    pub hosts: Vec<HostId>,
    pub state: ProjectState,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Placement {
    pub host_id: HostId,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pane_ref: Option<PaneRef>,
    pub mode: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HostObservation {
    pub host_id: HostId,
    pub os: String,
    pub arch: String,
    pub load: f64,
    pub total_slots: u32,
    pub used_slots: u32,
    pub project_roots: Vec<String>,
    /// Project roots whose team leader runs on THIS host. Once a project
    /// spans machines, "where does its leader sit" is the first thing anyone
    /// needs, and no single machine can answer it from its own state.
    /// Defaulted so observations recorded before this field replay cleanly.
    #[serde(default)]
    pub leader_projects: Vec<String>,
    pub live: bool,
    pub quarantined: bool,
    pub observed_at_ms: u64,
}

impl HostObservation {
    pub fn available_slots(&self) -> u32 {
        self.total_slots.saturating_sub(self.used_slots)
    }

    pub fn is_eligible_for(&self, root_path: &str) -> bool {
        self.live
            && !self.quarantined
            && self.available_slots() > 0
            && self.project_roots.iter().any(|root| root == root_path)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Task {
    pub task_id: TaskId,
    pub project_id: ProjectId,
    pub title: String,
    pub body: String,
    pub status: TaskStatus,
    pub priority: i64,
    pub depends_on: Vec<TaskId>,
    pub created_by: String,
    pub created_at_ms: u64,
    pub updated_at_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub current_attempt_id: Option<AttemptId>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub placement: Option<Placement>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Attempt {
    pub attempt_id: AttemptId,
    pub task_id: TaskId,
    pub project_id: ProjectId,
    pub status: String,
    pub host_id: HostId,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pane_ref: Option<PaneRef>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub worktree_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base_ref: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub head_ref: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub head_sha: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fencing_token: Option<FencingToken>,
    pub created_at_ms: u64,
    pub updated_at_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MergeQueueStatus {
    Queued,
    Running,
    Merged,
    Failed,
    Cancelled,
}

impl MergeQueueStatus {
    pub fn can_transition_to(&self, next: &MergeQueueStatus) -> bool {
        use MergeQueueStatus::*;
        match (self, next) {
            (Queued, Running | Cancelled) => true,
            (Running, Merged | Failed | Cancelled) => true,
            (Merged | Failed | Cancelled, _) => false,
            (a, b) if a == b => true,
            _ => false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReviewFileSummary {
    pub path: String,
    pub kind: String,
    pub add: i64,
    pub del: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReviewSnapshot {
    pub snapshot_id: ReviewSnapshotId,
    pub task_id: TaskId,
    pub attempt_id: AttemptId,
    pub base_sha: String,
    pub head_sha: String,
    pub diff_digest: String,
    pub summary: String,
    pub files: Vec<ReviewFileSummary>,
    pub created_at_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MergeQueueItem {
    pub queue_id: MergeQueueId,
    pub project_id: ProjectId,
    pub task_id: TaskId,
    pub attempt_id: AttemptId,
    pub status: MergeQueueStatus,
    pub approved_by: String,
    pub approved_at_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IntentEvent {
    pub schema: u32,
    pub event_id: EventId,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub project_id: Option<ProjectId>,
    pub actor: Actor,
    pub ts_ms: u64,
    pub payload: Value,
}

impl IntentEvent {
    pub fn new(
        kind: impl Into<String>,
        request_id: Option<String>,
        project_id: Option<ProjectId>,
        payload: Value,
    ) -> Self {
        Self {
            schema: 1,
            event_id: EventId::new_random(),
            request_id,
            kind: kind.into(),
            project_id,
            actor: Actor::default(),
            ts_ms: now_ms(),
            payload,
        }
    }
}

pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
