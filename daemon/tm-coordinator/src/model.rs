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
    Blocked,
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
            (Pending, Placed | Assigned | Blocked | Cancelled) => true,
            (Placed, Assigned | InProgress | Blocked | Cancelled) => true,
            (Assigned, InProgress | Blocked | Cancelled) => true,
            (InProgress, Blocked | ReviewReady | Failed | Cancelled) => true,
            (Blocked, Assigned | InProgress | Cancelled | Failed) => true,
            (ReviewReady, Approved | Rejected | Blocked | Cancelled) => true,
            (Approved, QueuedForMerge | Merged | Failed) => true,
            (QueuedForMerge, Merged | Failed | Cancelled) => true,
            (Rejected, Assigned | Cancelled) => true,
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
