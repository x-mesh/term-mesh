use crate::model::{AttemptId, FencingToken, TaskId};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FenceRecord {
    pub task_id: TaskId,
    pub attempt_id: Option<AttemptId>,
    pub holder: String,
    pub token: FencingToken,
    pub generation: i64,
    pub expires_at_ms: Option<u64>,
}
