use super::{
    KeyId, ObjectId, ProjectId, ProjectKey, ResumeToken, RouterError, StageId, StreamLane,
    StreamRouterSender,
};
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
use std::sync::Mutex;
use sync_protocol::{WireBinding, WireBody, WireFrame};
const MAGIC: &[u8; 4] = b"TMCP";
const VERSION: u16 = 1;
const MAX_RANGES: usize = 4096;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransferCheckpoint {
    pub project_id: ProjectId,
    pub operation_id: [u8; 16],
    pub object_id: ObjectId,
    pub stage_id: StageId,
    pub resume_token: ResumeToken,
    pub key_id: KeyId,
    pub generation: u64,
    pub verified_ranges: Vec<(u32, u32)>,
    pub mac: [u8; 32],
}
impl TransferCheckpoint {
    pub fn seal(mut self, key: &ProjectKey) -> Result<Self, TransferError> {
        self.mac = [0; 32];
        self.mac = key.keyed_hash(&self.encode_inner()?);
        Ok(self)
    }
    pub fn canonical_bytes(&self) -> Result<Vec<u8>, TransferError> {
        let mut o = self.encode_inner()?;
        o.extend_from_slice(&self.mac);
        Ok(o)
    }
    pub fn decode(input: &[u8], key: &ProjectKey) -> Result<Self, TransferError> {
        if input.len() < 4 + 2 + 2 + 32 + 16 + 32 + 16 + 32 + 16 + 8 + 2 + 32
            || &input[..4] != MAGIC
            || u16::from_be_bytes(input[4..6].try_into().unwrap()) != VERSION
            || input[6..8] != [0, 0]
        {
            return Err(TransferError::Checkpoint);
        }
        let body = &input[..input.len() - 32];
        let mut o = 8;
        let project_id = ProjectId::from_bytes(arr(input, &mut o)?);
        let operation_id = arr(input, &mut o)?;
        let object_id = ObjectId(arr(input, &mut o)?);
        let stage_id = StageId::from_bytes(arr(input, &mut o)?);
        let resume_token = ResumeToken::from_bytes(arr(input, &mut o)?);
        let key_id = KeyId(arr(input, &mut o)?);
        let generation = u64::from_be_bytes(arr(input, &mut o)?);
        let n = u16::from_be_bytes(arr(input, &mut o)?) as usize;
        if n > MAX_RANGES {
            return Err(TransferError::Checkpoint);
        }
        let mut verified_ranges = Vec::with_capacity(n);
        let mut last = 0;
        for _ in 0..n {
            let s = u32::from_be_bytes(arr(input, &mut o)?);
            let e = u32::from_be_bytes(arr(input, &mut o)?);
            if s < last || s >= e {
                return Err(TransferError::Checkpoint);
            }
            last = e;
            verified_ranges.push((s, e));
        }
        if o + 32 != input.len() {
            return Err(TransferError::Checkpoint);
        }
        let mac = arr(input, &mut o)?;
        if key.keyed_hash(body) != mac {
            return Err(TransferError::Checkpoint);
        }
        Ok(Self {
            project_id,
            operation_id,
            object_id,
            stage_id,
            resume_token,
            key_id,
            generation,
            verified_ranges,
            mac,
        })
    }
    fn encode_inner(&self) -> Result<Vec<u8>, TransferError> {
        if self.verified_ranges.len() > MAX_RANGES {
            return Err(TransferError::Checkpoint);
        }
        let mut o = Vec::new();
        o.extend_from_slice(MAGIC);
        o.extend_from_slice(&VERSION.to_be_bytes());
        o.extend_from_slice(&[0, 0]);
        o.extend_from_slice(self.project_id.as_bytes());
        o.extend_from_slice(&self.operation_id);
        o.extend_from_slice(&self.object_id.0);
        o.extend_from_slice(self.stage_id.as_bytes());
        o.extend_from_slice(self.resume_token.as_bytes());
        o.extend_from_slice(&self.key_id.0);
        o.extend_from_slice(&self.generation.to_be_bytes());
        o.extend_from_slice(&(self.verified_ranges.len() as u16).to_be_bytes());
        let mut last = 0;
        for (s, e) in &self.verified_ranges {
            if *s < last || s >= e {
                return Err(TransferError::Checkpoint);
            }
            o.extend_from_slice(&s.to_be_bytes());
            o.extend_from_slice(&e.to_be_bytes());
            last = *e;
        }
        Ok(o)
    }
}
fn arr<const N: usize>(i: &[u8], o: &mut usize) -> Result<[u8; N], TransferError> {
    let e = o.checked_add(N).ok_or(TransferError::Checkpoint)?;
    let v = i.get(*o..e).ok_or(TransferError::Checkpoint)?;
    *o = e;
    Ok(v.try_into().unwrap())
}

pub struct WireTrace {
    file: Mutex<File>,
    sequence: Mutex<u64>,
}
#[derive(Debug, Clone, Copy)]
pub enum TraceDirection {
    Tx,
    Rx,
}
#[derive(Debug, Clone, Copy)]
pub enum TraceMessage {
    BlobChunk,
    StreamPreface,
    OplogBatch,
    ManifestNodes,
    SyncControl,
}
impl WireTrace {
    pub fn create(path: &Path) -> Result<Self, TransferError> {
        if let Some(p) = path.parent() {
            std::fs::create_dir_all(p)?;
        }
        Ok(Self {
            file: Mutex::new(
                OpenOptions::new()
                    .create(true)
                    .create_new(true)
                    .write(true)
                    .mode(0o600)
                    .open(path)?,
            ),
            sequence: Mutex::new(0),
        })
    }
    pub fn record(
        &self,
        direction: TraceDirection,
        lane: StreamLane,
        message: TraceMessage,
        wire_bytes: usize,
        item_count: usize,
        chunk: Option<u32>,
        retransmit: bool,
    ) -> Result<(), TransferError> {
        let mut seq = self.sequence.lock().map_err(|_| TransferError::Poisoned)?;
        let mut f = self.file.lock().map_err(|_| TransferError::Poisoned)?;
        serde_json::to_writer(
            &mut *f,
            &serde_json::json!({
                "v": 1, "seq": *seq, "direction": format!("{direction:?}"),
                "lane": format!("{lane:?}"), "message": format!("{message:?}"),
                "wire_bytes": wire_bytes, "item_count": item_count,
                "chunk_index": chunk, "retransmit": retransmit,
            }),
        )
        .map_err(|error| TransferError::Io(std::io::Error::other(error)))?;
        f.write_all(b"\n")?;
        *seq += 1;
        Ok(())
    }
    pub fn summary(
        &self,
        path_items: u64,
        path_bytes: u64,
        total_bytes: u64,
    ) -> Result<(), TransferError> {
        let mut f = self.file.lock().map_err(|_| TransferError::Poisoned)?;
        writeln!(f,"{{\"v\":1,\"type\":\"summary\",\"path_items\":{path_items},\"path_bytes\":{path_bytes},\"total_bytes\":{total_bytes}}}")?;
        f.sync_all()?;
        Ok(())
    }
}
pub struct TransferSession<'a> {
    sender: &'a StreamRouterSender,
    trace: &'a WireTrace,
    expected: WireBinding,
}
impl TransferSession<'_> {
    pub fn new<'a>(
        sender: &'a StreamRouterSender,
        trace: &'a WireTrace,
        expected: WireBinding,
    ) -> TransferSession<'a> {
        TransferSession {
            sender,
            trace,
            expected,
        }
    }
    pub async fn enqueue(&self, frame: &WireFrame, retransmit: bool) -> Result<(), TransferError> {
        if frame.binding != self.expected {
            return Err(TransferError::Binding);
        }
        let bytes = frame.canonical_bytes()?;
        let (lane, name, items, chunk) = match &frame.body {
            WireBody::BlobChunk(v) => (
                StreamLane::Blob,
                TraceMessage::BlobChunk,
                1,
                Some(v.chunk_index),
            ),
            WireBody::StreamPreface(_) => {
                (StreamLane::Control, TraceMessage::StreamPreface, 1, None)
            }
            WireBody::OplogBatch(v) => (
                StreamLane::SyncOperation,
                TraceMessage::OplogBatch,
                v.records.len(),
                None,
            ),
            WireBody::ManifestNodeBatch(v) => (
                StreamLane::SyncOperation,
                TraceMessage::ManifestNodes,
                v.nodes.len(),
                None,
            ),
            _ => (
                StreamLane::SyncOperation,
                TraceMessage::SyncControl,
                1,
                None,
            ),
        };
        self.sender.send(lane, bytes.clone()).await?;
        self.trace.record(
            TraceDirection::Tx,
            lane,
            name,
            bytes.len(),
            items,
            chunk,
            retransmit,
        )?;
        Ok(())
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LogicalTransferReport {
    pub logical_bytes: u64,
    pub total_chunks: u32,
    pub verified_before_restart: u32,
    pub retransmitted_chunks: u32,
    pub retransmitted_verified_chunks: u32,
    pub peak_buffer_bytes: usize,
    pub observable_digest: [u8; 32],
}
/// Deterministic fixture describing the SHAPE of a large resumed transfer
/// report — fixed constants, NOT a measured 1 GiB transfer or a real
/// packet-loss/sleep-wake resume. It hashes a fixed buffer so
/// `observable_digest` is stable across runs, and exists only so callers
/// can assert the `LogicalTransferReport` struct/serialization is wired
/// correctly. A real resume-under-fault e2e is tracked separately; do not
/// read a pass here as "1 GiB transfer verified".
pub fn logical_transfer_fixture() -> LogicalTransferReport {
    let logical = 1024_u64 * 1024 * 1024;
    let chunks = 256;
    let verified = 231;
    let buffer = vec![0xa5; 4 * 1024 * 1024];
    let mut hasher = blake3::Hasher::new();
    hasher.update(b"term-mesh logical transfer fixture v1\0");
    for _ in 0..chunks {
        hasher.update(&buffer);
    }
    let observable_digest = *hasher.finalize().as_bytes();
    LogicalTransferReport {
        logical_bytes: logical,
        total_chunks: chunks,
        verified_before_restart: verified,
        retransmitted_chunks: chunks - verified,
        retransmitted_verified_chunks: 0,
        peak_buffer_bytes: 4 * 1024 * 1024,
        observable_digest,
    }
}

#[derive(Debug)]
pub enum TransferError {
    Io(std::io::Error),
    Protocol(sync_protocol::ProtocolError),
    Router(RouterError),
    Checkpoint,
    Binding,
    Poisoned,
}
impl From<std::io::Error> for TransferError {
    fn from(v: std::io::Error) -> Self {
        Self::Io(v)
    }
}
impl From<sync_protocol::ProtocolError> for TransferError {
    fn from(v: sync_protocol::ProtocolError) -> Self {
        Self::Protocol(v)
    }
}
impl From<RouterError> for TransferError {
    fn from(v: RouterError) -> Self {
        Self::Router(v)
    }
}
impl std::fmt::Display for TransferError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for TransferError {}
