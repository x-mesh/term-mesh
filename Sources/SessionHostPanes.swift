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
    /// one fails at the far end, and a failure per pass is a log full of the
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

    /// Sessions already on screen, read from the panes themselves.
    ///
    /// This used to be a `Set` this type maintained, and every way that set
    /// could drift from the screen was a bug of its own. Closing an
    /// auto-opened pane left its id marked — nothing ever called the release —
    /// so that session could never come back. A momentarily unreachable daemon
    /// cleared the whole set while its panes were still up, so the next pass
    /// opened a second pane for every one of them.
    ///
    /// The panes are the answer to the question being asked. Reading them
    /// costs a walk of the window list and cannot disagree with what the user
    /// is looking at.
    ///
    /// Keyed by the *peer's* surface id, not the local panel id: the local one
    /// is minted per attach, so comparing those would open a duplicate pane
    /// every pass.
    static func shownSurfaceIDs() -> Set<Data> {
        guard let app = AppDelegate.shared else { return [] }
        var shown: Set<Data> = []
        for context in app.mainWindowContexts.values {
            for workspace in context.tabManager.tabs {
                for panel in workspace.panels.values {
                    guard let terminal = panel as? TerminalPanel,
                          let session = terminal.peerPaneSession,
                          !session.isTorndown
                    else { continue }
                    shown.insert(session.originSurface.surfaceID)
                }
            }
        }
        return shown
    }

    /// Sessions whose pane someone closed, which must stay closed.
    ///
    /// Reading "already shown" off the screen is what makes the pass
    /// idempotent, and it is also what makes a close undone fifteen seconds
    /// later: the daemon still holds the session, so the next pass finds it
    /// missing and opens it again. Measured, not predicted — a pane closed at
    /// 23:02:15 was back at 23:02:25.
    ///
    /// A dismissal is safe to remember where the old "shown" bookkeeping was
    /// not, because it has an owner: a close puts an id in, and nothing else
    /// needs to take it out. Deliberately not persisted — a fresh run should
    /// show what the daemon is holding, which is the whole point of this type.
    private static var dismissedSurfaceIDs: Set<Data> = []

    static func noteClosedByUser(surfaceID: Data) {
        guard !surfaceID.isEmpty else { return }
        dismissedSurfaceIDs.insert(surfaceID)
    }

    /// Drop dismissals for sessions the daemon no longer holds, so the set
    /// cannot grow for the life of the process.
    ///
    /// The gap this leaves: daemon surface ids are derived from the caller's
    /// key, so a session terminated and re-created under the same key returns
    /// with the same id. Re-created between two passes, it inherits the earlier
    /// dismissal and stays hidden until the app restarts. Pruning on absence
    /// closes that whenever a pass sees the gap, which is the common case.
    private static func pruneDismissals(stillHeld: Set<Data>) {
        dismissedSurfaceIDs.formIntersection(stillHeld)
    }

    /// Test seam: this state is process-global, so a test that adds to it must
    /// be able to put it back.
    static func forgetDismissalsForTests() {
        dismissedSurfaceIDs.removeAll()
    }

    static var dismissedSurfaceIDsForTests: Set<Data> { dismissedSurfaceIDs }

    static func pruneDismissalsForTests(stillHeld: Set<Data>) {
        pruneDismissals(stillHeld: stillHeld)
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

    /// What `reconcileWhenReady` will actually wait, which is one interval
    /// short of attempts × interval: the last attempt does not sleep after
    /// itself. Stated here so the test asserts the real number.
    static var startupSettleWindow: Duration {
        startupSettleInterval * (startupSettleAttempts - 1)
    }

    /// How often to look again while this machine is serving peers.
    ///
    /// Sessions appear after startup — that is what a session host is for, and
    /// every peer-placed project creates one minutes or hours in. A single
    /// pass at server-start showed whatever existed at launch and nothing
    /// after it, so the case this whole type exists for was the case it
    /// covered worst.
    ///
    /// Deliberately slow: a pass walks the window list and opens a connection
    /// to the daemon, and nothing about a session that has been running for a
    /// minute needs to be noticed in under one.
    static let pollInterval: Duration = .seconds(15)

    /// Only one pass at a time.
    ///
    /// A pass decides what is missing before it awaits its first attach, so two
    /// overlapping passes both see the same session as missing and both open a
    /// pane for it. Reading the shown set off live panes does not prevent this
    /// on its own — when both look, neither has opened anything yet.
    private static var reconcileInFlight = false

    private static var pollTask: Task<Void, Never>?
}

extension SessionHostPanes {

    /// Start looking, and keep looking while this machine serves peers.
    ///
    /// Idempotent: the peer server can be brought up more than once in a
    /// process, and a second poller would double every pass.
    static func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor in
            await reconcileWhenReady()
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled else { return }
                await reconcile()
            }
        }
    }

    /// Stop when the peer server does — a poller outliving the thing it serves
    /// would keep opening panes for a machine that is no longer a host.
    static func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Reconcile once the session host is listening *and* there is somewhere to
    /// put a pane.
    ///
    /// Waiting on the socket alone was not enough. At launch the peer server
    /// can be up before any window is, and the pass then found the sessions,
    /// had nowhere to show them, and gave up — with nothing scheduled to ask
    /// again. Both halves have to be there before the answer means anything.
    @discardableResult
    static func reconcileWhenReady() async -> Int {
        for attempt in 0..<startupSettleAttempts {
            let path = TermMeshDaemon.shared.daemonPeerSocketPath
            guard hasSessionHost(socketPath: path) else { return 0 }
            if TermMeshDaemon.isListening(atUnixSocketPath: path),
               AppDelegate.shared?.tabManager?.selectedWorkspace != nil {
                return await reconcile()
            }
            if attempt + 1 < startupSettleAttempts {
                try? await Task.sleep(for: startupSettleInterval)
            }
        }
        // Gave up on the fast path. Distinguishable from "nothing to show",
        // which is what a silent zero made it indistinguishable from. The
        // poller keeps asking after this, so it is a slow start and not a dead
        // end — say which.
        RemoteWorkLog.info(
            "This machine's session daemon is not serving yet, or there is no "
                + "window to show its sessions in; still checking"
        )
        return 0
    }

    /// Open a pane here for every daemon-held session that has none.
    ///
    /// Failures are per-session: one surface that cannot be attached must not
    /// stop the rest, because the reason is usually that particular session and
    /// not the daemon.
    @discardableResult
    static func reconcile() async -> Int {
        guard !reconcileInFlight else { return 0 }
        reconcileInFlight = true
        defer { reconcileInFlight = false }

        let socketPath = TermMeshDaemon.shared.daemonPeerSocketPath
        guard hasSessionHost(socketPath: socketPath) else { return 0 }
        // Nothing listening: the daemon is down or was never told to serve.
        // Leave the panes alone — they are the record of what is shown, and a
        // daemon that comes back reuses its surface ids, so a pane still up is
        // still that session.
        guard TermMeshDaemon.isListening(atUnixSocketPath: socketPath) else { return 0 }

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

        pruneDismissals(stillHeld: Set(surfaces.map(\.surfaceID)))
        let wanted = sessionsNeedingPanes(
            daemonSurfaces: surfaces.map { (id: $0.surfaceID, attachable: $0.attachable) },
            alreadyShown: shownSurfaceIDs().union(dismissedSurfaceIDs)
        )
        guard !wanted.isEmpty else { return 0 }

        var opened = 0
        for surfaceID in wanted {
            guard let info = surfaces.first(where: { $0.surfaceID == surfaceID }) else { continue }
            guard let workspace = AppDelegate.shared?.tabManager?.selectedWorkspace else {
                // No window yet. The poller comes back, so this is a wait
                // rather than the permanent give-up it used to be — but a
                // silent return here is how this looked like it had worked
                // while showing nothing, so name which half is missing.
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
