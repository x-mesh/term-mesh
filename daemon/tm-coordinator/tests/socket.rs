use std::sync::Arc;

use serde_json::json;
use tempfile::tempdir;
use tm_coordinator::event_log::LocalJournalEventLog;
use tm_coordinator::{socket, Api, EventLog};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

#[tokio::test]
async fn uds_json_rpc_accepts_project_add_and_status() {
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

    for _ in 0..100 {
        if sock.exists() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }

    let mut stream = UnixStream::connect(&sock).await.unwrap();
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

#[tokio::test]
async fn events_subscribe_acks_then_streams_live_events() {
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

    for _ in 0..100 {
        if sock.exists() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }

    let mut subscriber = UnixStream::connect(&sock).await.unwrap();
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

    for _ in 0..100 {
        if sock.exists() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }

    let mut stream = UnixStream::connect(&sock).await.unwrap();
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
