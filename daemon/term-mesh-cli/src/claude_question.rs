use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

const MAX_QUESTIONS: usize = 4;
const MAX_OPTIONS: usize = 4;
const MAX_QUESTION_BYTES: usize = 2048;
const MAX_LABEL_BYTES: usize = 512;
const MAX_DESCRIPTION_BYTES: usize = 1024;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct OptionInput {
    pub label: String,
    #[serde(default)]
    pub description: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct QuestionInput {
    #[serde(default)]
    pub header: String,
    pub question: String,
    #[serde(default, rename = "multiSelect")]
    pub multi_select: bool,
    pub options: Vec<OptionInput>,
}

#[derive(Debug, Deserialize)]
struct HookPayload {
    session_id: String,
    tool_name: String,
    tool_use_id: String,
    #[serde(default)]
    tool_input: Value,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Record {
    pub version: u8,
    pub provider: String,
    pub id: String,
    pub fingerprint: String,
    pub surface_id: String,
    pub session_id: String,
    pub state: String,
    pub questions: Vec<QuestionInput>,
}

fn safe_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}

fn valid_text(value: &str, maximum: usize, required: bool) -> bool {
    (!required || !value.is_empty())
        && value.len() <= maximum
        && !value.chars().any(char::is_control)
}

fn parse_questions(input: &Value) -> Result<Vec<QuestionInput>, String> {
    let questions: Vec<QuestionInput> =
        serde_json::from_value(input.get("questions").cloned().unwrap_or(Value::Null))
            .map_err(|_| "invalid AskUserQuestion payload".to_string())?;
    if questions.is_empty() || questions.len() > MAX_QUESTIONS {
        return Err("invalid AskUserQuestion count".into());
    }
    for question in &questions {
        if !valid_text(&question.header, MAX_LABEL_BYTES, false)
            || !valid_text(&question.question, MAX_QUESTION_BYTES, true)
            || question.options.is_empty()
            || question.options.len() > MAX_OPTIONS
        {
            return Err("invalid AskUserQuestion content".into());
        }
        if question.options.iter().any(|option| {
            !valid_text(&option.label, MAX_LABEL_BYTES, true)
                || !valid_text(&option.description, MAX_DESCRIPTION_BYTES, false)
        }) {
            return Err("invalid AskUserQuestion option".into());
        }
    }
    Ok(questions)
}

pub fn root_for_socket(socket: &str) -> PathBuf {
    let mut hash = Sha256::new();
    hash.update(socket.as_bytes());
    env::temp_dir()
        .join("term-mesh")
        .join("questions-v1")
        .join(format!("{:x}", hash.finalize()))
}

fn record_path(root: &Path, record: &Record) -> PathBuf {
    root.join(&record.surface_id)
        .join(&record.session_id)
        .join(format!("{}.json", record.id))
}

fn fingerprint(surface: &str, session: &str, id: &str, questions: &[QuestionInput]) -> String {
    let mut hash = Sha256::new();
    hash.update(
        serde_json::to_vec(&json!({
            "version": 1,
            "provider": "claude",
            "surface_id": surface,
            "session_id": session,
            "tool_use_id": id,
            "questions": questions,
        }))
        .expect("question fields serialize"),
    );
    format!("sha256:{:x}", hash.finalize())
}

fn write_record(path: &Path, record: &Record) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| "invalid record path".to_string())?;
    fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
        .map_err(|error| error.to_string())?;
    let temporary = path.with_extension(format!("{}.tmp", std::process::id()));
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&temporary)
        .map_err(|error| error.to_string())?;
    file.write_all(&serde_json::to_vec(record).map_err(|error| error.to_string())?)
        .map_err(|error| error.to_string())?;
    file.sync_all().map_err(|error| error.to_string())?;
    fs::rename(temporary, path).map_err(|error| error.to_string())
}

fn update_state(root: &Path, surface: &str, session: &str, id: &str, state: &str) {
    let path = root.join(surface).join(session).join(format!("{id}.json"));
    let Ok(mut file) = File::open(&path) else {
        return;
    };
    let mut bytes = Vec::new();
    if file.read_to_end(&mut bytes).is_err() {
        return;
    }
    let Ok(mut record) = serde_json::from_slice::<Record>(&bytes) else {
        return;
    };
    record.state = state.to_string();
    let _ = write_record(&path, &record);
}

pub fn run(action: &str) -> Result<(), String> {
    let mut raw = String::new();
    std::io::stdin()
        .read_to_string(&mut raw)
        .map_err(|error| error.to_string())?;
    let hook: HookPayload =
        serde_json::from_str(&raw).map_err(|_| "invalid hook payload".to_string())?;
    let surface = env::var("CMUX_SURFACE_ID").unwrap_or_default();
    if hook.tool_name != "AskUserQuestion"
        || !safe_identifier(&surface)
        || !safe_identifier(&hook.session_id)
        || !safe_identifier(&hook.tool_use_id)
    {
        return Ok(());
    }
    let socket = env::var("TERMMESH_DAEMON_UNIX_PATH")
        .or_else(|_| env::var("TERMMESH_SOCKET"))
        .unwrap_or_else(|_| "/tmp/term-meshd.sock".to_string());
    let root = root_for_socket(&socket);
    match action {
        "capture" => {
            let questions = parse_questions(&hook.tool_input)?;
            let session_dir = root.join(&surface).join(&hook.session_id);
            if let Ok(entries) = fs::read_dir(&session_dir) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    let Ok(raw) = fs::read(&path) else { continue };
                    let Ok(mut previous) = serde_json::from_slice::<Record>(&raw) else {
                        continue;
                    };
                    if previous.state == "pending" {
                        previous.state = "cancelled".to_string();
                        let _ = write_record(&path, &previous);
                    }
                }
            }
            let question_fingerprint =
                fingerprint(&surface, &hook.session_id, &hook.tool_use_id, &questions);
            let record = Record {
                version: 1,
                provider: "claude".to_string(),
                id: hook.tool_use_id,
                fingerprint: question_fingerprint,
                surface_id: surface,
                session_id: hook.session_id,
                state: "pending".to_string(),
                questions,
            };
            write_record(&record_path(&root, &record), &record)
        }
        "answered" | "cancelled" => {
            update_state(&root, &surface, &hook.session_id, &hook.tool_use_id, action);
            Ok(())
        }
        _ => Err("unknown claude-question action".to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn socket_hash_isolates_question_stores() {
        assert_ne!(
            root_for_socket("/tmp/a.sock"),
            root_for_socket("/tmp/b.sock")
        );
    }

    #[test]
    fn parser_rejects_control_characters() {
        assert!(parse_questions(&json!({
            "questions": [{"question": "bad\n", "options": [{"label": "yes"}]}]
        }))
        .is_err());
    }
}
