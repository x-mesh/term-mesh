import Bonsplit
import Foundation

/// Drives mesh-project-sync by shelling out to `tm-agent` — locally over the
/// daemon's unix socket, and on the peer over `ssh`.
///
/// Deliberately a process wrapper rather than a native RPC client. `tm-agent`
/// already speaks the daemon protocol and ships in the app bundle, and the git
/// checkpoint path next door drives `git`/`ssh` exactly this way, so this adds a
/// feature without adding a second protocol implementation to keep in step.
///
/// **Dev-grade trust.** Provisioning uses `sync bootstrap-trust`, which carries
/// the project recovery key and DEK in its descriptor. That is the recipe the
/// wiring plan's D3 sanctions for dev/e2e only; production (S4) drives the same
/// `apply_control_record` behind `pairing.approve` with user presence. Until
/// then this stays behind a dev surface.
enum SyncServiceError: LocalizedError {
    case invalidTarget
    case invalidPath(String)
    case toolMissing
    case commandFailed(String)
    case malformedResponse(String)
    case syncFailed(state: String, code: String)
    case pathBoundToAnotherProject(path: String, projectID: String)
    case unresolvedPeerAddress(String)
    case secretsUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            return "The peer's SSH target contains characters that are not allowed."
        case .invalidPath(let path):
            return "\(path) is not an absolute path."
        case .toolMissing:
            return "tm-agent was not found in this build."
        case .commandFailed(let message):
            return message
        case .malformedResponse(let raw):
            return "The daemon returned an unreadable response: \(raw)"
        case .syncFailed(let state, let code):
            return code.isEmpty ? "Sync \(state)." : "Sync \(state): \(code)"
        case .secretsUnavailable(let reason):
            return "Could not keep this project's sync keys (\(reason)). "
                + "Without them a re-provision cannot reuse the trust the peer already has."
        case .unresolvedPeerAddress(let host):
            return "\(host) did not resolve to an IPv4 address the peer can be dialled on."
        case .pathBoundToAnotherProject(let path, let projectID):
            return "\(path) is already mirrored as project \(String(projectID.prefix(12)))…. "
                + "Reset this mirror to adopt it, or pick a different folder."
        }
    }
}

struct SyncMirrorResult {
    let projectID: String
    /// Plan entries the run moved. The daemon counts fetched + pushed + deleted.
    let entries: UInt64
    let manifestRoot: String
}

actor SyncService {
    static let shared = SyncService()

    private let queue = DispatchQueue(label: "com.termmesh.sync-service", qos: .utility)

    /// Port the responder binds for incoming syncs. Fixed for now; a peer that
    /// needs a different one is a settings question, not a protocol one.
    private static let defaultBindPort = 47820

    // MARK: - Public surface

    /// Provision both daemons for `projectID` and run one sync.
    ///
    /// Idempotent enough to be a button: registering a project that is already
    /// registered, or provisioning trust that is already applied, is tolerated.
    /// The peer serves first (it does not dial), then this side dials it.
    func mirror(
        projectID: String,
        localPath: String,
        peerSSHTarget: String,
        peerAddress: String,
        remotePath: String,
        remoteToolPath: String,
        remoteSocketPath: String,
        peerID: String = "peer-b"
    ) async throws -> SyncMirrorResult {
        try await mirrorInternal(
            projectID: projectID, localPath: localPath, peerSSHTarget: peerSSHTarget,
            peerAddress: peerAddress, remotePath: remotePath, remoteToolPath: remoteToolPath,
            remoteSocketPath: remoteSocketPath, peerID: peerID, runSyncAfterwards: true
        )
    }

    private func mirrorInternal(
        projectID: String,
        localPath: String,
        peerSSHTarget: String,
        peerAddress: String,
        remotePath: String,
        remoteToolPath: String,
        remoteSocketPath: String,
        peerID: String,
        runSyncAfterwards: Bool
    ) async throws -> SyncMirrorResult {
        try Self.validateTarget(peerSSHTarget)
        try Self.validateAbsolutePath(localPath)
        try Self.validateAbsolutePath(remotePath)
        try Self.validateAbsolutePath(remoteToolPath)

        let remote = RemoteAgent(
            sshTarget: peerSSHTarget,
            toolPath: remoteToolPath,
            socketPath: remoteSocketPath
        )

        Self.log("mirror.begin project=\(projectID.prefix(12)) local=\(localPath) remote=\(remotePath) peer=\(peerSSHTarget)")
        // The daemon parses a peer address as a literal `SocketAddr`, so a
        // hostname has to become an IP before it gets there. Resolving here
        // rather than asking the user to type one keeps ssh aliases and MagicDNS
        // names usable, which is how peers are actually named.
        guard let dialable = Self.resolveIPv4(peerAddress) else {
            throw SyncServiceError.unresolvedPeerAddress(peerAddress)
        }
        Self.log("mirror.resolved \(peerAddress) -> \(dialable)")

        try await register(projectID: projectID, path: localPath, remote: nil)
        try await register(projectID: projectID, path: remotePath, remote: remote)

        // Identity phase: each daemon reports the certificate hash that binds it
        // in the roster. Neither side can build the roster alone — this is the
        // rendezvous the whole provisioning turns on.
        let localDevice = Self.deviceID(seed: 0x41)
        let peerDevice = Self.deviceID(seed: 0x42)
        Self.log("mirror.registered both roots")
        let localHash = try await certificateHash(projectID: projectID, device: localDevice, remote: nil)
        let peerHash = try await certificateHash(projectID: projectID, device: peerDevice, remote: remote)

        let roster: [[String: Any]] = [
            ["device_id": localDevice, "certificate_hash": localHash, "epoch": 1],
            ["device_id": peerDevice, "certificate_hash": peerHash, "epoch": 2],
        ]
        let secrets = try Self.secrets(for: projectID)

        // Peer first: it has no address book and never dials, so it can be
        // serving before this side exists.
        try await applyTrust(
            projectID: projectID, secrets: secrets, device: peerDevice, epoch: 2,
            roster: roster, peers: [], remote: remote
        )
        try await ensureServing(projectID: projectID, port: Self.defaultBindPort, remote: remote)

        try await applyTrust(
            projectID: projectID, secrets: secrets, device: localDevice, epoch: 1, roster: roster,
            peers: [["peer_id": peerID, "addr": "\(dialable):\(Self.defaultBindPort)"]],
            remote: nil
        )

        Self.log("mirror.provisioned project=\(projectID.prefix(12))")
        guard runSyncAfterwards else {
            return SyncMirrorResult(projectID: projectID, entries: 0, manifestRoot: "")
        }
        return try await runSync(projectID: projectID, peerID: peerID)
    }

    /// Provision both daemons WITHOUT syncing.
    ///
    /// Split out because provisioning is not idempotent: applying the same
    /// grants at the same roster epoch twice is refused, so a caller that
    /// re-provisions after any later failure locks itself out
    /// (`applying trust grants failed`) with no way back. The caller records
    /// the project as provisioned the moment this returns, and only ever calls
    /// `syncNow` afterwards.
    func provision(
        projectID: String,
        localPath: String,
        peerSSHTarget: String,
        peerAddress: String,
        remotePath: String,
        remoteToolPath: String,
        remoteSocketPath: String,
        peerID: String = "peer-b"
    ) async throws {
        _ = try await mirrorInternal(
            projectID: projectID, localPath: localPath, peerSSHTarget: peerSSHTarget,
            peerAddress: peerAddress, remotePath: remotePath, remoteToolPath: remoteToolPath,
            remoteSocketPath: remoteSocketPath, peerID: peerID, runSyncAfterwards: false
        )
    }

    /// The project id this daemon already has for `localPath`.
    ///
    /// The local registration is the anchor: a daemon refuses a second
    /// registration of the same root and offers no way to remove one, so once a
    /// folder is registered its id is permanent for that machine. Minting a
    /// fresh id for a folder that already has one is therefore never right — it
    /// fails at registration, or worse, provisions the two sides against
    /// different projects and surfaces much later as `ProjectNotFound`.
    /// Whether this project has already been provisioned from this machine.
    ///
    /// The secrets file is written during provisioning and only then, so its
    /// presence is the record that provisioning happened — including when the
    /// app's own bookkeeping was lost. Needed because provisioning cannot be
    /// repeated: a second attempt at the same roster epoch is refused outright.
    nonisolated static func isProvisioned(projectID: String) -> Bool {
        guard let url = secretsURL(projectID: projectID) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func localProjectID(for localPath: String) async -> String? {
        try? await registeredProjectID(path: localPath, remote: nil)
    }

    /// Run one sync against an already-provisioned project, making sure the
    /// peer is listening first.
    func syncNow(
        projectID: String,
        peerSSHTarget: String,
        remoteToolPath: String,
        remoteSocketPath: String,
        peerID: String = "peer-b"
    ) async throws -> SyncMirrorResult {
        try Self.validateTarget(peerSSHTarget)
        try await ensureServing(
            projectID: projectID,
            port: Self.defaultBindPort,
            remote: RemoteAgent(
                sshTarget: peerSSHTarget,
                toolPath: remoteToolPath,
                socketPath: remoteSocketPath
            )
        )
        return try await runSync(projectID: projectID, peerID: peerID)
    }

    // MARK: - Phases

    /// The project id a daemon already has registered for `path`, if any.
    ///
    /// Asked before registering rather than after failing, because a daemon
    /// rejects a second registration of the same root and the previous id is
    /// the one that matters — swallowing that rejection and carrying on with a
    /// fresh id leaves the two sides provisioning different projects, which
    /// only surfaces later as `ProjectNotFound` from `serve`.
    private func registeredProjectID(path: String, remote: RemoteAgent?) async throws -> String? {
        let raw = try await agent(["project", "list"], remote: remote)
        let projects = try Self.object(raw)["projects"] as? [[String: Any]] ?? []
        return projects.first { $0["root_path"] as? String == path }?["project_id"] as? String
    }

    private func register(projectID: String, path: String, remote: RemoteAgent?) async throws {
        if let existing = try await registeredProjectID(path: path, remote: remote) {
            guard existing == projectID else {
                throw SyncServiceError.pathBoundToAnotherProject(path: path, projectID: existing)
            }
            return
        }
        _ = try await agent(["project", "add", path, "--id", projectID], remote: remote)
    }

    private func certificateHash(projectID: String, device: String, remote: RemoteAgent?) async throws -> String {
        let raw = try await agent(
            ["sync", "bootstrap-identity", "--project", projectID, "--device", device],
            remote: remote
        )
        return try Self.string(raw, field: "certificate_hash")
    }

    private func applyTrust(
        projectID: String,
        secrets: ProjectSecrets,
        device: String,
        epoch: Int,
        roster: [[String: Any]],
        peers: [[String: Any]],
        remote: RemoteAgent?
    ) async throws {
        let descriptor: [String: Any] = [
            "project_id": projectID,
            "recovery": secrets.recovery,
            "dek_key_id": secrets.dekKeyID,
            "dek_key": secrets.dekKey,
            "device_id": device,
            "epoch": epoch,
            "roster": roster,
            "peers": peers,
        ]
        let json = try JSONSerialization.data(withJSONObject: descriptor, options: [.sortedKeys])
        _ = try await agent(
            ["sync", "bootstrap-trust", "--descriptor", "-"],
            remote: remote,
            stdin: json
        )
    }

    /// Bind the peer's listener, treating an already-bound port as success.
    ///
    /// Serving is per daemon PROCESS, not per provisioning: a peer that
    /// restarts comes back with its trust intact and no listener, and a sync
    /// against it then hangs waiting for a connection nobody accepts. So this
    /// runs before every sync, and a second bind reporting `AddrInUse` means
    /// the listener this needs is already there.
    private func ensureServing(projectID: String, port: Int, remote: RemoteAgent?) async throws {
        do {
            let raw = try await agent(
                ["sync", "serve", "--project", projectID, "--bind", "0.0.0.0:\(port)"],
                remote: remote
            )
            Self.log("serve.bound \((try? Self.string(raw, field: "bound_addr")) ?? "?")")
        } catch SyncServiceError.commandFailed(let message)
            where message.contains("AddrInUse") || message.contains("Address already in use") {
            Self.log("serve.already bound")
        }
    }

    private func runSync(projectID: String, peerID: String) async throws -> SyncMirrorResult {
        // `sync.start` wants a 16-byte hex request id; the CLI's generated id is
        // not hex, so supply one.
        let requestID = Self.randomHex(bytes: 16)
        let started = try await agent(
            ["sync", "start", projectID, "--peer", peerID, "--request-id", requestID],
            remote: nil
        )
        let operationID = try Self.string(started, field: "operation_id")

        // Poll to a terminal state. The operation is durable in the daemon, so a
        // slow run is a wait, not a failure — but an unbounded one hides a peer
        // that is never going to answer (a listener that died with its daemon),
        // so the wait is capped and says so.
        Self.log("sync.started operation=\(operationID.prefix(12))")
        for attempt in 0..<120 {
            if attempt > 0, attempt % 15 == 0 {
                Self.log("sync.waiting \(attempt)s operation=\(operationID.prefix(12))")
            }
            let status = try await agent(["sync", "status", projectID, operationID], remote: nil)
            let object = try Self.object(status)
            let state = object["state"] as? String ?? ""
            switch state {
            case "succeeded":
                Self.log("mirror.succeeded operation=\(operationID.prefix(12))")
                let result = object["result"] as? [String: Any]
                return SyncMirrorResult(
                    projectID: projectID,
                    entries: (result?["entries"] as? NSNumber)?.uint64Value ?? 0,
                    manifestRoot: result?["manifest_root"] as? String ?? ""
                )
            case "failed", "cancelled", "interrupted":
                Self.log("mirror.\(state) code=\(object["error_code"] as? String ?? "")")
                throw SyncServiceError.syncFailed(
                    state: state,
                    code: object["error_code"] as? String ?? ""
                )
            default:
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        Self.log("sync.timeout operation=\(operationID.prefix(12))")
        throw SyncServiceError.syncFailed(
            state: "timed out after 2 minutes",
            code: "the peer never answered — its listener may have died with its daemon"
        )
    }

    // MARK: - Process plumbing

    private struct RemoteAgent {
        let sshTarget: String
        let toolPath: String
        /// The peer daemon to drive. Explicit because `tm-agent` cannot
        /// auto-discover a socket over a non-login ssh shell, and because which
        /// daemon gets provisioned is a decision worth stating rather than
        /// inheriting from the environment.
        let socketPath: String
    }

    /// Run one `tm-agent` invocation and return its stdout.
    ///
    /// Local calls exec the bundled binary directly. Remote calls go through
    /// `ssh`, with every argument shell-quoted — the peer runs a login shell, so
    /// anything unquoted is a word-splitting or injection bug waiting to happen.
    private func agent(_ arguments: [String], remote: RemoteAgent?, stdin: Data? = nil) async throws -> String {
        guard let tool = Self.localToolPath() else { throw SyncServiceError.toolMissing }
        if let remote {
            let command = (["env", "TERMMESH_DAEMON_SOCKET=\(remote.socketPath)", remote.toolPath] + arguments)
                .map(Self.shellQuote)
                .joined(separator: " ")
            return try await run("/usr/bin/ssh", [remote.sshTarget, command], stdin: stdin)
        }
        return try await run(tool, arguments, stdin: stdin, environment: Self.localEnvironment())
    }

    private func run(
        _ executable: String,
        _ arguments: [String],
        stdin: Data? = nil,
        environment: [String: String]? = nil
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let process = Process()
                let out = Pipe()
                let err = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = out
                process.standardError = err
                if let environment { process.environment = environment }
                let input = Pipe()
                if stdin != nil { process.standardInput = input }
                do {
                    try process.run()
                    if let stdin {
                        input.fileHandleForWriting.write(stdin)
                        try? input.fileHandleForWriting.close()
                    }
                    // Drain before waiting: a pipe that fills would deadlock a
                    // process we are blocked on.
                    let output = out.fileHandleForReading.readDataToEndOfFile()
                    let errorOutput = err.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        let message = String(data: errorOutput, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(
                            throwing: SyncServiceError.commandFailed(
                                message.flatMap { $0.isEmpty ? nil : $0 } ?? "Command failed: \(executable)"
                            )
                        )
                        return
                    }
                    continuation.resume(returning: String(data: output, encoding: .utf8) ?? "")
                } catch {
                    continuation.resume(throwing: SyncServiceError.commandFailed(error.localizedDescription))
                }
            }
        }
    }

    /// Environment for a local `tm-agent`: point it at this app's daemon, and
    /// keep the sync keychain on disk.
    ///
    /// `MacOsKeychain` needs a code-signing entitlement this build does not
    /// carry, so a device identity cannot be created through it — provisioning
    /// fails with `SYNC_BOOTSTRAP_KEYCHAIN`. `FileKeychain` is selected by
    /// setting this directory, which is what the daemon does for dev/e2e. Real
    /// Keychain storage comes with the S4 pairing work.
    private static func localEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERMMESH_DAEMON_SOCKET"] = TermMeshDaemon.shared.socketPath
        if env["TERMMESH_SYNC_KEYCHAIN_DIR"] == nil {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            let dir = support?.appendingPathComponent("term-mesh/sync-keychain", isDirectory: true)
            if let dir {
                try? FileManager.default.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                env["TERMMESH_SYNC_KEYCHAIN_DIR"] = dir.path
            }
        }
        return env
    }

    private static func localToolPath() -> String? {
        let fm = FileManager.default
        if let resources = Bundle.main.resourcePath {
            let bundled = (resources as NSString).appendingPathComponent("bin/tm-agent")
            if fm.fileExists(atPath: bundled) { return bundled }
        }
        // Untagged development: the freshly built binary next to the sources.
        for config in ["release", "debug"] {
            let path = FileManager.default.currentDirectoryPath + "/daemon/target/\(config)/tm-agent"
            if fm.fileExists(atPath: path) { return path }
        }
        return nil
    }

    // MARK: - Helpers

    /// Per-project secrets: the recovery signing key that authorises device
    /// grants, and the DEK the CAS is encrypted with.
    ///
    /// Stable for the life of the project, not per call. A `TrustStore` is
    /// opened with the recovery PUBLIC key and verifies every later grant
    /// against it, so re-provisioning with a fresh recovery key fails outright
    /// (`applying trust grants failed`) — and a fresh DEK would orphan every
    /// object already in the peer's CAS. They are therefore generated once and
    /// reused.
    ///
    /// Kept in the login Keychain rather than `UserDefaults`, which is a
    /// world-readable plist. The daemon cannot reach the Keychain (it is
    /// unsigned for that entitlement), but the app can, which is why this side
    /// holds them.
    struct ProjectSecrets {
        let recovery: String
        let dekKeyID: String
        let dekKey: String

        static func generated() -> ProjectSecrets {
            ProjectSecrets(
                recovery: SyncService.randomHex(bytes: 32),
                dekKeyID: SyncService.randomHex(bytes: 16),
                dekKey: SyncService.randomHex(bytes: 32)
            )
        }
    }

    /// Where the app keeps its copy of the project secrets.
    ///
    /// A 0600 file rather than the Keychain. The Keychain path failed silently
    /// here — an unsigned build's `SecItemAdd` can be rejected, `loadSecrets`
    /// then returns nil, fresh secrets get generated, and provisioning dies at
    /// `applying trust grants failed` with nothing explaining why. A file makes
    /// the failure visible and matches where the daemon already keeps the same
    /// class of material (`FileKeychain`, same directory). Both are local,
    /// owner-only, dev-grade; neither belongs in a signed release, which is
    /// what the S4 pairing work replaces.
    private static func secretsURL(projectID: String) -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = support.appendingPathComponent("term-mesh/sync-keychain", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir.appendingPathComponent("project-\(projectID).json")
    }

    /// The project's secrets, generating and storing them on first use.
    private static func secrets(for projectID: String) throws -> ProjectSecrets {
        if let existing = loadSecrets(projectID: projectID) {
            log("secrets.loaded project=\(projectID.prefix(12))")
            return existing
        }
        let fresh = ProjectSecrets.generated()
        try storeSecrets(fresh, projectID: projectID)
        log("secrets.created project=\(projectID.prefix(12))")
        return fresh
    }

    private static func loadSecrets(projectID: String) -> ProjectSecrets? {
        guard let url = secretsURL(projectID: projectID),
              let data = try? Data(contentsOf: url),
              let parts = try? JSONDecoder().decode([String: String].self, from: data),
              let recovery = parts["recovery"],
              let dekKeyID = parts["dek_key_id"],
              let dekKey = parts["dek_key"] else { return nil }
        return ProjectSecrets(recovery: recovery, dekKeyID: dekKeyID, dekKey: dekKey)
    }

    /// Throws rather than shrugging: losing these silently is what turns a
    /// re-provision into an unexplainable trust failure.
    private static func storeSecrets(_ secrets: ProjectSecrets, projectID: String) throws {
        guard let url = secretsURL(projectID: projectID) else {
            throw SyncServiceError.secretsUnavailable("no application support directory")
        }
        let data = try JSONEncoder().encode([
            "recovery": secrets.recovery,
            "dek_key_id": secrets.dekKeyID,
            "dek_key": secrets.dekKey,
        ])
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw SyncServiceError.secretsUnavailable(error.localizedDescription)
        }
    }

    /// Forget a project's secrets, so the next provisioning starts clean.
    /// Only useful together with a daemon whose trust state was also cleared.
    static func forgetSecrets(projectID: String) {
        guard let url = secretsURL(projectID: projectID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func randomHex(bytes: Int) -> String {
        var raw = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &raw)
        return raw.map { String(format: "%02x", $0) }.joined()
    }

    /// A 32-byte device id. Deterministic per role so a re-provision of the same
    /// pair keeps the roster stable rather than accumulating identities.
    private static func deviceID(seed: UInt8) -> String {
        String(repeating: String(format: "%02x", seed), count: 32)
    }

    private static func object(_ raw: String) throws -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncServiceError.malformedResponse(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return object
    }

    private static func string(_ raw: String, field: String) throws -> String {
        guard let value = try object(raw)[field] as? String, !value.isEmpty else {
            throw SyncServiceError.malformedResponse(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return value
    }

    /// Mirror progress goes to the unified debug log, so a failure can be read
    /// after the fact instead of only in the row that showed it.
    /// Public so the store can record why a mirror ended.
    static func logFailure(_ message: String) { log(message) }

    private static func log(_ message: String) {
        #if DEBUG
        dlog("sync.\(message)")
        #endif
        // Also its own file. The shared debug log is a 500-entry ring that
        // layout tracing floods, so a mirror's few lines are gone from it long
        // before anyone reads them — and this is the log someone reaches for
        // when a mirror failed.
        appendToSyncLog(message)
    }

    /// Path of the sync-only log, tag-isolated like the daemon's own.
    static var logPath: String {
        let tag = ProcessInfo.processInfo.environment["TERMMESH_TAG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return tag.isEmpty ? "/tmp/term-mesh-sync.log" : "/tmp/term-mesh-sync-\(tag).log"
    }

    private static let logQueue = DispatchQueue(label: "com.termmesh.sync-log")

    private static func appendToSyncLog(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        logQueue.async {
            let line = "\(stamp) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let path = logPath
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }

    /// Resolve `host` to a dotted-quad address, passing an address through
    /// unchanged.
    ///
    /// IPv4 only, because the responder binds `0.0.0.0`. A peer reachable only
    /// over IPv6 needs that bind widened first, so failing here is honest
    /// rather than handing the daemon an address it cannot use.
    static func resolveIPv4(_ host: String) -> String? {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let first = info else { return nil }
        defer { freeaddrinfo(info) }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard let sockaddr = first.pointee.ai_addr else { return nil }
        var addr = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }

    private static func validateTarget(_ target: String) throws {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@[]:"
        )
        guard !target.isEmpty,
              target.unicodeScalars.allSatisfy(allowed.contains),
              !target.hasPrefix("-") else {
            throw SyncServiceError.invalidTarget
        }
    }

    private static func validateAbsolutePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else {
            throw SyncServiceError.invalidPath(path)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
