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
    for directory in parent.ancestors() {
        fs::set_permissions(directory, fs::Permissions::from_mode(0o700))
            .map_err(|error| error.to_string())?;
        if directory.file_name().is_some_and(|name| name == "questions-v1") {
            break;
        }
    }
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

fn apply_hook(action: &str, raw: &str, surface: &str, socket: &str) -> Result<(), String> {
    let hook: HookPayload =
        serde_json::from_str(raw).map_err(|_| "invalid hook payload".to_string())?;
    if hook.tool_name != "AskUserQuestion"
        || !safe_identifier(&surface)
        || !safe_identifier(&hook.session_id)
        || !safe_identifier(&hook.tool_use_id)
    {
        return Ok(());
    }
    let root = root_for_socket(socket);
    match action {
        "capture" => {
            let questions = parse_questions(&hook.tool_input)?;
            let path = root.join(surface).join(&hook.session_id).join(format!("{}.json", hook.tool_use_id));
            if let Ok(raw) = fs::read(&path) {
                if let Ok(existing) = serde_json::from_slice::<Record>(&raw) {
                    if existing.state == "pending" {
                        return Ok(());
                    }
                }
            }
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
                surface_id: surface.to_string(),
                session_id: hook.session_id,
                state: "pending".to_string(),
                questions,
            };
            write_record(&record_path(&root, &record), &record)
        }
        "answered" | "cancelled" | "expired" => {
            update_state(&root, &surface, &hook.session_id, &hook.tool_use_id, action);
            Ok(())
        }
        _ => Err("unknown claude-question action".to_string()),
    }
}

pub fn run(action: &str) -> Result<(), String> {
    let mut raw = String::new();
    std::io::stdin()
        .read_to_string(&mut raw)
        .map_err(|error| error.to_string())?;
    let surface = env::var("CMUX_SURFACE_ID").unwrap_or_default();
    let socket = env::var("TERMMESH_DAEMON_UNIX_PATH")
        .or_else(|_| env::var("TERMMESH_SOCKET"))
        .unwrap_or_else(|_| "/tmp/term-meshd.sock".to_string());
    apply_hook(action, &raw, &surface, &socket)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn payload(id: &str, questions: Value) -> String {
        json!({
            "session_id": "session-1", "tool_name": "AskUserQuestion",
            "tool_use_id": id, "tool_input": { "questions": questions }
        }).to_string()
    }

    fn read_record(socket: &str, id: &str) -> Record {
        let path = root_for_socket(socket).join("surface-1/session-1").join(format!("{id}.json"));
        serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
    }

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

    #[test]
    fn fixtures_store_unicode_multi_question_and_transition_states() {
        let temp = tempfile::tempdir().unwrap();
        let socket = temp.path().join("daemon.sock").display().to_string();
        let questions = json!([
            {"header": "선택", "question": "무엇을 할까요?", "options": [{"label": "계속 🚀"}]},
            {"question": "둘 다?", "multiSelect": true, "options": [{"label": "A"}, {"label": "B"}]}
        ]);
        let first = payload("tool-1", questions.clone());
        apply_hook("capture", &first, "surface-1", &socket).unwrap();
        assert_eq!(read_record(&socket, "tool-1").state, "pending");
        apply_hook("capture", &first, "surface-1", &socket).unwrap();
        assert_eq!(read_record(&socket, "tool-1").questions.len(), 2);
        apply_hook("answered", &first, "surface-1", &socket).unwrap();
        assert_eq!(read_record(&socket, "tool-1").state, "answered");
        let second = payload("tool-2", questions.clone());
        apply_hook("capture", &second, "surface-1", &socket).unwrap();
        apply_hook("cancelled", &second, "surface-1", &socket).unwrap();
        assert_eq!(read_record(&socket, "tool-2").state, "cancelled");
        let third = payload("tool-3", questions);
        apply_hook("capture", &third, "surface-1", &socket).unwrap();
        apply_hook("expired", &third, "surface-1", &socket).unwrap();
        assert_eq!(read_record(&socket, "tool-3").state, "expired");
    }

    #[test]
    fn a_new_capture_cancels_pending_and_writes_private_atomic_records() {
        let temp = tempfile::tempdir().unwrap();
        let socket = temp.path().join("daemon.sock").display().to_string();
        let one = payload("one", json!([{"question": "one", "options": [{"label": "yes"}]}]));
        let two = payload("two", json!([{"question": "two", "options": [{"label": "yes"}]}]));
        apply_hook("capture", &one, "surface-1", &socket).unwrap();
        apply_hook("capture", &two, "surface-1", &socket).unwrap();
        assert_eq!(read_record(&socket, "one").state, "cancelled");
        let directory = root_for_socket(&socket).join("surface-1/session-1");
        assert_eq!(fs::metadata(&directory).unwrap().permissions().mode() & 0o777, 0o700);
        assert_eq!(fs::metadata(directory.parent().unwrap()).unwrap().permissions().mode() & 0o777, 0o700);
        assert_eq!(fs::metadata(directory.parent().unwrap().parent().unwrap()).unwrap().permissions().mode() & 0o777, 0o700);
        assert_eq!(fs::metadata(directory.join("two.json")).unwrap().permissions().mode() & 0o777, 0o600);
        assert!(fs::read_dir(directory).unwrap().all(|entry| !entry.unwrap().file_name().to_string_lossy().ends_with(".tmp")));
    }

    #[test]
    fn malformed_and_oversized_payloads_fail_without_a_record() {
        let temp = tempfile::tempdir().unwrap();
        let socket = temp.path().join("daemon.sock").display().to_string();
        assert!(apply_hook("capture", "not json", "surface-1", &socket).is_err());
        let oversized = "x".repeat(MAX_LABEL_BYTES + 1);
        let invalid = payload("bad", json!([{"question": "q", "options": [{"label": oversized}]}]));
        assert!(apply_hook("capture", &invalid, "surface-1", &socket).is_err());
        assert!(parse_questions(&json!({
            "questions": [{
                "question": "q".repeat(MAX_QUESTION_BYTES + 1),
                "options": [{"label": "ok", "description": "x".repeat(MAX_DESCRIPTION_BYTES + 1)}]
            }]
        })).is_err());
        assert!(!root_for_socket(&socket).exists());
    }
}
