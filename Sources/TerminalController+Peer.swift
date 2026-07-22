import Foundation

/// Socket surface for peer-federation saved hosts.
///
/// `RemoteHostStore` was reachable only from SwiftUI, so every host action —
/// connect, disconnect, force disconnect, retry — could only be driven by a
/// human clicking the sidebar. That put the whole peer feature outside the
/// `tests_v2` socket-e2e harness and made regressions there un-testable.
///
/// Threading: the store is `@MainActor`, the socket handler is not (each client
/// gets its own thread, see `TerminalController+Process.swift:466`). Read-only
/// snapshots hop with `v2MainExec` so a wedged main thread times out instead of
/// deadlocking the client. `connect` and `retry` perform network I/O, so they
/// are fire-and-forget and their outcome is observed by polling `peer.host.list`
/// — the same contract the `debug.peer.*` commands use with `last_open_result`.
///
/// Per the socket focus policy these commands never activate the app or move
/// in-app focus; none of them belong in `focusIntentV2Methods`.
extension TerminalController {

    /// Resolve a `--host` argument against the store. Accepts the stable key
    /// (`HostEntry.id`, e.g. `ssh:root@jw-server`) or the display name, since
    /// the key is an implementation detail a caller shouldn't have to know.
    /// Display-name matching is case-insensitive and rejects ambiguity rather
    /// than picking one, so a typo can never silently act on the wrong host.
    @MainActor
    private func peerResolveHost(_ handle: String) -> Result<HostEntry, String> {
        let hosts = RemoteHostStore.shared.sortedHosts
        if let exact = hosts.first(where: { $0.id == handle }) {
            return .success(exact)
        }
        let byName = hosts.filter {
            $0.displayName.caseInsensitiveCompare(handle) == .orderedSame
        }
        if byName.count == 1 { return .success(byName[0]) }
        if byName.count > 1 {
            return .failure("\(handle) matches \(byName.count) hosts — use the id instead")
        }
        return .failure("no such peer host: \(handle)")
    }

    private static func peerStateString(_ state: HostConnectionState) -> String {
        switch state {
        case .saved: return "saved"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .failed: return "failed"
        }
    }

    @MainActor
    private func peerHostDict(_ host: HostEntry) -> [String: Any] {
        var dict: [String: Any] = [
            "id": host.id,
            "display_name": host.displayName,
            "state": Self.peerStateString(host.connectionState),
            // The sidebar hides Disconnect without a lease while a live pane
            // keeps the row `.connected`; surfacing the flag lets a test assert
            // that combination directly instead of inferring it.
            "has_sidebar_lease": RemoteHostStore.shared.hasSidebarLease(for: host.id),
            "workspace_count": host.workspaces.count,
        ]
        if case .failed(let reason) = host.connectionState {
            dict["failure_reason"] = reason
        }
        if let ssh = host.sshTarget, !ssh.isEmpty { dict["ssh_target"] = ssh }
        if let remote = host.remoteSockPath, !remote.isEmpty { dict["remote_sock_path"] = remote }
        if !host.activeSockPath.isEmpty { dict["active_sock_path"] = host.activeSockPath }
        return dict
    }

    /// Snapshot of every saved/known peer host and its connection state.
    func v2PeerHostList(params _: [String: Any]) -> V2CallResult {
        var hosts: [[String: Any]] = []
        let ok = v2MainExec(timeout: 5) {
            MainActor.assumeIsolated {
                hosts = RemoteHostStore.shared.sortedHosts.map { self.peerHostDict($0) }
            }
        }
        guard ok else {
            return .err(code: "internal_error", message: "peer host list timed out", data: nil)
        }
        return .ok(["ok": true, "hosts": hosts])
    }

    /// Start connecting a saved host. Returns as soon as the attempt is
    /// scheduled; poll `peer.host.list` for the resulting state. A host that is
    /// already connected or connecting is reported back rather than re-driven,
    /// so a retrying caller cannot stack duplicate attempts.
    func v2PeerHostConnect(params: [String: Any]) -> V2CallResult {
        peerDispatchHostAction(params: params, action: "connect") { store, host in
            switch host.connectionState {
            case .connected:
                return ["ok": true, "started": false, "state": "connected"]
            case .connecting:
                return ["ok": true, "started": false, "state": "connecting"]
            case .saved, .failed:
                store.connectSavedHost(host)
                return ["ok": true, "started": true, "state": "connecting"]
            }
        }
    }

    /// Abandon the in-flight attempt and start a fresh one. Valid from any
    /// state — this is the escape hatch for a row wedged in `.connecting`,
    /// which is exactly when the caller cannot know the state is still valid.
    func v2PeerHostRetry(params: [String: Any]) -> V2CallResult {
        peerDispatchHostAction(params: params, action: "retry") { store, host in
            store.retryConnectingHost(host)
            return ["ok": true, "started": true, "state": "connecting"]
        }
    }

    /// Cancel an in-progress connect, returning the row to `.saved`.
    func v2PeerHostCancel(params: [String: Any]) -> V2CallResult {
        peerDispatchHostAction(params: params, action: "cancel") { store, host in
            guard case .connecting = host.connectionState else {
                return [
                    "ok": true,
                    "cancelled": false,
                    "state": Self.peerStateString(host.connectionState),
                ]
            }
            store.cancelConnectingHost(host)
            return ["ok": true, "cancelled": true, "state": "saved"]
        }
    }

    /// Release the sidebar's lease. Panes and mirrors opened from this host
    /// hold their own refs and deliberately stay open, so the row can end up
    /// back at `.connected` — the response reports the state after the fact
    /// rather than assuming.
    func v2PeerHostDisconnect(params: [String: Any]) -> V2CallResult {
        peerDispatchHostAction(params: params, action: "disconnect") { store, host in
            store.disconnectSavedHost(host)
            let after = store.sortedHosts.first { $0.id == host.id }
            return [
                "ok": true,
                "state": after.map { Self.peerStateString($0.connectionState) } ?? "saved",
                "has_sidebar_lease": store.hasSidebarLease(for: host.id),
            ]
        }
    }

    /// Close every pane, mirror and relay window opened from this host, then
    /// release the sidebar lease. `closed` counts the connections that were
    /// asked to close, which is what a test asserts against.
    func v2PeerHostForceDisconnect(params: [String: Any]) -> V2CallResult {
        peerDispatchHostAction(params: params, action: "force_disconnect") { store, host in
            // The store reports the rows it closed. Diffing activeConnections()
            // around the call would be wrong twice over: window closes land
            // asynchronously, and the count includes other hosts.
            let closed = store.forceDisconnectSavedHost(host)
            let row = store.sortedHosts.first { $0.id == host.id }
            return [
                "ok": true,
                "closed": closed,
                "state": row.map { Self.peerStateString($0.connectionState) } ?? "saved",
                "has_sidebar_lease": store.hasSidebarLease(for: host.id),
            ]
        }
    }

    /// Open one of the host's remote surfaces as a pane in the current
    /// workspace — the sidebar's "Open Surface as Pane…" without the picker.
    /// Fire-and-forget: the attach is a network round trip, so the outcome is
    /// polled via `peer.pane.status`.
    func v2PeerSurfaceOpenPane(params: [String: Any]) -> V2CallResult {
        peerDispatchHostAction(params: params, action: "open_pane") { _, host in
            PeerClientCoordinator.shared.openRemotePaneHeadless(spec: host.paneHostSpec)
            return ["ok": true, "started": true]
        }
    }

    /// Open one of the host's workspaces as a live mirror in the main window.
    ///
    /// A live mirror changes the rules for everything else in that workspace —
    /// `Workspace.mirrorForwardsLocalActions` routes local closes to the host
    /// and the reconciler owns the layout — so a peer bug that only appears
    /// alongside a mirror is unreachable without this. `workspace` selects by
    /// title; omitted, the host's first workspace is used.
    func v2PeerWorkspaceOpenMirror(params: [String: Any]) -> V2CallResult {
        let wanted = v2String(params, "workspace")
        let live = (params["live"] as? Bool) ?? true
        return peerDispatchHostAction(params: params, action: "open_mirror") { store, host in
            guard !host.workspaces.isEmpty else {
                return ["ok": false, "error": "host has no workspaces"]
            }
            let chosen: WorkspaceSummary?
            if let wanted {
                chosen = host.workspaces.first {
                    $0.title.caseInsensitiveCompare(wanted) == .orderedSame
                }
            } else {
                chosen = host.workspaces.first
            }
            guard let workspace = chosen else {
                return ["ok": false, "error": "no such workspace: \(wanted ?? "")"]
            }
            store.openWorkspaceAsMirror(workspace, host: host, live: live)
            return ["ok": true, "started": true, "workspace": workspace.title, "live": live]
        }
    }

    /// Live-mirror state (subscription health, leaf count, shape hash) — the
    /// poll counterpart to `peer.workspace.open_mirror`.
    func v2PeerMirrorStatus(params _: [String: Any]) -> V2CallResult {
        var status: [String: Any] = [:]
        let ok = v2MainExec(timeout: 5) {
            MainActor.assumeIsolated {
                status = PeerClientCoordinator.shared.debugMirrorStatus()
            }
        }
        guard ok else {
            return .err(code: "internal_error", message: "peer mirror status timed out", data: nil)
        }
        return .ok(["ok": true, "status": status])
    }

    /// Remote-pane sessions and host-lease count. The counterpart poll for
    /// `peer.surface.open_pane`, and what a test asserts against to confirm a
    /// force disconnect actually tore every pane down.
    func v2PeerPaneStatus(params _: [String: Any]) -> V2CallResult {
        var status: [String: Any] = [:]
        let ok = v2MainExec(timeout: 5) {
            MainActor.assumeIsolated {
                status = PeerClientCoordinator.shared.debugPaneStatus()
            }
        }
        guard ok else {
            return .err(code: "internal_error", message: "peer pane status timed out", data: nil)
        }
        return .ok(["ok": true, "status": status])
    }

    /// Shared plumbing: resolve `host`, hop to main, run `body`, return its
    /// dictionary. `body` runs on the MainActor with the store already in hand.
    private func peerDispatchHostAction(
        params: [String: Any],
        action: String,
        _ body: @escaping @MainActor (RemoteHostStore, HostEntry) -> [String: Any]
    ) -> V2CallResult {
        guard let handle = v2String(params, "host") else {
            return .err(code: "invalid_params", message: "host is required", data: nil)
        }
        var result: [String: Any] = [:]
        var failure: String?
        // Generous but bounded: these mutate UI state on main, and a wedged
        // main thread must surface as a timeout rather than hang the client.
        let ok = v2MainExec(timeout: 10) {
            MainActor.assumeIsolated {
                let store = RemoteHostStore.shared
                switch self.peerResolveHost(handle) {
                case .failure(let message):
                    failure = message
                case .success(let host):
                    result = body(store, host)
                }
            }
        }
        guard ok else {
            return .err(
                code: "internal_error", message: "peer \(action) timed out", data: nil
            )
        }
        if let failure {
            return .err(code: "not_found", message: failure, data: nil)
        }
        return .ok(result)
    }
}
