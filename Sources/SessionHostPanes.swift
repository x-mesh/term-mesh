import Foundation
import PeerProto

/// Shows this machine's daemon-held sessions in this machine's own window.
///
/// A session the daemon owns outlives the app, which is the point of it — but
/// until something here attaches to one, the machine holding the work is the
/// one place you cannot see it. A project placed on a peer looked exactly like
/// that: the leader's own machine showed a workspace and no team.
///
/// Not a workspace mirror. The daemon places ensured sessions as *tabs* in one
/// pane, deliberately — "deterministic placement rather than requiring a
/// client-side picker" — and `PeerWorkspaceMirror` renders a pane's active
/// surface and has no notion of a tab strip, so mirroring showed one session
/// no matter how many were running. Attaching per surface sidesteps that
/// without changing where the daemon puts them or what the protocol carries.
@MainActor
enum SessionHostPanes {

    /// Sessions the daemon holds that have no pane here yet.
    ///
    /// "Held by the daemon" is the whole test. Anything it owns is a session
    /// that survives this app, which is exactly what deserves a window here;
    /// deciding by key or title would bind this to a naming scheme the app
    /// does not set and the host is free to change.
    ///
    /// Unattachable surfaces are skipped rather than attempted: attaching to
    /// one fails at the far end, and a failure per poll is a log full of the
    /// same line.
    static func sessionsNeedingPanes(
        daemonSurfaces: [(id: Data, attachable: Bool)],
        alreadyShown: Set<Data>
    ) -> [Data] {
        daemonSurfaces
            .filter { $0.attachable && !alreadyShown.contains($0.id) }
            .map(\.id)
    }

    /// Whether this machine has a session owner worth looking at.
    ///
    /// The empty path is a host saying it has none — see
    /// `Hello.session_host_socket`. Polling one would be asking a question
    /// that has already been answered.
    static func hasSessionHost(socketPath: String) -> Bool {
        socketPath.hasPrefix("/")
    }

    /// Surfaces already on screen, so a second pass adds nothing.
    ///
    /// Keyed by the *peer's* surface id rather than the local panel id: the
    /// local id is minted per attach, so comparing those would open a second
    /// pane for the same session every time this runs.
    private(set) static var shownSurfaceIDs: Set<Data> = []

    static func markShown(_ surfaceID: Data) {
        shownSurfaceIDs.insert(surfaceID)
    }

    static func markClosed(_ surfaceID: Data) {
        shownSurfaceIDs.remove(surfaceID)
    }

    /// Forget everything, for a daemon that went away and came back: its
    /// surface ids are derived from keys, so the same session can return with
    /// the same id and must be re-shown rather than considered already up.
    static func forgetAll() {
        shownSurfaceIDs.removeAll()
    }

    /// How long to keep looking for a session host that is still coming up.
    ///
    /// The app starts its daemon and its own peer server around the same
    /// moment, and the daemon binds its socket a little after being spawned.
    /// A single attempt at server-start therefore found nothing and returned
    /// silently — sessions that had outlived the app stayed invisible until
    /// something asked again, which nothing did. Restored panes from the
    /// previous run made that look like it had worked.
    static let startupSettleAttempts = 10
    static let startupSettleInterval: Duration = .milliseconds(500)
}

extension SessionHostPanes {

    /// Open a pane here for every daemon-held session that has none.
    ///
    /// Idempotent by surface id, so running it again after a session appears
    /// adds only that one. Failures are per-session: one surface that cannot
    /// be attached must not stop the rest, because the reason is usually that
    /// particular session and not the daemon.
    /// Reconcile once the session host is actually listening.
    ///
    /// Bounded rather than indefinite: a machine with no daemon serving is an
    /// ordinary state, not something to keep waiting on.
    @discardableResult
    static func reconcileWhenReady() async -> Int {
        for attempt in 0..<startupSettleAttempts {
            let path = TermMeshDaemon.shared.daemonPeerSocketPath
            guard hasSessionHost(socketPath: path) else { return 0 }
            if FileManager.default.fileExists(atPath: path) {
                return await reconcile()
            }
            if attempt + 1 < startupSettleAttempts {
                try? await Task.sleep(for: startupSettleInterval)
            }
        }
        // Gave up waiting. Distinguishable from "nothing to show", which is
        // what a silent zero made it indistinguishable from.
        RemoteWorkLog.info(
            "This machine's session daemon never started serving; "
                + "any sessions it holds are not shown here"
        )
        return 0
    }

    @discardableResult
    static func reconcile() async -> Int {
        let socketPath = TermMeshDaemon.shared.daemonPeerSocketPath
        guard hasSessionHost(socketPath: socketPath) else { return 0 }
        guard FileManager.default.fileExists(atPath: socketPath) else {
            // The daemon is not serving. Forget what was shown: its surface
            // ids come from keys, so the same session can return under the
            // same id and would otherwise be taken for one already up.
            forgetAll()
            return 0
        }

        let spec = PeerPaneHostSpec.direct(sockPath: socketPath)
        let registry = PeerPaneHostRegistry.shared
        let lease: PeerPaneHostLease
        do {
            lease = try await registry.acquire(spec)
        } catch {
            RemoteWorkLog.debug("session host unreachable at \(socketPath): \(error)")
            return 0
        }
        defer { registry.release(lease) }

        let surfaces: [Termmesh_Peer_V1_SurfaceInfo]
        do {
            surfaces = try await PeerPaneSession.listSurfaces(on: lease)
        } catch {
            RemoteWorkLog.debug("session host did not list its sessions: \(error)")
            return 0
        }

        let wanted = sessionsNeedingPanes(
            daemonSurfaces: surfaces.map { (id: $0.surfaceID, attachable: $0.attachable) },
            alreadyShown: shownSurfaceIDs
        )
        guard !wanted.isEmpty else {
            if !surfaces.isEmpty {
                RemoteWorkLog.debug(
                    "session host holds \(surfaces.count); all already shown here"
                )
            }
            return 0
        }

        var opened = 0
        for surfaceID in wanted {
            guard let info = surfaces.first(where: { $0.surfaceID == surfaceID }) else { continue }
            guard let workspace = AppDelegate.shared?.tabManager?.selectedWorkspace else {
                // At launch the peer server can be up before a window is, and
                // returning quietly here is how this looked like it had worked
                // while showing nothing. Say which half was missing.
                RemoteWorkLog.info(
                    "\(wanted.count) session(s) are waiting on this machine's daemon, "
                        + "but there is no workspace to show them in yet"
                )
                break
            }
            do {
                let session = try await PeerPaneSession.attach(
                    lease: lease,
                    surface: info,
                    title: info.title.isEmpty ? info.workspaceName : info.title,
                    spec: spec
                )
                // Never steal focus: this runs on its own schedule, not
                // because anyone asked for a pane right now.
                guard workspace.openRemotePane(session: session, focus: false) != nil else {
                    session.teardown()
                    continue
                }
                markShown(surfaceID)
                opened += 1
            } catch {
                RemoteWorkLog.debug(
                    "could not show session \(info.title.isEmpty ? "?" : info.title): \(error)"
                )
            }
        }
        if opened > 0 {
            RemoteWorkLog.info(
                "Showing \(opened) session\(opened == 1 ? "" : "s") this machine's daemon is holding"
            )
        }
        return opened
    }
}
