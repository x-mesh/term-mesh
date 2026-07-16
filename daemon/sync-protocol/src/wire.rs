use crate::{ProtocolError, ID_BYTES, PROTOCOL_V1};

pub const MAX_WIRE_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_FRONTIERS: usize = 4096;
pub const MAX_HASHES: usize = 4096;
pub const MAX_MANIFEST_PAGE_BYTES: usize = 1024 * 1024;
pub const MAX_BLOB_ENVELOPE_BYTES: usize = 4 * 1024 * 1024 + 64;
pub const MAX_BATCH_RECORDS: usize = 1024;
const MAGIC: &[u8; 4] = b"TMWR";
pub const WIRE_HEADER_BYTES: usize = 4 + 2 + 1 + 1 + ID_BYTES + 8 + 16 + 4;
pub const OPLOG_BATCH_FIXED_BYTES: usize = 2;
pub const BLOB_LENGTH_PREFIX_BYTES: usize = 4;
const HEADER: usize = WIRE_HEADER_BYTES;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WireBinding {
    pub project_id: [u8; 32],
    pub roster_epoch: u64,
    pub operation_id: [u8; 16],
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrontierEntry {
    pub device_id: [u8; 32],
    pub sequence: u64,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ChunkRange {
    pub start: u32,
    pub end_exclusive: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamPreface {
    pub lane: u8,
    pub declared_length: Option<u64>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReconcileOffer {
    pub manifest_root: [u8; 32],
    pub frontier: Vec<FrontierEntry>,
    pub retained_floor: Vec<FrontierEntry>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestNodeRequest {
    pub hashes: Vec<[u8; 32]>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestNodeBatch {
    pub nodes: Vec<Vec<u8>>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MissingObject {
    pub hashes: Vec<[u8; 32]>,
    pub resume_ranges: Vec<ChunkRange>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlobChunk {
    pub object_id: [u8; 32],
    pub chunk_index: u32,
    pub plaintext_length: u32,
    pub envelope: Vec<u8>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OplogRangeRequest {
    pub device_id: [u8; 32],
    pub start: u64,
    pub end_exclusive: u64,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OplogBatch {
    pub records: Vec<Vec<u8>>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BatchAck {
    pub batch_hash: [u8; 32],
    pub durable_sequence: u64,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FullResyncRequired {
    pub manifest_root: [u8; 32],
    pub retained_floor: Vec<FrontierEntry>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Baseline {
    pub manifest_root: [u8; 32],
    pub frontier: Vec<FrontierEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WireBody {
    StreamPreface(StreamPreface),
    ReconcileOffer(ReconcileOffer),
    ManifestNodeRequest(ManifestNodeRequest),
    ManifestNodeBatch(ManifestNodeBatch),
    MissingObject(MissingObject),
    BlobChunk(BlobChunk),
    OplogRangeRequest(OplogRangeRequest),
    OplogBatch(OplogBatch),
    BatchAck(BatchAck),
    FullResyncRequired(FullResyncRequired),
    Baseline(Baseline),
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WireFrame {
    pub binding: WireBinding,
    pub body: WireBody,
}

impl WireFrame {
    pub fn canonical_bytes(&self) -> Result<Vec<u8>, ProtocolError> {
        let (kind, payload) = encode_body(&self.body)?;
        if HEADER + payload.len() > MAX_WIRE_BYTES {
            return Err(ProtocolError::InvalidWire("message too large"));
        }
        let mut out = Vec::with_capacity(HEADER + payload.len());
        out.extend_from_slice(MAGIC);
        out.extend_from_slice(&PROTOCOL_V1.to_be_bytes());
        out.push(kind);
        out.push(0);
        out.extend_from_slice(&self.binding.project_id);
        out.extend_from_slice(&self.binding.roster_epoch.to_be_bytes());
        out.extend_from_slice(&self.binding.operation_id);
        out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        out.extend_from_slice(&payload);
        Ok(out)
    }
    pub fn decode(input: &[u8]) -> Result<Self, ProtocolError> {
        if input.len() < HEADER || input.len() > MAX_WIRE_BYTES {
            return Err(ProtocolError::InvalidWire("length"));
        }
        if &input[..4] != MAGIC
            || u16::from_be_bytes([input[4], input[5]]) != PROTOCOL_V1
            || input[7] != 0
        {
            return Err(ProtocolError::InvalidWire("header"));
        }
        let length = u32::from_be_bytes(input[64..68].try_into().unwrap()) as usize;
        if HEADER.checked_add(length) != Some(input.len()) {
            return Err(ProtocolError::InvalidWire(
                "declared length or trailing bytes",
            ));
        }
        let mut project_id = [0; 32];
        project_id.copy_from_slice(&input[8..40]);
        let roster_epoch = u64::from_be_bytes(input[40..48].try_into().unwrap());
        let mut operation_id = [0; 16];
        operation_id.copy_from_slice(&input[48..64]);
        Ok(Self {
            binding: WireBinding {
                project_id,
                roster_epoch,
                operation_id,
            },
            body: decode_body(input[6], &input[HEADER..])?,
        })
    }
}

fn put_frontiers(out: &mut Vec<u8>, values: &[FrontierEntry]) -> Result<(), ProtocolError> {
    if values.len() > MAX_FRONTIERS || values.windows(2).any(|w| w[0].device_id >= w[1].device_id) {
        return Err(ProtocolError::InvalidWire("frontier order/count"));
    }
    out.extend_from_slice(&(values.len() as u16).to_be_bytes());
    for v in values {
        out.extend_from_slice(&v.device_id);
        out.extend_from_slice(&v.sequence.to_be_bytes());
    }
    Ok(())
}
fn get_frontiers(input: &[u8], o: &mut usize) -> Result<Vec<FrontierEntry>, ProtocolError> {
    let n = get_u16(input, o)? as usize;
    if n > MAX_FRONTIERS {
        return Err(ProtocolError::InvalidWire("frontier count"));
    }
    let mut v = Vec::with_capacity(n);
    for _ in 0..n {
        let device_id = get_arr(input, o)?;
        let sequence = get_u64(input, o)?;
        v.push(FrontierEntry {
            device_id,
            sequence,
        });
    }
    if v.windows(2).any(|w| w[0].device_id >= w[1].device_id) {
        return Err(ProtocolError::InvalidWire("frontier order"));
    }
    Ok(v)
}
fn put_hashes(out: &mut Vec<u8>, v: &[[u8; 32]]) -> Result<(), ProtocolError> {
    if v.len() > MAX_HASHES || v.windows(2).any(|w| w[0] >= w[1]) {
        return Err(ProtocolError::InvalidWire("hash order/count"));
    }
    out.extend_from_slice(&(v.len() as u16).to_be_bytes());
    for x in v {
        out.extend_from_slice(x)
    }
    Ok(())
}
fn get_hashes(i: &[u8], o: &mut usize) -> Result<Vec<[u8; 32]>, ProtocolError> {
    let n = get_u16(i, o)? as usize;
    if n > MAX_HASHES {
        return Err(ProtocolError::InvalidWire("hash count"));
    }
    let mut v = Vec::with_capacity(n);
    for _ in 0..n {
        v.push(get_arr(i, o)?)
    }
    if v.windows(2).any(|w| w[0] >= w[1]) {
        return Err(ProtocolError::InvalidWire("hash order"));
    }
    Ok(v)
}

fn encode_body(body: &WireBody) -> Result<(u8, Vec<u8>), ProtocolError> {
    let mut o = Vec::new();
    let k = match body {
        WireBody::StreamPreface(v) => {
            if v.lane > 3 {
                return Err(ProtocolError::InvalidWire("lane"));
            }
            o.push(v.lane);
            match v.declared_length {
                Some(n) => {
                    o.push(1);
                    o.extend_from_slice(&n.to_be_bytes())
                }
                None => o.push(0),
            };
            1
        }
        WireBody::ReconcileOffer(v) => {
            o.extend_from_slice(&v.manifest_root);
            put_frontiers(&mut o, &v.frontier)?;
            put_frontiers(&mut o, &v.retained_floor)?;
            2
        }
        WireBody::ManifestNodeRequest(v) => {
            put_hashes(&mut o, &v.hashes)?;
            3
        }
        WireBody::ManifestNodeBatch(v) => {
            put_blobs(&mut o, &v.nodes, MAX_MANIFEST_PAGE_BYTES, MAX_BATCH_RECORDS)?;
            4
        }
        WireBody::MissingObject(v) => {
            put_hashes(&mut o, &v.hashes)?;
            if v.resume_ranges.len() > MAX_HASHES {
                return Err(ProtocolError::InvalidWire("range count"));
            }
            o.extend_from_slice(&(v.resume_ranges.len() as u16).to_be_bytes());
            let mut last = 0;
            for r in &v.resume_ranges {
                if r.start < last || r.start >= r.end_exclusive {
                    return Err(ProtocolError::InvalidWire("ranges"));
                }
                o.extend_from_slice(&r.start.to_be_bytes());
                o.extend_from_slice(&r.end_exclusive.to_be_bytes());
                last = r.end_exclusive;
            }
            5
        }
        WireBody::BlobChunk(v) => {
            if v.envelope.len() > MAX_BLOB_ENVELOPE_BYTES {
                return Err(ProtocolError::InvalidWire("blob"));
            }
            o.extend_from_slice(&v.object_id);
            o.extend_from_slice(&v.chunk_index.to_be_bytes());
            o.extend_from_slice(&v.plaintext_length.to_be_bytes());
            o.extend_from_slice(&(v.envelope.len() as u32).to_be_bytes());
            o.extend_from_slice(&v.envelope);
            6
        }
        WireBody::OplogRangeRequest(v) => {
            if v.start >= v.end_exclusive {
                return Err(ProtocolError::InvalidWire("oplog range"));
            }
            o.extend_from_slice(&v.device_id);
            o.extend_from_slice(&v.start.to_be_bytes());
            o.extend_from_slice(&v.end_exclusive.to_be_bytes());
            7
        }
        WireBody::OplogBatch(v) => {
            put_blobs(
                &mut o,
                &v.records,
                MAX_WIRE_BYTES - HEADER,
                MAX_BATCH_RECORDS,
            )?;
            8
        }
        WireBody::BatchAck(v) => {
            o.extend_from_slice(&v.batch_hash);
            o.extend_from_slice(&v.durable_sequence.to_be_bytes());
            9
        }
        WireBody::FullResyncRequired(v) => {
            o.extend_from_slice(&v.manifest_root);
            put_frontiers(&mut o, &v.retained_floor)?;
            10
        }
        WireBody::Baseline(v) => {
            o.extend_from_slice(&v.manifest_root);
            put_frontiers(&mut o, &v.frontier)?;
            11
        }
    };
    Ok((k, o))
}

fn decode_body(k: u8, i: &[u8]) -> Result<WireBody, ProtocolError> {
    let mut o = 0;
    let b = match k {
        1 => {
            let lane = get_u8(i, &mut o)?;
            if lane > 3 {
                return Err(ProtocolError::InvalidWire("lane"));
            }
            let declared_length = match get_u8(i, &mut o)? {
                0 => None,
                1 => Some(get_u64(i, &mut o)?),
                _ => return Err(ProtocolError::InvalidWire("preface option")),
            };
            WireBody::StreamPreface(StreamPreface {
                lane,
                declared_length,
            })
        }
        2 => {
            let manifest_root = get_arr(i, &mut o)?;
            let frontier = get_frontiers(i, &mut o)?;
            let retained_floor = get_frontiers(i, &mut o)?;
            WireBody::ReconcileOffer(ReconcileOffer {
                manifest_root,
                frontier,
                retained_floor,
            })
        }
        3 => WireBody::ManifestNodeRequest(ManifestNodeRequest {
            hashes: get_hashes(i, &mut o)?,
        }),
        4 => WireBody::ManifestNodeBatch(ManifestNodeBatch {
            nodes: get_blobs(i, &mut o, MAX_MANIFEST_PAGE_BYTES, MAX_BATCH_RECORDS)?,
        }),
        5 => {
            let hashes = get_hashes(i, &mut o)?;
            let n = get_u16(i, &mut o)? as usize;
            if n > MAX_HASHES {
                return Err(ProtocolError::InvalidWire("range count"));
            }
            let mut resume_ranges = Vec::with_capacity(n);
            let mut last = 0;
            for _ in 0..n {
                let start = get_u32(i, &mut o)?;
                let end_exclusive = get_u32(i, &mut o)?;
                if start < last || start >= end_exclusive {
                    return Err(ProtocolError::InvalidWire("ranges"));
                }
                last = end_exclusive;
                resume_ranges.push(ChunkRange {
                    start,
                    end_exclusive,
                });
            }
            WireBody::MissingObject(MissingObject {
                hashes,
                resume_ranges,
            })
        }
        6 => {
            let object_id = get_arr(i, &mut o)?;
            let chunk_index = get_u32(i, &mut o)?;
            let plaintext_length = get_u32(i, &mut o)?;
            let n = get_u32(i, &mut o)? as usize;
            if n > MAX_BLOB_ENVELOPE_BYTES {
                return Err(ProtocolError::InvalidWire("blob"));
            }
            let envelope = take(i, &mut o, n)?.to_vec();
            WireBody::BlobChunk(BlobChunk {
                object_id,
                chunk_index,
                plaintext_length,
                envelope,
            })
        }
        7 => {
            let device_id = get_arr(i, &mut o)?;
            let start = get_u64(i, &mut o)?;
            let end_exclusive = get_u64(i, &mut o)?;
            if start >= end_exclusive {
                return Err(ProtocolError::InvalidWire("oplog range"));
            }
            WireBody::OplogRangeRequest(OplogRangeRequest {
                device_id,
                start,
                end_exclusive,
            })
        }
        8 => WireBody::OplogBatch(OplogBatch {
            records: get_blobs(i, &mut o, MAX_WIRE_BYTES, MAX_BATCH_RECORDS)?,
        }),
        9 => WireBody::BatchAck(BatchAck {
            batch_hash: get_arr(i, &mut o)?,
            durable_sequence: get_u64(i, &mut o)?,
        }),
        10 => WireBody::FullResyncRequired(FullResyncRequired {
            manifest_root: get_arr(i, &mut o)?,
            retained_floor: get_frontiers(i, &mut o)?,
        }),
        11 => WireBody::Baseline(Baseline {
            manifest_root: get_arr(i, &mut o)?,
            frontier: get_frontiers(i, &mut o)?,
        }),
        _ => return Err(ProtocolError::InvalidWire("kind")),
    };
    if o != i.len() {
        return Err(ProtocolError::InvalidWire("trailing bytes"));
    }
    Ok(b)
}

fn put_blobs(
    o: &mut Vec<u8>,
    v: &[Vec<u8>],
    max_bytes: usize,
    max_count: usize,
) -> Result<(), ProtocolError> {
    if v.len() > max_count {
        return Err(ProtocolError::InvalidWire("blob count"));
    }
    let total = blob_wire_len(v)?;
    if total > max_bytes {
        return Err(ProtocolError::InvalidWire("blob bytes"));
    }
    o.extend_from_slice(&(v.len() as u16).to_be_bytes());
    for b in v {
        let length = u32::try_from(b.len()).map_err(|_| ProtocolError::LengthOverflow)?;
        o.extend_from_slice(&length.to_be_bytes());
        o.extend_from_slice(b)
    }
    Ok(())
}
fn blob_wire_len(v: &[Vec<u8>]) -> Result<usize, ProtocolError> {
    v.iter().try_fold(2_usize, |total, blob| {
        total
            .checked_add(4)
            .and_then(|n| n.checked_add(blob.len()))
            .ok_or(ProtocolError::LengthOverflow)
    })
}
fn get_blobs(
    i: &[u8],
    o: &mut usize,
    max_bytes: usize,
    max_count: usize,
) -> Result<Vec<Vec<u8>>, ProtocolError> {
    let n = get_u16(i, o)? as usize;
    if n > max_count {
        return Err(ProtocolError::InvalidWire("blob count"));
    }
    let mut total: usize = 2;
    let mut v = Vec::with_capacity(n);
    for _ in 0..n {
        let l = get_u32(i, o)? as usize;
        total = total
            .checked_add(4)
            .and_then(|n| n.checked_add(l))
            .ok_or(ProtocolError::LengthOverflow)?;
        if total > max_bytes {
            return Err(ProtocolError::InvalidWire("blob bytes"));
        }
        v.push(take(i, o, l)?.to_vec())
    }
    Ok(v)
}
fn take<'a>(i: &'a [u8], o: &mut usize, n: usize) -> Result<&'a [u8], ProtocolError> {
    let e = o.checked_add(n).ok_or(ProtocolError::LengthOverflow)?;
    let v = i
        .get(*o..e)
        .ok_or(ProtocolError::InvalidWire("truncated"))?;
    *o = e;
    Ok(v)
}
fn get_u8(i: &[u8], o: &mut usize) -> Result<u8, ProtocolError> {
    Ok(take(i, o, 1)?[0])
}
fn get_u16(i: &[u8], o: &mut usize) -> Result<u16, ProtocolError> {
    Ok(u16::from_be_bytes(take(i, o, 2)?.try_into().unwrap()))
}
fn get_u32(i: &[u8], o: &mut usize) -> Result<u32, ProtocolError> {
    Ok(u32::from_be_bytes(take(i, o, 4)?.try_into().unwrap()))
}
fn get_u64(i: &[u8], o: &mut usize) -> Result<u64, ProtocolError> {
    Ok(u64::from_be_bytes(take(i, o, 8)?.try_into().unwrap()))
}
fn get_arr<const N: usize>(i: &[u8], o: &mut usize) -> Result<[u8; N], ProtocolError> {
    Ok(take(i, o, N)?.try_into().unwrap())
}
