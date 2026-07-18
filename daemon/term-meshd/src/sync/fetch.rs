//! Fetch phase of a sync operation (Phase S2c of the mesh-project-sync wiring
//! plan): the initiator asks the peer for the files its diff says it lacks, the
//! peer streams each one's encrypted chunks, and the initiator stages them into
//! CAS ready for `ApplyStore::apply`.
//!
//! Unlike the S2a Blob-lane primitive, the fetch phase runs entirely on the
//! ORDERED `SyncOperation` lane — a header is immediately followed by exactly
//! its object's chunks — so the initiator never has to reassemble across the
//! lane scheduler's reordering. Bulk transfer can move to the Blob lane once the
//! connection demuxes lanes into separate inboxes (a later optimization).
//!
//! The responder serves only paths in its own manifest (an untrusted requested
//! path that the peer does not actually have is skipped), so a request cannot
//! read arbitrary files.

use std::collections::HashMap;
use std::path::Path;

use tokio::time::{timeout, Duration};

use super::{
    build_apply_plan, build_delete_plan, check_delete_guard, put_plaintext, ApplyStore, CasStore,
    EncryptedChunk, EntryKind, FetchEntry,
    KeyId, ManifestEntry, ObjectDomain, ObjectId, ProjectId, ProjectKey, StreamLane, SyncConnection,
};

const FETCH_TIMEOUT: Duration = Duration::from_secs(60);
const NONCE_LEN: usize = 24;

const TAG_REQUEST: u8 = 1;
const TAG_HEADER: u8 = 2;
const TAG_CHUNK: u8 = 3;
const TAG_DONE: u8 = 4;
const TAG_PUSH_MANIFEST: u8 = 5;
const TAG_PUSH_ACK: u8 = 6;

// ── wire codec ──────────────────────────────────────────────────────────────

fn encode_request(paths: &[&str]) -> Vec<u8> {
    let mut out = vec![TAG_REQUEST];
    out.extend_from_slice(&(paths.len() as u32).to_be_bytes());
    for path in paths {
        out.extend_from_slice(&(path.len() as u32).to_be_bytes());
        out.extend_from_slice(path.as_bytes());
    }
    out
}

fn decode_request(payload: &[u8]) -> Result<Vec<String>, String> {
    let mut r = Reader::new(payload);
    if r.u8()? != TAG_REQUEST {
        return Err("fetch_bad_message".into());
    }
    let count = r.u32()? as usize;
    if count > 4_000_000 {
        return Err("fetch_too_large".into());
    }
    let mut paths = Vec::with_capacity(count.min(1024));
    for _ in 0..count {
        let len = r.u32()? as usize;
        paths.push(r.string(len)?);
    }
    Ok(paths)
}

fn encode_header(path: &str, object_id: ObjectId, length: u64) -> Vec<u8> {
    let mut out = vec![TAG_HEADER];
    out.extend_from_slice(&(path.len() as u32).to_be_bytes());
    out.extend_from_slice(path.as_bytes());
    out.extend_from_slice(&object_id.0);
    out.extend_from_slice(&length.to_be_bytes());
    out
}

fn encode_chunk(object_id: ObjectId, index: u32, envelope: &EncryptedChunk) -> Vec<u8> {
    let mut out = vec![TAG_CHUNK];
    out.extend_from_slice(&object_id.0);
    out.extend_from_slice(&index.to_be_bytes());
    out.extend_from_slice(envelope.nonce());
    out.extend_from_slice(envelope.ciphertext());
    out
}

fn encode_done() -> Vec<u8> {
    vec![TAG_DONE]
}

/// The responder's verdict on a completed push: whether the apply succeeded and
/// how many plan entries landed. Sending the bytes is not the same as the peer
/// having them on disk, so `run_push` waits for this before reporting success —
/// otherwise a caller (an operation, a test) can observe "sync succeeded" while
/// the peer's apply is still in flight or has already failed.
fn encode_push_ack(applied: Option<u64>) -> Vec<u8> {
    let mut out = vec![TAG_PUSH_ACK];
    match applied {
        Some(count) => {
            out.push(1);
            out.extend_from_slice(&count.to_be_bytes());
        }
        None => out.push(0),
    }
    out
}

fn decode_push_ack(payload: &[u8]) -> Result<u64, String> {
    let mut r = Reader::new(payload);
    if r.u8()? != TAG_PUSH_ACK {
        return Err("push_bad_message".into());
    }
    if r.u8()? == 0 {
        return Err("push_rejected".into());
    }
    r.u64()
}

fn kind_from_u8(value: u8) -> Result<EntryKind, String> {
    match value {
        1 => Ok(EntryKind::File),
        2 => Ok(EntryKind::Directory),
        3 => Ok(EntryKind::Symlink),
        _ => Err("push_bad_kind".into()),
    }
}

/// The push manifest: the full set of entries the initiator is pushing (files,
/// dirs, symlinks) plus the paths it wants REMOVED, so the responder can build an
/// apply plan that creates ancestors + symlinks and drops what the initiator
/// deleted. One message on the SyncOperation lane (bounded like the request).
fn encode_push_manifest(entries: &[FetchEntry], deletes: &[String]) -> Vec<u8> {
    let mut out = vec![TAG_PUSH_MANIFEST];
    out.extend_from_slice(&(entries.len() as u32).to_be_bytes());
    for entry in entries {
        out.extend_from_slice(&(entry.relative_path.len() as u32).to_be_bytes());
        out.extend_from_slice(entry.relative_path.as_bytes());
        out.push(entry.kind as u8);
        out.push(entry.executable as u8);
        out.extend_from_slice(&entry.length.to_be_bytes());
        out.extend_from_slice(&entry.content_hash);
        match &entry.symlink_target {
            Some(target) => {
                out.push(1);
                out.extend_from_slice(&(target.len() as u32).to_be_bytes());
                out.extend_from_slice(target.as_bytes());
            }
            None => out.push(0),
        }
    }
    out.extend_from_slice(&(deletes.len() as u32).to_be_bytes());
    for path in deletes {
        out.extend_from_slice(&(path.len() as u32).to_be_bytes());
        out.extend_from_slice(path.as_bytes());
    }
    out
}

fn decode_push_manifest(payload: &[u8]) -> Result<(Vec<FetchEntry>, Vec<String>), String> {
    let mut r = Reader::new(payload);
    if r.u8()? != TAG_PUSH_MANIFEST {
        return Err("push_bad_message".into());
    }
    let count = r.u32()? as usize;
    if count > 4_000_000 {
        return Err("push_too_large".into());
    }
    let mut entries = Vec::with_capacity(count.min(1024));
    for _ in 0..count {
        let path_len = r.u32()? as usize;
        let relative_path = r.string(path_len)?;
        let kind = kind_from_u8(r.u8()?)?;
        let executable = r.u8()? != 0;
        let length = r.u64()?;
        let content_hash = r.array::<32>()?;
        let symlink_target = if r.u8()? != 0 {
            let target_len = r.u32()? as usize;
            Some(r.string(target_len)?)
        } else {
            None
        };
        entries.push(FetchEntry {
            relative_path,
            kind,
            executable,
            length,
            content_hash,
            symlink_target,
        });
    }
    let delete_count = r.u32()? as usize;
    if delete_count > 4_000_000 {
        return Err("push_too_large".into());
    }
    let mut deletes = Vec::with_capacity(delete_count.min(1024));
    for _ in 0..delete_count {
        let len = r.u32()? as usize;
        deletes.push(r.string(len)?);
    }
    // Reject trailing bytes: a peer speaking a longer message than this build
    // understands must fail loudly, not have the tail silently ignored.
    if r.offset != payload.len() {
        return Err("push_bad_message".into());
    }
    Ok((entries, deletes))
}

/// A decoded fetch-phase message from the initiator's perspective.
enum Incoming {
    Header {
        path: String,
        object_id: ObjectId,
        length: u64,
    },
    Chunk {
        object_id: ObjectId,
        index: u32,
        envelope: EncryptedChunk,
    },
    Done,
}

fn decode_incoming(payload: &[u8]) -> Result<Incoming, String> {
    let mut r = Reader::new(payload);
    match r.u8()? {
        TAG_HEADER => {
            let path_len = r.u32()? as usize;
            let path = r.string(path_len)?;
            let object_id = ObjectId(r.array::<32>()?);
            let length = r.u64()?;
            Ok(Incoming::Header {
                path,
                object_id,
                length,
            })
        }
        TAG_CHUNK => {
            let object_id = ObjectId(r.array::<32>()?);
            let index = r.u32()?;
            let nonce = r.array::<NONCE_LEN>()?;
            let ciphertext = r.rest().to_vec();
            Ok(Incoming::Chunk {
                object_id,
                index,
                envelope: EncryptedChunk::from_parts(nonce, ciphertext),
            })
        }
        TAG_DONE => Ok(Incoming::Done),
        _ => Err("fetch_bad_message".into()),
    }
}

struct Reader<'a> {
    input: &'a [u8],
    offset: usize,
}

impl<'a> Reader<'a> {
    fn new(input: &'a [u8]) -> Self {
        Self { input, offset: 0 }
    }
    fn take(&mut self, n: usize) -> Result<&'a [u8], String> {
        let end = self.offset.checked_add(n).ok_or("fetch_truncated")?;
        let slice = self.input.get(self.offset..end).ok_or("fetch_truncated")?;
        self.offset = end;
        Ok(slice)
    }
    fn u8(&mut self) -> Result<u8, String> {
        Ok(self.take(1)?[0])
    }
    fn u32(&mut self) -> Result<u32, String> {
        Ok(u32::from_be_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn u64(&mut self) -> Result<u64, String> {
        Ok(u64::from_be_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn array<const N: usize>(&mut self) -> Result<[u8; N], String> {
        Ok(self.take(N)?.try_into().unwrap())
    }
    fn string(&mut self, len: usize) -> Result<String, String> {
        if len > 4096 {
            return Err("fetch_too_large".into());
        }
        std::str::from_utf8(self.take(len)?)
            .map(str::to_owned)
            .map_err(|_| "fetch_bad_utf8".into())
    }
    fn rest(&self) -> &'a [u8] {
        &self.input[self.offset..]
    }
}

// ── orchestration ───────────────────────────────────────────────────────────

/// The next control message on the `SyncOperation` lane (request / header / done).
async fn recv_syncop(connection: &mut SyncConnection) -> Result<Vec<u8>, String> {
    recv_on(connection, StreamLane::SyncOperation).await
}

/// The next chunk envelope on the `Blob` lane. Bulk transfer rides the Blob lane
/// so a large file's chunks do not head-of-line block control traffic; the
/// per-lane demux keeps the two from clobbering each other.
async fn recv_blob(connection: &mut SyncConnection) -> Result<Vec<u8>, String> {
    recv_on(connection, StreamLane::Blob).await
}

async fn recv_on(connection: &mut SyncConnection, lane: StreamLane) -> Result<Vec<u8>, String> {
    timeout(FETCH_TIMEOUT, connection.recv_lane(lane))
        .await
        .map_err(|_| "fetch_timeout".to_string())?
        .ok_or_else(|| "fetch_closed".to_string())
}

/// Number of `CHUNK_SIZE` chunks for a plaintext of `len` bytes.
fn chunks(len: u64) -> u32 {
    super::chunk_count_for(len)
}

/// Initiator side: request the files in `fetch`, stage each returned object into
/// `cas`, and return `path -> object_id` for the ones received (ready for the
/// apply plan). Directory/symlink entries carry no content and are not fetched.
pub async fn run_fetch_pull(
    connection: &mut SyncConnection,
    cas: &CasStore,
    domain: ObjectDomain,
    fetch: &[FetchEntry],
) -> Result<HashMap<String, ObjectId>, String> {
    let file_paths: Vec<&str> = fetch
        .iter()
        .filter(|entry| entry.kind == EntryKind::File)
        .map(|entry| entry.relative_path.as_str())
        .collect();
    connection
        .sender()
        .send(StreamLane::SyncOperation, encode_request(&file_paths))
        .await
        .map_err(|_| "fetch_send_failed".to_string())?;

    let mut resolved = HashMap::new();
    loop {
        match decode_incoming(&recv_syncop(connection).await?)? {
            Incoming::Done => break,
            Incoming::Header {
                path,
                object_id,
                length,
            } => {
                let expected = chunks(length);
                let mut staging = cas
                    .begin_stage(domain, object_id, length)
                    .map_err(|_| "cas_stage_failed".to_string())?;
                // The header (SyncOperation lane) is followed by exactly this
                // object's chunks on the Blob lane, in send order.
                for _ in 0..expected {
                    match decode_incoming(&recv_blob(connection).await?)? {
                        Incoming::Chunk {
                            object_id: chunk_object,
                            index,
                            envelope,
                        } if chunk_object == object_id => staging
                            .write_encrypted_chunk(index, &envelope)
                            .map_err(|_| "cas_write_failed".to_string())?,
                        _ => return Err("fetch_out_of_order".to_string()),
                    }
                }
                staging.finish().map_err(|_| "cas_finish_failed".to_string())?;
                resolved.insert(path, object_id);
            }
            _ => return Err("fetch_out_of_order".to_string()),
        }
    }
    Ok(resolved)
}

/// Responder side: answer a fetch request by streaming each requested file it
/// actually holds. `local` is the responder's own manifest (used to authorize
/// requested paths and to bound them to real files); `root` is its project
/// root, `key`/`key_id` its current project key.
pub async fn respond_to_fetch(
    connection: &mut SyncConnection,
    cas: &CasStore,
    root: &Path,
    domain: ObjectDomain,
    key: &ProjectKey,
    key_id: KeyId,
    local: &[ManifestEntry],
) -> Result<(), String> {
    let requested = decode_request(&recv_syncop(connection).await?)?;
    let known: HashMap<&str, &ManifestEntry> = local
        .iter()
        .map(|entry| (entry.relative_path.as_str(), entry))
        .collect();
    let sender = connection.sender();
    for path in &requested {
        let Some(entry) = known.get(path.as_str()) else {
            continue; // not in our manifest — never serve an arbitrary path
        };
        if entry.kind != EntryKind::File {
            continue;
        }
        let content = std::fs::read(root.join(path)).map_err(|_| "fetch_read_failed".to_string())?;
        let object_id = put_plaintext(cas, domain, key, key_id, &content)?;
        sender
            .send(
                StreamLane::SyncOperation,
                encode_header(path, object_id, content.len() as u64),
            )
            .await
            .map_err(|_| "fetch_send_failed".to_string())?;
        let live = cas
            .get_live(domain, object_id)
            .map_err(|_| "cas_read_failed".to_string())?
            .ok_or_else(|| "cas_object_missing".to_string())?;
        // The header rode the SyncOperation lane; the bulk chunks ride the Blob
        // lane so they do not head-of-line block control traffic.
        for index in 0..chunks(content.len() as u64) {
            let (_len, envelope) = live
                .read_encrypted_chunk(index)
                .map_err(|_| "cas_read_failed".to_string())?;
            sender
                .send(StreamLane::Blob, encode_chunk(object_id, index, &envelope))
                .await
                .map_err(|_| "fetch_send_failed".to_string())?;
        }
    }
    sender
        .send(StreamLane::SyncOperation, encode_done())
        .await
        .map_err(|_| "fetch_send_failed".to_string())?;
    Ok(())
}

/// Initiator side of a PUSH (mirror of [`respond_to_fetch`]): send the peer the
/// local-changed entries it should apply. First the push manifest (the full set
/// so the peer can create ancestors + symlinks), then each FILE's content
/// (HEADER immediately followed by its chunks), then DONE — and finally *wait for
/// the peer's apply ack*, so a successful return means the peer has the files on
/// disk, not merely that the bytes left this machine.
///
/// Returns the CAS object each pushed FILE landed on, so the caller can record
/// them as the new base objects for those paths.
pub async fn run_push(
    connection: &mut SyncConnection,
    cas: &CasStore,
    root: &Path,
    domain: ObjectDomain,
    key: &ProjectKey,
    key_id: KeyId,
    push: &[FetchEntry],
    deletes: &[String],
) -> Result<HashMap<String, ObjectId>, String> {
    let sender = connection.sender();
    let mut pushed = HashMap::new();
    sender
        .send(StreamLane::SyncOperation, encode_push_manifest(push, deletes))
        .await
        .map_err(|_| "push_send_failed".to_string())?;
    for entry in push {
        if entry.kind != EntryKind::File {
            continue; // dirs/symlinks carry no bytes; the manifest describes them
        }
        let content =
            std::fs::read(root.join(&entry.relative_path)).map_err(|_| "push_read_failed".to_string())?;
        let object_id = put_plaintext(cas, domain, key, key_id, &content)?;
        pushed.insert(entry.relative_path.clone(), object_id);
        sender
            .send(
                StreamLane::SyncOperation,
                encode_header(&entry.relative_path, object_id, content.len() as u64),
            )
            .await
            .map_err(|_| "push_send_failed".to_string())?;
        let live = cas
            .get_live(domain, object_id)
            .map_err(|_| "cas_read_failed".to_string())?
            .ok_or_else(|| "cas_object_missing".to_string())?;
        // Push rides the ordered SyncOperation lane end to end, so a header is
        // immediately followed by exactly its object's chunks and the receiver
        // never reassembles across lanes. Moving bulk push to the Blob lane (as
        // the fetch direction does) is a head-of-line-blocking optimization.
        for index in 0..chunks(content.len() as u64) {
            let (_len, envelope) = live
                .read_encrypted_chunk(index)
                .map_err(|_| "cas_read_failed".to_string())?;
            sender
                .send(
                    StreamLane::SyncOperation,
                    encode_chunk(object_id, index, &envelope),
                )
                .await
                .map_err(|_| "push_send_failed".to_string())?;
        }
    }
    sender
        .send(StreamLane::SyncOperation, encode_done())
        .await
        .map_err(|_| "push_send_failed".to_string())?;
    // Wait for the peer to report its apply. Returning at "all bytes sent" would
    // let the operation be marked succeeded while the peer has not written a
    // single file yet — and a failing apply would be lost entirely.
    decode_push_ack(&recv_syncop(connection).await?)?;
    Ok(pushed)
}

/// Responder side of a PUSH (mirror of [`run_fetch_pull`] + apply): receive the
/// push manifest + each file's chunks into `cas`, then apply the pushed entries
/// to the working tree at `root` (the initiator has already reconciled, so the
/// responder trusts the push). `local` is the responder's current manifest.
/// Returns the number of plan entries applied.
///
/// Always answers with a push ack — success or failure — because `run_push`
/// blocks on it; returning early without one would hang the initiator until its
/// fetch timeout.
pub async fn receive_push(
    connection: &mut SyncConnection,
    cas: &CasStore,
    root: &Path,
    domain: ObjectDomain,
    apply_store: &std::sync::Mutex<ApplyStore>,
    project: ProjectId,
    local: &[ManifestEntry],
) -> Result<u64, String> {
    let outcome =
        receive_push_inner(connection, cas, root, domain, apply_store, project, local).await;
    let _ = connection
        .sender()
        .send(
            StreamLane::SyncOperation,
            encode_push_ack(outcome.as_ref().ok().copied()),
        )
        .await;
    outcome
}

async fn receive_push_inner(
    connection: &mut SyncConnection,
    cas: &CasStore,
    root: &Path,
    domain: ObjectDomain,
    apply_store: &std::sync::Mutex<ApplyStore>,
    project: ProjectId,
    local: &[ManifestEntry],
) -> Result<u64, String> {
    let (push_entries, delete_paths) = decode_push_manifest(&recv_syncop(connection).await?)?;

    let mut resolved = HashMap::new();
    loop {
        match decode_incoming(&recv_syncop(connection).await?)? {
            Incoming::Done => break,
            Incoming::Header {
                path,
                object_id,
                length,
            } => {
                let mut staging = cas
                    .begin_stage(domain, object_id, length)
                    .map_err(|_| "cas_stage_failed".to_string())?;
                // Chunks ride the ordered SyncOperation lane immediately after the
                // header (see `run_push`).
                for _ in 0..chunks(length) {
                    match decode_incoming(&recv_syncop(connection).await?)? {
                        Incoming::Chunk {
                            object_id: chunk_object,
                            index,
                            envelope,
                        } if chunk_object == object_id => staging
                            .write_encrypted_chunk(index, &envelope)
                            .map_err(|_| "cas_write_failed".to_string())?,
                        _ => return Err("push_out_of_order".to_string()),
                    }
                }
                staging.finish().map_err(|_| "cas_finish_failed".to_string())?;
                resolved.insert(path, object_id);
            }
            _ => return Err("push_out_of_order".to_string()),
        }
    }

    let mut operation_id = [0u8; 16];
    getrandom::getrandom(&mut operation_id).map_err(|_| "push_apply_failed".to_string())?;
    let plan = build_apply_plan(project, operation_id, &push_entries, &resolved, local);
    let mut applied = plan.entries.len() as u64;
    if !plan.entries.is_empty() {
        // Lock only for the (synchronous) apply — never across the network recv
        // above, so the guard is not held over an await.
        let store = apply_store
            .lock()
            .map_err(|_| "push_apply_failed".to_string())?;
        store
            .apply(root, cas, domain, &plan)
            .map_err(|_| "push_apply_failed".to_string())?;
    }

    // Deletes the initiator propagated. Guarded on this side too: the responder
    // trusts the push, so the bound is the only thing standing between a peer
    // with a broken manifest and an emptied tree.
    if !delete_paths.is_empty() {
        check_delete_guard(delete_paths.len(), local.len())?;
        let mut delete_id = [0u8; 16];
        getrandom::getrandom(&mut delete_id).map_err(|_| "push_apply_failed".to_string())?;
        let delete_plan = build_delete_plan(project, delete_id, &delete_paths, local);
        if !delete_plan.entries.is_empty() {
            applied += delete_plan.entries.len() as u64;
            let store = apply_store
                .lock()
                .map_err(|_| "push_apply_failed".to_string())?;
            store
                .apply(root, cas, domain, &delete_plan)
                .map_err(|_| "push_apply_failed".to_string())?;
        }
    }
    Ok(applied)
}
