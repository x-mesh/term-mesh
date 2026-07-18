//! Daemon-side sync **responder** — the accept half of the transport (piece 6).
//!
//! `NetworkSyncRunner` dials a peer (the initiator); this serves incoming
//! connections for one provisioned project. `SyncEndpoint::server` binds with a
//! single project's trust store + TLS identity, so a listener is per-project —
//! the mutual-pinned handshake authenticates the initiator against exactly that
//! project's roster. Multi-project serving on one endpoint needs a per-connection
//! certificate resolver and is deferred; a daemon serves each project on its own
//! listener.
//!
//! Each accepted connection mirrors the in-process e2e's hand-driven responder,
//! now against real provisioned stores: handshake → swap manifests from a fresh
//! scan of the tree → answer the initiator's fetch from the CAS. The DEK,
//! identity, trust, and CAS all come from what `bootstrap-trust` wrote.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use sync_protocol::{SyncHello, PROJECT_SYNC_CAPABILITY, PROTOCOL_V1};

use super::{
    exchange_manifests, receive_push, respond_to_fetch, scan_project_entries, HeldProjectRoot,
    KeyId, ObjectDomain, ObjectType, ProjectId, ProjectKey, SyncConnection, SyncContext,
    SyncEndpoint,
};

/// A fresh `SyncHello` (random nonce, so repeat connections are not replay-
/// rejected) advertising this daemon's coordinates for the project.
fn server_hello(context: &SyncContext) -> Option<SyncHello> {
    let mut nonce = [0u8; 32];
    getrandom::getrandom(&mut nonce).ok()?;
    Some(SyncHello {
        project_id: context.project_id,
        device_id: context.device_id,
        // The roster's CURRENT epoch — both peers must agree on the version, or
        // the mutual-pinned handshake rejects with a stale epoch.
        roster_epoch: context.roster_epoch,
        selected_version: PROTOCOL_V1,
        version_offers: vec![PROTOCOL_V1],
        capabilities: vec![PROJECT_SYNC_CAPABILITY.into()],
        nonce,
    })
}

/// Serve incoming sync connections for one provisioned project until `stop` is
/// set (checked between connections; a daemon shutdown drops the task). Serves
/// connections one at a time — enough for the v0 explicit-endpoint bootstrap;
/// per-connection concurrency is a later optimization.
pub async fn serve_project(
    endpoint: SyncEndpoint,
    context: Arc<SyncContext>,
    root: HeldProjectRoot,
    dek_key: ProjectKey,
    dek_key_id: KeyId,
    stop: Arc<AtomicBool>,
) {
    let domain = ObjectDomain {
        project_id: ProjectId::from_bytes(context.project_id),
        object_type: ObjectType::FILE,
        version: 1,
    };
    while !stop.load(Ordering::Acquire) {
        let Some(hello) = server_hello(&context) else {
            break;
        };
        match endpoint.accept(hello).await {
            Ok(auth) => {
                serve_connection(auth, &context, &root, domain, &dek_key, dek_key_id).await;
            }
            Err(_) => {
                // A transient accept/handshake failure (e.g. an unauthorized dial)
                // must not spin the loop or take the listener down; pause briefly
                // and keep serving unless we are stopping.
                if stop.load(Ordering::Acquire) {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
    }
}

/// Serve one accepted connection: swap manifests from a fresh scan, then answer
/// the initiator's fetch from the CAS. The tree is re-scanned per connection so a
/// change between connections is reflected.
async fn serve_connection(
    auth: super::AuthenticatedConnection,
    context: &SyncContext,
    root: &HeldProjectRoot,
    domain: ObjectDomain,
    dek_key: &ProjectKey,
    dek_key_id: KeyId,
) {
    let mut connection = SyncConnection::start(auth);
    let entries = match scan_project_entries(root.descriptor()) {
        Ok(entries) => entries,
        Err(_) => return,
    };
    if exchange_manifests(&mut connection, &entries).await.is_err() {
        return;
    }
    // Fetch phase: serve what the initiator pulls.
    let _ = respond_to_fetch(
        &mut connection,
        context.cas.as_ref(),
        root.canonical_path(),
        domain,
        dek_key,
        dek_key_id,
        &entries,
    )
    .await;
    // Push phase: apply what the initiator pushes (it has already reconciled, so
    // the responder trusts the push and applies onto its current tree).
    let _ = receive_push(
        &mut connection,
        context.cas.as_ref(),
        root.canonical_path(),
        domain,
        context.apply_store.as_ref(),
        ProjectId::from_bytes(context.project_id),
        &entries,
    )
    .await;
    // Hold the connection open until the initiator has drained the response and
    // hung up — dropping it early would reset the still-in-flight streams before
    // they flush, so the initiator would see `fetch_closed`.
    while connection.recv().await.is_some() {}
}
