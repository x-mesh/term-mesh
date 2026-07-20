//  PeerHostEditorView: add/edit sheet for saved remote-host profiles
//  (sidebar-first peer UX, Phase 3). Mounted from the sidebar's Remote
//  Hosts section via .sheet(item:). SwiftUI by design — the legacy
//  NSAlert connect dialogs stay untouched until Phase 4 retires them.

import AppKit
import Bonsplit
import SwiftUI

/// Sheet payload: one type for both "add" and "edit" so `.sheet(item:)`
/// gets a stable identity either way.
struct PeerHostEditorContext: Identifiable {
    var profile: PeerHostProfile
    let isNew: Bool
    var id: UUID { profile.id }
}

struct PeerHostEditorView: View {
    @State private var profile: PeerHostProfile
    private let isNew: Bool
    private let onSave: (PeerHostProfile) -> Void
    private let onCancel: () -> Void

    /// Text mirror of the optional Int port (empty = nil).
    @State private var portText: String
    @State private var validationError: String?
    @State private var discovered: [DiscoveredPeer] = []
    /// Held for the sheet's lifetime; started/stopped with appearance.
    @State private var bonjourBrowser = PeerBonjourBrowser()

    /// Test / install flow state (the sheet's "doctor").
    ///
    /// Existing case signatures are a frozen interface contract — do not
    /// change them. The version-check states below are additive only.
    enum DoctorState: Equatable {
        case idle
        case testing
        case ok(String)              // live socket path
        case daemonMissing           // SSH fine, no term-meshd → offer install
        case sshFailed(String)
        case installing
        case installFailed(String)
        case diagnosing              // installed but still no socket
        case diagnosed(String)       // compact failure reason
        /// Connected, version known, and at/above the latest release.
        case okUpToDate(socket: String, version: String)
        /// Connected, version known, and behind the latest release.
        case updateAvailable(socket: String, remote: String, latest: String)
        /// Connected, but the installed version predates
        /// `PeerDaemonVersion.versionSyncFloor` — comparing it against
        /// `latest` would misreport, so this is a recommendation, not a
        /// version-ordering claim (see PeerDaemonVersion.Comparison.legacy).
        case legacyDaemon(socket: String, remote: String)
        /// Connected, but the remote version couldn't be determined
        /// (probe failed, or the latest-release lookup failed) — never
        /// blocks a successful Test result on its own.
        case okVersionUnknown(socket: String)
    }
    @State private var doctorState: DoctorState = .idle
    @State private var showInstallConfirm = false
    @State private var showUpdateConfirm = false
    /// Suppresses the Update button after one SUCCESSFUL update attempt
    /// this sheet session, even if the post-update retest still reports
    /// outdated/legacy — avoids nagging the user in a retry loop. Reset
    /// on a FAILED install (see `runInstall()`'s catch block) since a
    /// failure isn't the "still outdated after a real update" case this
    /// exists to suppress — the user should be able to just retry.
    @State private var updateAttempted = false
    /// Version reported by a binary found on the host while term-meshd
    /// itself isn't running (`.daemonMissing`). Kept out of that case's
    /// associated value since its signature must not change.
    @State private var daemonMissingVersion: String?
    /// `PeerHostKind` paired with `daemonMissingVersion` — same
    /// "kept out of the frozen case's associated value" reasoning.
    @State private var daemonMissingHostKind: PeerHostKind?
    /// Which kind of host the LAST successful version probe found —
    /// Linux term-meshd or a Mac term-mesh.app. Kept as its own @State
    /// rather than widening `.okUpToDate`/`.updateAvailable`/
    /// `.legacyDaemon`'s associated values, per the same
    /// frozen-signature discipline as `daemonMissingVersion`; every
    /// switch over `doctorState` stays untouched by this addition.
    /// Reset alongside the rest of the doctor state in
    /// `invalidateDoctorState()`.
    @State private var testedHostKind: PeerHostKind?
    /// The exact (sshTarget, port, identityFile) — as a validated
    /// `PeerHostProfile` — that the last `runTest()` actually probed.
    /// `runInstall()` reads ONLY this, never a fresh `validatedDraft()`,
    /// so Install/Update always targets what was tested even if the form
    /// fields changed afterward. Cleared by `invalidateDoctorState()`;
    /// the Install/Update buttons also require it to be non-nil (see
    /// `showsUpdateButton`) as a second line of defense.
    @State private var testedDraft: PeerHostProfile?
    /// Bumped by `invalidateDoctorState()` and at the start of every
    /// `runTest()`. Each `runTest()`/`runInstall()` Task captures the
    /// value at launch and re-checks it after every `await` before
    /// touching `doctorState`/`testedDraft`/`daemonMissingVersion` — a
    /// mismatch means a newer Test or a field edit superseded this Task
    /// while it was suspended, so its result is discarded rather than
    /// written. This, not the resets in `invalidateDoctorState()`, is
    /// what actually stops a late-arriving response from clobbering a
    /// fresher state (SwiftUI state writes alone can't prevent an
    /// already-in-flight Task from waking up later and writing anyway).
    @State private var doctorGeneration = 0
    /// True for exactly as long as the remote install/update SSH script
    /// is actually running — from `runInstall()`'s launch of
    /// `PeerHostDoctor.install` until that call returns, success or
    /// failure. A different layer from `doctorGeneration`: the generation
    /// guard discards a STALE RESULT, but does nothing about a SIDE
    /// EFFECT already under way on the remote host. Without this latch,
    /// `invalidateDoctorState()` resetting `doctorState` to `.idle`
    /// mid-install would re-enable the buttons and let the user kick off
    /// a second concurrent install script against the same host.
    /// `doctorBusy` ORs this in so Test/Install/Update stay locked until
    /// the remote script actually exits — deliberately not cancelled
    /// (the script can't be cancelled once started; refusing new actions
    /// until it finishes is the only honest guard). `invalidateDoctorState()`
    /// intentionally does NOT touch this flag: a field edit still resets
    /// the visible doctor state, but the buttons stay locked until the
    /// in-flight install/update completes.
    @State private var installInFlight = false

    /// Agent-notification stack (scripts + Claude hooks) on the host —
    /// a second doctor lane beside the daemon one, so "connected" and
    /// "notifications will actually work" are answered separately.
    /// Additive: DoctorState's frozen cases stay untouched.
    enum AgentStackState: Equatable {
        case idle
        case checking
        /// Probe answered — status says what is and isn't there.
        case status(PeerAgentStackStatus)
        case installing
        case installFailed(String)
        /// Install finished; the message is the doctor's summary line.
        case installed(String)
    }
    @State private var agentStackState: AgentStackState = .idle
    @State private var showAgentInstallConfirm = false
    /// Same latch discipline as `installInFlight`, same reason: the
    /// generation guard discards stale results, but only this keeps the
    /// buttons locked while a remote install is genuinely under way.
    @State private var agentInstallInFlight = false

    /// Fixed tag palette (one-dark hues) + nil for "no color".
    private static let colorChoices: [String?] = [
        nil, "#E06C75", "#D19A66", "#E5C07B",
        "#98C379", "#56B6C2", "#61AFEF", "#C678DD",
    ]
    /// Small curated symbol set; nil = default "network".
    private static let symbolChoices: [String?] = [
        nil, "server.rack", "desktopcomputer", "laptopcomputer",
        "cpu", "cloud", "shippingbox",
    ]

    init(context: PeerHostEditorContext,
         onSave: @escaping (PeerHostProfile) -> Void,
         onCancel: @escaping () -> Void) {
        _profile = State(initialValue: context.profile)
        self.isNew = context.isNew
        self.onSave = onSave
        self.onCancel = onCancel
        _portText = State(initialValue: context.profile.sshPort.map(String.init) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Add Peer Host" : "Edit Peer Host")
                .font(.headline)

            if !discovered.isEmpty {
                discoveredChips
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Name")
                    TextField(profile.sshTarget.isEmpty ? "display name" : profile.sshTarget,
                              text: $profile.displayName)
                }
                GridRow {
                    Text("SSH Target")
                    TextField("user@host or ssh-config alias", text: $profile.sshTarget)
                }
                GridRow {
                    Text("Port")
                    TextField("22 — or set in ~/.ssh/config", text: $portText)
                }
                GridRow {
                    Text("Identity File")
                    TextField("~/.ssh/id_ed25519 — or ssh-config", text: optionalBinding(\.identityFile))
                }
                GridRow {
                    Text("Remote Socket")
                    TextField("leave empty to auto-detect", text: $profile.remoteSocket)
                }
                GridRow {
                    Text("Color")
                    colorSwatches
                }
                GridRow {
                    Text("Icon")
                    symbolPicker
                }
            }
            .font(.system(size: 12))

            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            doctorStatusLine

            agentStackStatusLine

            HStack {
                Button("Test", action: runTest)
                    .disabled(doctorBusy
                              || profile.sshTarget.trimmingCharacters(in: .whitespaces).isEmpty)
                if case .daemonMissing = doctorState, testedDraft != nil {
                    Button("Install term-meshd…") { showInstallConfirm = true }
                        .disabled(doctorBusy)
                }
                if showsUpdateButton {
                    Button("Update term-meshd…") { showUpdateConfirm = true }
                        .disabled(doctorBusy)
                }
                if showsAgentInstallButton {
                    Button("Set up notifications…") { showAgentInstallConfirm = true }
                        .disabled(doctorBusy)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save", action: validateAndSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(profile.sshTarget.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            bonjourBrowser.start { peers in
                discovered = peers
            }
        }
        .onDisappear { bonjourBrowser.stop() }
        // A stale doctorState/testedDraft is worse than none: any edit to
        // a field the doctor actually probes invalidates the last Test so
        // Install/Update can never fire against a since-changed target.
        .onChange(of: profile.sshTarget) { invalidateDoctorState() }
        .onChange(of: portText) { invalidateDoctorState() }
        .onChange(of: profile.identityFile) { invalidateDoctorState() }
        .confirmationDialog(
            "Install term-meshd on \"\(profile.sshTarget)\"?",
            isPresented: $showInstallConfirm
        ) {
            Button("Install") { runInstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runs the official install script over SSH: downloads the latest release binary and registers a systemd user service.")
        }
        .confirmationDialog(
            "Update term-meshd on \"\(profile.sshTarget)\"?",
            isPresented: $showUpdateConfirm
        ) {
            Button("Update") {
                updateAttempted = true
                runInstall()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Updating restarts the remote daemon and terminates all sessions on this host.")
        }
        .confirmationDialog(
            "Set up agent notifications on \"\(profile.sshTarget)\"?",
            isPresented: $showAgentInstallConfirm
        ) {
            Button("Set Up") { runAgentStackInstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Copies agent-notify.sh and agent-title.sh to ~/.local/bin and, when Claude Code is installed there, wires its Notification and Stop hooks (existing settings are backed up).")
        }
    }

    private var doctorBusy: Bool {
        // installInFlight can outlive `.installing` in doctorState (e.g.
        // right after invalidateDoctorState() resets state mid-install)
        // so it's checked independently, not folded into the switch.
        if installInFlight || agentInstallInFlight { return true }
        switch doctorState {
        case .testing, .installing, .diagnosing: return true
        default: return false
        }
    }

    /// Offered when the last probe answered and found something missing;
    /// requires the tested target for the same reason Install/Update do.
    private var showsAgentInstallButton: Bool {
        guard testedDraft != nil else { return false }
        switch agentStackState {
        case .status(let status): return !status.isComplete
        case .installFailed: return true
        default: return false
        }
    }

    /// Shown for `.updateAvailable`/`.legacyDaemon`, suppressed after one
    /// update attempt this session (see `updateAttempted`), and only
    /// when there's an actual tested target to act on (`testedDraft`) —
    /// belt-and-suspenders alongside the generation guard in `runInstall`.
    /// Also suppressed for a Mac host (`testedHostKind == .app`):
    /// `PeerHostDoctor.install` only knows how to run the Linux install
    /// script, which is a guaranteed failure over SSH to a Mac (its
    /// `uname` guard dies immediately) — the doctor status line's
    /// `doctorMessageWithMacHint` covers that case with manual-update
    /// copy instead of a button that can't work (1st-scope decision;
    /// remote-automated Mac update is a later candidate).
    private var showsUpdateButton: Bool {
        guard !updateAttempted, testedDraft != nil, testedHostKind != .app else { return false }
        switch doctorState {
        case .updateAvailable, .legacyDaemon: return true
        default: return false
        }
    }

    @ViewBuilder
    private var doctorStatusLine: some View {
        switch doctorState {
        case .idle:
            EmptyView()
        case .testing:
            Label("Testing connection…", systemImage: "ellipsis.circle")
                .font(.caption).foregroundColor(.secondary)
        case .ok(let path):
            Label("Connected — daemon socket: \(path)", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundColor(.green)
        case .daemonMissing:
            Label(daemonMissingStatusText,
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundColor(.orange)
        case .okUpToDate(_, let version):
            Label("\(serverLabel) v\(displayVersion(version)) — up to date", systemImage: "checkmark.seal")
                .font(.caption).foregroundColor(.green)
        case .updateAvailable(_, let remote, let latest):
            doctorMessageWithMacHint(
                "Update available: \(serverLabel) v\(displayVersion(remote)) → v\(displayVersion(latest))",
                systemImage: "arrow.up.circle"
            )
        case .legacyDaemon(_, let remote):
            doctorMessageWithMacHint(
                "Legacy \(serverLabel) (v\(displayVersion(remote))) — update recommended (version reporting predates v\(displayVersion(PeerDaemonVersion.versionSyncFloor)))",
                systemImage: "exclamationmark.arrow.circlepath"
            )
        case .okVersionUnknown(let path):
            Label("Connected — daemon socket: \(path) — version unknown",
                  systemImage: "questionmark.circle")
                .font(.caption).foregroundColor(.secondary)
        case .sshFailed(let msg):
            Label("SSH failed: \(msg)", systemImage: "xmark.circle.fill")
                .font(.caption).foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .installing:
            Label("Installing term-meshd (downloads the release binary)…",
                  systemImage: "arrow.down.circle")
                .font(.caption).foregroundColor(.secondary)
        case .installFailed(let msg):
            Label("Install failed: \(msg)", systemImage: "xmark.circle.fill")
                .font(.caption).foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .diagnosing:
            Label("Installed, verifying daemon…", systemImage: "stethoscope")
                .font(.caption).foregroundColor(.secondary)
        case .diagnosed(let reason):
            Label("Installed but the daemon won't run: \(reason)",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The agent-stack lane, rendered beneath the daemon status line.
    /// Silent until a Test has run — the whole point is answering "will
    /// an agent in a pane on this host actually notify me", which only
    /// makes sense against a reachable host.
    @ViewBuilder
    private var agentStackStatusLine: some View {
        switch agentStackState {
        case .idle:
            EmptyView()
        case .checking:
            Label("Checking agent notification setup…", systemImage: "ellipsis.circle")
                .font(.caption).foregroundColor(.secondary)
        case .status(let status):
            if status.isComplete {
                Label(agentStackCompleteText(status), systemImage: "bell.badge")
                    .font(.caption).foregroundColor(.green)
            } else {
                Label(agentStackMissingText(status), systemImage: "bell.slash")
                    .font(.caption).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .installing:
            Label("Setting up agent notifications…", systemImage: "arrow.down.circle")
                .font(.caption).foregroundColor(.secondary)
        case .installFailed(let msg):
            Label("Notification setup failed: \(msg)", systemImage: "xmark.circle.fill")
                .font(.caption).foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .installed(let summary):
            Label("Agent notifications set up — \(summary)", systemImage: "bell.badge")
                .font(.caption).foregroundColor(.green)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func agentStackCompleteText(_ status: PeerAgentStackStatus) -> String {
        status.hasClaude
            ? "Agent notifications ready — scripts installed, Claude hooks wired"
            : "Agent notification scripts installed (no claude on this host)"
    }

    private func agentStackMissingText(_ status: PeerAgentStackStatus) -> String {
        var missing: [String] = []
        if !status.scriptsInstalled { missing.append("scripts not installed") }
        if status.hasClaude && !status.hooksWired { missing.append("Claude hooks not wired") }
        // python3 gates the Claude-hook path specifically (isComplete
        // requires it whenever claude is present), so it belongs in the
        // missing list itself — not as a trailing aside — when claude is
        // there. Otherwise it's advisory only.
        if !status.hasPython3 {
            if status.hasClaude {
                missing.append("python3 missing (required for Claude hooks)")
            } else if missing.isEmpty {
                missing.append("python3 missing (needed for notifications)")
            }
        }
        let detail = missing.isEmpty ? "setup incomplete" : missing.joined(separator: ", ")
        return "Agent notifications: " + detail
    }

    /// `.daemonMissing`'s base copy, plus (when a binary was found on the
    /// host despite the daemon not running) the version it reports and
    /// which kind of host reported it.
    private var daemonMissingStatusText: String {
        guard let version = daemonMissingVersion else {
            return "SSH OK, but no peer server was found on the host."
        }
        let label = daemonMissingHostKind == .app ? "term-mesh app" : "term-meshd"
        let verb = daemonMissingHostKind == .app
            ? "is installed, but its peer socket is not running"
            : "is installed but not running"
        return "SSH OK, \(label) v\(displayVersion(version)) \(verb) on the host."
    }

    /// "term-meshd" for a Linux host, "term-mesh app" for a Mac host —
    /// tracks whichever `testedHostKind` the last successful probe
    /// found. Falls back to "term-meshd" when the kind isn't known yet
    /// (shouldn't happen once a version is known, but keeps old copy as
    /// the safe default rather than rendering a nil-derived label).
    private var serverLabel: String {
        testedHostKind == .app ? "term-mesh app" : "term-meshd"
    }

    /// Shared renderer for `.updateAvailable`/`.legacyDaemon`: the
    /// primary orange status line, plus — only for a Mac host, where
    /// there is no automatic remote-update button (see
    /// `showsUpdateButton`) — a secondary hint pointing at the manual
    /// `brew upgrade --cask term-mesh` path.
    @ViewBuilder
    private func doctorMessageWithMacHint(_ text: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(text, systemImage: systemImage)
                .font(.caption).foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if testedHostKind == .app {
                Text("Mac hosts run the app itself — update term-mesh on that Mac (brew upgrade --cask term-mesh) and relaunch.")
                    .font(.caption2).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Strips any existing "v"/"V" prefix so callers can prepend exactly
    /// one. `term-meshd --version` prints a bare `CARGO_PKG_VERSION`
    /// (e.g. "0.156.0"), but a GitHub release tag (`latest`, from
    /// `PeerDaemonVersion.fetchLatestRelease`) already carries the repo's
    /// "vX.Y.Z" tag format — prepending "v" to both unconditionally would
    /// double up on the tag side ("vv0.157.0"). Applied to every rendered
    /// version regardless of source, so a future format change on either
    /// side can't silently reintroduce the duplicate.
    private func displayVersion(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    /// Invalidates the doctor flow when a field it actually probes (SSH
    /// target, port, identity file) changes. The `doctorGeneration` bump
    /// is what actually matters: any `runTest()`/`runInstall()` Task
    /// still in flight re-checks it after every `await` and discards its
    /// result on mismatch (see `doctorGeneration`'s doc comment), so a
    /// stale response can never write over what this function resets.
    /// The resets below are the visible half — immediate UI feedback
    /// that the last Test/Install no longer applies to the edited target.
    private func invalidateDoctorState() {
        doctorGeneration += 1
        doctorState = .idle
        testedDraft = nil
        daemonMissingVersion = nil
        daemonMissingHostKind = nil
        testedHostKind = nil
        updateAttempted = false
        showInstallConfirm = false
        showUpdateConfirm = false
        agentStackState = .idle
        showAgentInstallConfirm = false
    }

    // MARK: - Doctor actions

    private func runTest() {
        guard let draft = validatedDraft() else { return }
        // Bump FIRST, then capture — immediately invalidates any Task
        // still in flight from a prior Test/Install/Update click, so a
        // rapid re-click can't race its own predecessor. See
        // `doctorGeneration`'s doc comment for the full guard discipline.
        doctorGeneration += 1
        let gen = doctorGeneration
        doctorState = .testing
        daemonMissingVersion = nil
        daemonMissingHostKind = nil
        // Snapshot NOW — this is the exact target Install/Update must use
        // later, even if the form fields change before the user acts on
        // the result (see `testedDraft`/`invalidateDoctorState()`).
        testedDraft = draft
        Task {
            let result = await PeerHostDoctor.test(
                sshTarget: draft.sshTarget, port: draft.sshPort,
                identityFile: draft.identityFile
            )
            // A field edit (→ invalidateDoctorState) or a fresh Test
            // could have superseded this response while it was in
            // flight — discard rather than write a stale doctorState.
            guard gen == doctorGeneration else { return }
            switch result {
            case .ok(let path):
                let resolved = await resolveConnectedState(socketPath: path, draft: draft)
                guard gen == doctorGeneration else { return }
                doctorState = resolved
                await refreshAgentStack(draft: draft, gen: gen)
            case .daemonMissing:
                // Binary may still be present with the service just not
                // running — surface that without touching the frozen
                // `.daemonMissing` case's signature. exit 44 (no binary)
                // resolves to nil here, leaving the plain message as-is.
                // Stay on `.testing` (busy) until this probe finishes too
                // — same discipline as the `.ok` branch above: only the
                // terminal assignment mutates doctorState, so the Test
                // button stays disabled while this runs. The generation
                // guard below is the actual safety net either way.
                let probed = await PeerHostDoctor.checkVersion(
                    sshTarget: draft.sshTarget, port: draft.sshPort,
                    identityFile: draft.identityFile
                )
                guard gen == doctorGeneration else { return }
                #if DEBUG
                dlog("peer.doctor.version state=daemonMissing remote=\(probed?.version ?? "nil") kind=\(probed?.hostKind.rawValue ?? "nil") latest=n/a")
                #endif
                daemonMissingVersion = probed?.version
                daemonMissingHostKind = probed?.hostKind
                doctorState = .daemonMissing
                // SSH itself works, so the agent stack is still worth
                // answering — a host can carry the scripts and hooks
                // before its daemon is ever installed.
                await refreshAgentStack(draft: draft, gen: gen)
            case .sshFailed(let msg): doctorState = .sshFailed(msg)
            }
        }
    }

    private func runInstall() {
        // ONLY the last Test's validated target — never re-derive from
        // the live form, which may have been edited since (see
        // `testedDraft`). No test on file means nothing to install onto.
        // Backstopped by the Install/Update buttons only rendering when
        // `testedDraft != nil` (see `showsUpdateButton`) — this guard is
        // the second line of defense, not the only one.
        guard let draft = testedDraft else { return }
        // Capture (not bump — this Task inherits whatever generation the
        // Test that produced `testedDraft` is still running under; see
        // `doctorGeneration`'s doc comment).
        let gen = doctorGeneration
        doctorState = .installing
        daemonMissingVersion = nil
        installInFlight = true
        Task {
            do {
                // `defer` fires the instant this call returns or throws —
                // i.e. exactly when the remote script actually finishes,
                // regardless of the generation check below or which exit
                // path is taken. See `installInFlight`'s doc comment.
                defer { installInFlight = false }
                _ = try await PeerHostDoctor.install(
                    sshTarget: draft.sshTarget, port: draft.sshPort,
                    identityFile: draft.identityFile
                )
            } catch {
                guard gen == doctorGeneration else { return }
                doctorState = .installFailed(String(describing: error))
                // A FAILED attempt shouldn't count against future
                // re-prompting — updateAttempted only exists to suppress
                // the Update button after a SUCCESSFUL update still
                // reports outdated/legacy (see its doc comment). No-op
                // when this run came from the plain Install flow.
                updateAttempted = false
                return
            }
            guard gen == doctorGeneration else { return }
            // Re-test; if the daemon still isn't up, surface why
            // (e.g. release binary built against a newer glibc).
            let result = await PeerHostDoctor.test(
                sshTarget: draft.sshTarget, port: draft.sshPort,
                identityFile: draft.identityFile
            )
            guard gen == doctorGeneration else { return }
            switch result {
            case .ok(let path):
                let resolved = await resolveConnectedState(socketPath: path, draft: draft)
                guard gen == doctorGeneration else { return }
                doctorState = resolved
            case .daemonMissing:
                doctorState = .diagnosing
                let raw = await PeerHostDoctor.diagnose(
                    sshTarget: draft.sshTarget, port: draft.sshPort,
                    identityFile: draft.identityFile
                )
                guard gen == doctorGeneration else { return }
                doctorState = .diagnosed(PeerHostDoctor.summarizeDiagnosis(raw))
            case .sshFailed(let msg):
                doctorState = .sshFailed(msg)
            }
        }
    }

    /// Probes the agent-notification stack and publishes the result —
    /// runs after any Test that proved SSH works. A failed probe leaves
    /// the lane at `.idle` rather than inventing a red state: the daemon
    /// line already reports connectivity problems, and this lane only
    /// speaks when it actually measured something.
    private func refreshAgentStack(draft: PeerHostProfile, gen: Int) async {
        guard gen == doctorGeneration else { return }
        agentStackState = .checking
        let status = await PeerHostDoctor.checkAgentStack(
            sshTarget: draft.sshTarget, port: draft.sshPort,
            identityFile: draft.identityFile
        )
        guard gen == doctorGeneration else { return }
        #if DEBUG
        if let status {
            dlog("peer.doctor.agentStack notify=\(status.notifyPath ?? "nil") title=\(status.titlePath ?? "nil") hooks=\(status.hooksWired) claude=\(status.hasClaude) python3=\(status.hasPython3)")
        } else {
            dlog("peer.doctor.agentStack probe failed")
        }
        #endif
        agentStackState = status.map { .status($0) } ?? .idle
    }

    /// Installs the agent stack against the exact target the last Test
    /// probed — same `testedDraft` + generation + in-flight discipline
    /// as `runInstall()`.
    private func runAgentStackInstall() {
        guard let draft = testedDraft else { return }
        guard case .status(let status) = agentStackState else {
            // `.installFailed` retry: re-probe first so the install gets
            // a current status (claude/python3 presence steer it).
            Task {
                let gen = doctorGeneration
                await refreshAgentStack(draft: draft, gen: gen)
                guard gen == doctorGeneration,
                      case .status = agentStackState else { return }
                runAgentStackInstall()
            }
            return
        }
        let gen = doctorGeneration
        agentStackState = .installing
        agentInstallInFlight = true
        Task {
            defer { agentInstallInFlight = false }
            do {
                let summary = try await PeerHostDoctor.installAgentStack(
                    sshTarget: draft.sshTarget, port: draft.sshPort,
                    identityFile: draft.identityFile, status: status
                )
                guard gen == doctorGeneration else { return }
                agentStackState = .installed(summary)
                // Install can land partial (scripts up, hooks skipped for
                // a missing python3 — installAgentStack returns rather
                // than throws), so re-probe: the lane then shows the true
                // state (green complete, or orange with what's still
                // missing) instead of a static "set up" that might not be.
                await refreshAgentStack(draft: draft, gen: gen)
            } catch {
                guard gen == doctorGeneration else { return }
                agentStackState = .installFailed(String(describing: error))
            }
        }
    }

    /// Resolves the post-connect version-comparison state for a live
    /// socket — shared by `runTest()` and the post-install retest in
    /// `runInstall()` so both paths render identical outcomes. A failed
    /// version probe or a failed latest-release lookup never downgrades
    /// a successful Test result; it only narrows the state to
    /// `.okVersionUnknown`.
    private func resolveConnectedState(
        socketPath: String,
        draft: PeerHostProfile
    ) async -> DoctorState {
        guard let probed = await PeerHostDoctor.checkVersion(
            sshTarget: draft.sshTarget, port: draft.sshPort, identityFile: draft.identityFile
        ) else {
            #if DEBUG
            dlog("peer.doctor.version state=unknown remote=nil latest=n/a")
            #endif
            testedHostKind = nil
            return .okVersionUnknown(socket: socketPath)
        }
        let installed = probed.version
        testedHostKind = probed.hostKind
        guard let latest = await PeerDaemonVersion.fetchLatestRelease() else {
            #if DEBUG
            dlog("peer.doctor.version state=unknown remote=\(installed) latest=nil")
            #endif
            return .okVersionUnknown(socket: socketPath)
        }
        switch PeerDaemonVersion.compare(installed: installed, latest: latest) {
        case .upToDate:
            #if DEBUG
            dlog("peer.doctor.version state=upToDate remote=\(installed) latest=\(latest)")
            #endif
            return .okUpToDate(socket: socketPath, version: installed)
        case .outdated(let latestTag):
            #if DEBUG
            dlog("peer.doctor.version state=outdated remote=\(installed) latest=\(latestTag)")
            #endif
            return .updateAvailable(socket: socketPath, remote: installed, latest: latestTag)
        case .legacy:
            #if DEBUG
            dlog("peer.doctor.version state=legacy remote=\(installed) latest=\(latest)")
            #endif
            return .legacyDaemon(socket: socketPath, remote: installed)
        case .unknown:
            #if DEBUG
            dlog("peer.doctor.version state=unknown remote=\(installed) latest=\(latest)")
            #endif
            return .okVersionUnknown(socket: socketPath)
        }
    }

    // MARK: - Subviews

    /// LAN-discovered peers as tappable chips: tap fills target/socket
    /// (same semantics as the legacy dialog's "Discovered on LAN" popup —
    /// the bare hostname; prepend user@ manually when needed).
    private var discoveredChips: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Discovered on LAN")
                .font(.caption)
                .foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(discovered, id: \.serviceName) { peer in
                        Button {
                            profile.sshTarget = peer.hostname
                            profile.remoteSocket = peer.socketPath ?? ""
                            if profile.displayName.isEmpty {
                                profile.displayName = peer.serviceName
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "bonjour")
                                    .font(.system(size: 9))
                                Text(peer.serviceName)
                                    .font(.system(size: 11))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                        .help("\(peer.hostname)\(peer.socketPath.map { " · \($0)" } ?? "")")
                    }
                }
            }
        }
    }

    private var colorSwatches: some View {
        HStack(spacing: 6) {
            ForEach(Self.colorChoices, id: \.self) { hex in
                Button {
                    profile.colorHex = hex
                } label: {
                    Circle()
                        .fill(hex.flatMap { NSColor(hex: $0) }.map { Color(nsColor: $0) }
                              ?? Color.secondary.opacity(0.25))
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle().strokeBorder(
                                profile.colorHex == hex ? Color.accentColor : .clear,
                                lineWidth: 2
                            )
                        )
                        .overlay {
                            if hex == nil {
                                Image(systemName: "slash.circle")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(hex ?? "No color")
            }
        }
    }

    private var symbolPicker: some View {
        HStack(spacing: 6) {
            ForEach(Self.symbolChoices, id: \.self) { name in
                Button {
                    profile.symbolName = name
                } label: {
                    Image(systemName: name ?? "network")
                        .font(.system(size: 11))
                        .frame(width: 22, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(profile.symbolName == name
                                      ? Color.accentColor.opacity(0.25)
                                      : Color.secondary.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .help(name ?? "Default")
            }
        }
    }

    // MARK: - Save

    /// Same validation surface the tunnel/probe enforce at spawn time,
    /// surfaced here at edit time so a bad profile fails in the form,
    /// not on first connect. Returns nil (and sets `validationError`)
    /// on any invalid field. Shared by Save and the doctor actions.
    private func validatedDraft() -> PeerHostProfile? {
        var draft = profile
        draft.displayName = draft.displayName.trimmingCharacters(in: .whitespaces)
        draft.sshTarget = draft.sshTarget.trimmingCharacters(in: .whitespaces)
        draft.remoteSocket = draft.remoteSocket.trimmingCharacters(in: .whitespaces)
        if let identity = draft.identityFile {
            let trimmed = identity.trimmingCharacters(in: .whitespaces)
            draft.identityFile = trimmed.isEmpty ? nil : trimmed
        }

        do {
            try PeerSSHTunnel.validateSshTarget(draft.sshTarget)
            let trimmedPort = portText.trimmingCharacters(in: .whitespaces)
            if trimmedPort.isEmpty {
                draft.sshPort = nil
            } else {
                guard let port = Int(trimmedPort) else {
                    validationError = "Port must be a number"
                    return nil
                }
                try PeerSSHTunnel.validatePort(port)
                draft.sshPort = port
            }
            if let identity = draft.identityFile {
                try PeerSSHTunnel.validateIdentityFile(identity)
            }
            if !draft.remoteSocket.isEmpty {
                try PeerSSHTunnel.validateRemoteSockPath(draft.remoteSocket)
            }
        } catch PeerSSHTunnelError.invalidArgument(let message) {
            validationError = message
            return nil
        } catch {
            validationError = String(describing: error)
            return nil
        }
        validationError = nil
        return draft
    }

    private func validateAndSave() {
        guard let draft = validatedDraft() else { return }
        onSave(draft)
    }

    /// Binding for optional String fields ("" ↔ nil).
    private func optionalBinding(_ keyPath: WritableKeyPath<PeerHostProfile, String?>) -> Binding<String> {
        Binding(
            get: { profile[keyPath: keyPath] ?? "" },
            set: { profile[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}
