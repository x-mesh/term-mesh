//! CAS object transfer over the Blob lane (Phase S2a of the mesh-project-sync
//! wiring plan).
//!
//! The CAS has all the encode/store primitives (chunk, encrypt, stage, finish,
//! read) but nothing moved a chunk between two peers — `TransferSession` was
//! send-only and no code ever built a `BlobChunk`. This is that missing
//! sender↔receiver loop: [`send_object`] reads an object's encrypted chunks from
//! the source CAS and streams them over the Blob lane; [`recv_object`] stages
//! them into the destination CAS and finishes the object (which re-hashes and
//! enforces the [`ObjectId`], so a corrupted transfer is rejected).
//!
//! Chunks stay encrypted end to end — the sender never decrypts; the receiver
//! verifies each chunk under the shared project key when it stages it. A file's
//! bytes therefore reproduce on the peer only if the project key matches.

use tokio::time::{timeout, Duration};

use super::{
    encrypt_chunk_for_key, CasStore, EncryptedChunk, KeyId, ObjectDomain, ObjectId, ProjectKey,
    StreamLane, SyncConnection, CHUNK_SIZE,
};

/// How long to wait for the next blob chunk before failing the transfer.
const BLOB_TIMEOUT: Duration = Duration::from_secs(60);
/// XChaCha20 nonce width (mirrors `crypto::NONCE_BYTES`).
const NONCE_LEN: usize = 24;
/// Fixed prefix of a blob-chunk message: object id + chunk index + nonce.
const HEADER_LEN: usize = 32 + 4 + NONCE_LEN;

/// Number of `CHUNK_SIZE` chunks a plaintext of `len` bytes occupies.
pub fn chunk_count_for(len: u64) -> u32 {
    if len == 0 {
        0
    } else {
        len.div_ceil(CHUNK_SIZE as u64) as u32
    }
}

/// Chunk + encrypt `plaintext` into `cas` under `domain`, returning its object
/// id. `key`/`key_id` must be the CAS's current project key (what `begin_stage`
/// selects) so the staged chunks verify.
pub fn put_plaintext(
    cas: &CasStore,
    domain: ObjectDomain,
    key: &ProjectKey,
    key_id: KeyId,
    plaintext: &[u8],
) -> Result<ObjectId, String> {
    let object_id = ObjectId::for_plaintext(domain, plaintext);
    let len = plaintext.len() as u64;
    let mut staging = cas
        .begin_stage(domain, object_id, len)
        .map_err(|_| "cas_stage_failed".to_string())?;
    // `chunks()` yields nothing for an empty slice, but the CAS counts a
    // zero-length object as ONE chunk (`validate_chunk_count`) — so iterating
    // the slice directly writes no chunk for an empty file and `finish` then
    // rejects it as incomplete. An empty file is ordinary (`__init__.py`,
    // `.gitkeep`), so it has to carry its one empty chunk.
    let chunks: Vec<&[u8]> = if plaintext.is_empty() {
        vec![&[]]
    } else {
        plaintext.chunks(CHUNK_SIZE).collect()
    };
    for (index, chunk) in chunks.into_iter().enumerate() {
        let envelope =
            encrypt_chunk_for_key(key, key_id, domain, object_id, len, index as u32, chunk)
                .map_err(|_| "cas_encrypt_failed".to_string())?;
        staging
            .write_encrypted_chunk(index as u32, &envelope)
            .map_err(|_| "cas_write_failed".to_string())?;
    }
    staging.finish().map_err(|error| {
                    // Keep the reason: `finish` fails on a decrypt error, a
                    // chunk-length mismatch, an identity mismatch and several
                    // I/O faults, and collapsing them all to one code makes a
                    // real failure unactionable.
                    tracing::warn!(?error, "CAS finish failed");
                    "cas_finish_failed".to_string()
                })?;
    Ok(object_id)
}

/// `[object_id 32][chunk_index u32 BE][nonce 24][ciphertext…]`.
fn frame_chunk(object_id: ObjectId, index: u32, envelope: &EncryptedChunk) -> Vec<u8> {
    let mut message = Vec::with_capacity(HEADER_LEN + envelope.ciphertext().len());
    message.extend_from_slice(&object_id.0);
    message.extend_from_slice(&index.to_be_bytes());
    message.extend_from_slice(envelope.nonce());
    message.extend_from_slice(envelope.ciphertext());
    message
}

fn parse_chunk(payload: &[u8]) -> Result<(ObjectId, u32, EncryptedChunk), String> {
    if payload.len() < HEADER_LEN {
        return Err("blob_frame_truncated".to_string());
    }
    let mut object_id = [0u8; 32];
    object_id.copy_from_slice(&payload[0..32]);
    let index = u32::from_be_bytes(payload[32..36].try_into().unwrap());
    let mut nonce = [0u8; NONCE_LEN];
    nonce.copy_from_slice(&payload[36..HEADER_LEN]);
    let ciphertext = payload[HEADER_LEN..].to_vec();
    Ok((
        ObjectId(object_id),
        index,
        EncryptedChunk::from_parts(nonce, ciphertext),
    ))
}

/// Stream every encrypted chunk of `object_id` from `cas` over the Blob lane.
/// `plaintext_len` (known to the sender from its manifest) determines the chunk
/// count — `LiveObject` exposes reads but not its length.
pub async fn send_object(
    connection: &SyncConnection,
    cas: &CasStore,
    domain: ObjectDomain,
    object_id: ObjectId,
    plaintext_len: u64,
) -> Result<(), String> {
    let live = cas
        .get_live(domain, object_id)
        .map_err(|_| "cas_read_failed".to_string())?
        .ok_or_else(|| "cas_object_missing".to_string())?;
    let count = chunk_count_for(plaintext_len);
    let sender = connection.sender();
    for index in 0..count {
        let (_chunk_len, envelope) = live
            .read_encrypted_chunk(index)
            .map_err(|_| "cas_read_failed".to_string())?;
        sender
            .send(StreamLane::Blob, frame_chunk(object_id, index, &envelope))
            .await
            .map_err(|_| "blob_send_failed".to_string())?;
    }
    Ok(())
}

/// Receive `object_id`'s chunks from the Blob lane into `cas` and finish it.
/// `plaintext_len` (from the source manifest) sets the staged object length and
/// the expected chunk count. Non-Blob lane traffic is ignored; a chunk for a
/// different object is skipped.
pub async fn recv_object(
    connection: &mut SyncConnection,
    cas: &CasStore,
    domain: ObjectDomain,
    object_id: ObjectId,
    plaintext_len: u64,
) -> Result<(), String> {
    let expected = chunk_count_for(plaintext_len);
    let mut staging = cas
        .begin_stage(domain, object_id, plaintext_len)
        .map_err(|_| "cas_stage_failed".to_string())?;
    let mut received = 0u32;
    while received < expected {
        let payload = timeout(BLOB_TIMEOUT, connection.recv_lane(StreamLane::Blob))
            .await
            .map_err(|_| "blob_recv_timeout".to_string())?
            .ok_or_else(|| "blob_recv_closed".to_string())?;
        let (chunk_object, index, envelope) = parse_chunk(&payload)?;
        if chunk_object != object_id {
            continue;
        }
        staging
            .write_encrypted_chunk(index, &envelope)
            .map_err(|_| "cas_write_failed".to_string())?;
        received += 1;
    }
    staging.finish().map_err(|error| {
                    // Keep the reason: `finish` fails on a decrypt error, a
                    // chunk-length mismatch, an identity mismatch and several
                    // I/O faults, and collapsing them all to one code makes a
                    // real failure unactionable.
                    tracing::warn!(?error, "CAS finish failed");
                    "cas_finish_failed".to_string()
                })?;
    Ok(())
}
