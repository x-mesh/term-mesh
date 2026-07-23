use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard};

use serde_json::json;
use tempfile::tempdir;
use tm_coordinator::event_log::LocalJournalEventLog;
use tm_coordinator::{socket, Api, EventLog};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

static SOCKET_TEST_LOCK: Mutex<()> = Mutex::new(());

fn socket_test_lock() -> MutexGuard<'static, ()> {
    SOCKET_TEST_LOCK.lock().unwrap()
}

async fn connect_when_ready(sock: &Path) -> UnixStream {
    let mut last_error = None;
    for _ in 0..100 {
        match UnixStream::connect(sock).await {
            Ok(stream) => return stream,
            Err(error) => {
                last_error = Some(error);
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        }
    }
    panic!("socket did not become ready: {:?}", last_error);
}

#[tokio::test]
async fn uds_json_rpc_accepts_project_add_and_status() {
    let _guard = socket_test_lock();
    let dir = tempdir().unwrap();
    let sock = dir.path().join("coord.sock");
    let log: Arc<dyn EventLog> =
        Arc::new(LocalJournalEventLog::new(dir.path().join("events.ndjson")));
    let api = Api::for_tests(log).unwrap();
    let server_api = api.clone();
    let server_sock = sock.clone();
    let server = tokio::spawn(async move {
        let _ = socket::serve(server_api, &server_sock).await;
    });

    let mut stream = connect_when_ready(&sock).await;
    stream
        .write_all(
            serde_json::to_string(&json!({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "project.add",
                "params": {"request_id":"req1", "root_path":"/tmp/repo", "name":"repo"}
            }))
            .unwrap()
            .as_bytes(),
        )
        .await
        .unwrap();
    stream.write_all(b"\n").await.unwrap();

    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line).await.unwrap();
    let response: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["result"]["accepted"], true);
    server.abort();
}

/// JSON-RPC allows omitting `params`. Handlers whose fields are all optional
/// used to reject that with "invalid type: null", and a single failing call
/// sinks a client's whole snapshot — which reported a healthy coordinator as
/// offline.
#[tokio::test]
async fn omitted_params_are_accepted_for_all_optional_handlers() {
    let _guard = socket_test_lock();
    let dir = tempdir().unwrap();
    let sock = dir.path().join("coord.sock");
    let log: Arc<dyn EventLog> =
        Arc::new(LocalJournalEventLog::new(dir.path().join("events.ndjson")));
    let api = Api::for_tests(log).unwrap();
    let server_api = api.clone();
    let server_sock = sock.clone();
    let server = tokio::spawn(async move {
        let _ = socket::serve(server_api, &server_sock).await;
    });

    let stream = connect_when_ready(&sock).await;
    let mut reader = BufReader::new(stream);
    for (id, method) in [(1, "task.list"), (2, "host.list"), (3, "orchestration.status")] {
        reader
            .get_mut()
            .write_all(
                serde_json::to_string(&json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "method": method
                }))
                .unwrap()
                .as_bytes(),
            )
            .await
            .unwrap();
        reader.get_mut().write_all(b"\n").await.unwrap();

        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();
        let response: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert!(
            response.get("error").is_none(),
            "{method} rejected omitted params: {line}"
        );
    }
    server.abort();
}

#[tokio::test]
async fn events_subscribe_acks_then_streams_live_events() {
    let _guard = socket_test_lock();
    let dir = tempdir().unwrap();
    let sock = dir.path().join("coord.sock");
    let log: Arc<dyn EventLog> =
        Arc::new(LocalJournalEventLog::new(dir.path().join("events.ndjson")));
    let api = Api::for_tests(log).unwrap();
    let server_api = api.clone();
    let server_sock = sock.clone();
    let server = tokio::spawn(async move {
        let _ = socket::serve(server_api, &server_sock).await;
    });

    let mut subscriber = connect_when_ready(&sock).await;
    subscriber
        .write_all(
            serde_json::to_string(&json!({
                "jsonrpc": "2.0",
                "id": 7,
                "method": "events.subscribe",
                "params": {}
            }))
            .unwrap()
            .as_bytes(),
        )
        .await
        .unwrap();
    subscriber.write_all(b"\n").await.unwrap();
    let mut subscriber = BufReader::new(subscriber);
    let mut ack = String::new();
    subscriber.read_line(&mut ack).await.unwrap();
    let ack: serde_json::Value = serde_json::from_str(&ack).unwrap();
    assert_eq!(ack["result"]["subscribed"], true);

    api.handle(
        "project.add",
        json!({"request_id": "stream-req", "root_path": "/tmp/repo", "name": "repo"}),
    )
    .unwrap();

    let mut event = String::new();
    subscriber.read_line(&mut event).await.unwrap();
    let event: serde_json::Value = serde_json::from_str(&event).unwrap();
    assert_eq!(event["kind"], "project_added");
    assert_eq!(event["request_id"], "stream-req");
    server.abort();
}

#[tokio::test]
async fn oversized_no_newline_request_is_rejected_without_unbounded_read() {
    let _guard = socket_test_lock();
    let dir = tempdir().unwrap();
    let sock = dir.path().join("coord.sock");
    let log: Arc<dyn EventLog> =
        Arc::new(LocalJournalEventLog::new(dir.path().join("events.ndjson")));
    let api = Api::for_tests(log).unwrap();
    let server_api = api.clone();
    let server_sock = sock.clone();
    let server = tokio::spawn(async move {
        let _ = socket::serve(server_api, &server_sock).await;
    });

    let mut stream = connect_when_ready(&sock).await;
    stream.write_all(&vec![b'a'; 64 * 1024 + 1]).await.unwrap();

    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    tokio::time::timeout(
        std::time::Duration::from_secs(1),
        reader.read_line(&mut line),
    )
    .await
    .unwrap()
    .unwrap();
    let response: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["error"]["message"], "REQUEST_TOO_LARGE");
    server.abort();
}
