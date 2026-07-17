mod apply;
mod blob;
mod cas;
mod conflict;
mod crypto;
mod fetch;
mod gc;
mod git;
mod keychain;
mod manifest;
mod merge;
mod network_runner;
mod operation;
mod oplog;
mod path_sandbox;
mod plan;
mod project_lock;
mod reconcile;
mod registry;
mod rotation;
mod scanner;
mod schema;
mod secure_sqlite;
mod sqlite_openat_vfs;
mod stream_router;
mod sync_connection;
mod transfer;
mod transport;
mod transport_auth;
mod trust;
mod trust_bootstrap;
mod trust_recovery;

#[allow(unused_imports)]
pub use blob::{chunk_count_for, put_plaintext, recv_object, send_object};
#[allow(unused_imports)]
pub use apply::{
    ApplyAction, ApplyBoundary, ApplyCrashHook, ApplyError, ApplyIoPoint, ApplyPlan,
    ApplyPlanEntry, ApplyPrecondition, ApplyStore, VisibleState,
};
#[allow(unused_imports)]
pub use cas::{
    encrypt_chunk, encrypt_chunk_for_key, CasError, CasLimits, CasStore, EncryptedChunk, KeyId,
    LiveObject, ObjectDomain, ObjectId, ObjectIdHasher, ObjectType, ProjectKeyMaterial,
    ProjectKeyProvider, ResumeCheckpoint, ResumeToken, StageId, StagingObject, CHUNK_SIZE,
};
#[allow(unused_imports)]
pub use conflict::{
    ConflictContent, ConflictError, ConflictKind, ConflictPathOrigin, ConflictRecord,
    ConflictResolution, ConflictSet, ConflictSide, ResolutionPrecondition, ResolvedConflict,
    MAX_CONFLICT_CONTENT_BYTES, MAX_CONFLICT_COUNT, MAX_CONFLICT_PATH_BYTES,
    MAX_CONFLICT_TOTAL_BYTES,
};
#[allow(unused_imports)]
pub use crypto::ProjectKey;
#[allow(unused_imports)]
pub use gc::{
    CasGc, DeviceStatus, GcCoordinator, GcEngine, GcError, GcReport, GcSnapshot, GcSnapshotLease,
};
#[allow(unused_imports)]
pub use git::{
    GitAdvertisement, GitCrashHook, GitError, GitPhase, GitReplicationPlane, NoGitCrash,
};
#[cfg(target_os = "macos")]
#[allow(unused_imports)]
pub use keychain::MacOsKeychain;
#[allow(unused_imports)]
pub use keychain::{
    load_device_tls_identity, persist_device_tls_identity, DeviceTlsIdentity, KeychainBackend,
    KeychainError, KeychainItem, KeychainProtection, PeerIdentityProvider, PresenceAction,
    PresenceCapability, PresenceGrantContext, RandomSource, SystemRandom, UserPresenceAuthorizer,
};
#[allow(unused_imports)]
pub use manifest::{EntryKind, Manifest, ManifestBuilder, ManifestEntry, ManifestError};
#[allow(unused_imports)]
pub use merge::{
    detect_path_conflicts, merge_file, MergeOutcome, PathChange, ThreeWayFile,
    MAX_PATH_CHANGE_COUNT, MAX_PATH_CHANGE_TOTAL_BYTES,
};
#[allow(unused_imports)]
pub use operation::{
    default_operation_db_path, OperationError, OperationIdParams, OperationKind, OperationManager,
    OperationRecord, OperationResult, OperationRetryParams, OperationRunner, OperationSpec,
    OperationStartParams, OperationState, SyncTransport, MAX_OPERATION_ENVELOPE_BYTES,
};
#[allow(unused_imports)]
pub use oplog::{
    AppendOutcome, BatchIngestOutcome, DeviceFrontier, DurableAck, DurableBatchAck, OplogError,
    OplogStore, OplogTrustError, OplogTrustProvider, SequenceRange, SignedDeviceAck,
    TombstonePayload,
};
#[allow(unused_imports)]
pub use path_sandbox::{PathFingerprint, PathKind, PathSandboxError};
#[allow(unused_imports)]
pub use reconcile::{
    BaselineCrashHook, BaselineInstallPhase, CompletedManifestHandle, FrontierRelation,
    HeadDecision, IncrementalSyncReport, ManifestIndex, ReconcileError, ReconcileOrchestrator,
    ReconcileStore, SyncMode,
};
#[allow(unused_imports)]
pub use registry::{
    default_registry_db_path, HeldProjectRoot, ProjectId, ProjectRecord, ProjectRegistry,
    RegistryError, PROJECT_ID_BYTES,
};
#[allow(unused_imports)]
pub use rotation::{
    unwrap_project_key, wrap_project_key, ControlPublishEvidence, KeyPersistEvidence,
    PublishReceipt, RotationCoordinator, RotationError, RotationPlan, WrappedProjectKey,
};
#[cfg(test)]
#[allow(unused_imports)]
pub(crate) use rotation::{
    AckCounts, AckEvidence, CasMigrationCounts, CasMigrationEvidence, RotationOrchestrator,
};
#[allow(unused_imports)]
pub use scanner::{
    validate_path_names, ManifestScanner, ScanCheckpoint, ScanError, ScanLimits, ScanMetrics,
    ScanObserver, ScanReason,
};
#[allow(unused_imports)]
pub use stream_router::{RoutedFrame, RouterError, StreamLane, StreamRouter, StreamRouterSender};
#[allow(unused_imports)]
pub use network_runner::{
    exchange_manifests, scan_project_entries, scan_project_entries_cancellable, NetworkSyncRunner,
    PeerAddressResolver, SyncContext, SyncContextProvider,
};
#[allow(unused_imports)]
pub use fetch::{respond_to_fetch, run_fetch_pull};
#[allow(unused_imports)]
pub use plan::{
    build_apply_plan, decode_entries, decode_manifest_batch, diff_manifests, encode_entries,
    encode_manifest_batches, FetchEntry, ManifestDiff, ManifestWireError,
};
#[allow(unused_imports)]
pub use sync_connection::{SyncConnection, SyncConnectionError};
#[allow(unused_imports)]
pub use transfer::{
    logical_transfer_fixture, LogicalTransferReport, TransferCheckpoint, TransferError,
    TransferSession, WireTrace,
};
#[allow(unused_imports)]
pub use transport::{AuthenticatedConnection, SyncEndpoint, TransportError};
#[allow(unused_imports)]
pub use trust::{
    TransportPeerSnapshot, TrustError, TrustGcCoordinator, TrustRootProvider, TrustStore,
};
#[allow(unused_imports)]
pub use trust_bootstrap::{seed_trust_store, BootstrapDevice};
#[allow(unused_imports)]
pub use trust_recovery::{
    authorize_revoke, device_secret_item, export_recovery, import_recovery, project_dek_item,
    recovery_sentinel_item,
};
