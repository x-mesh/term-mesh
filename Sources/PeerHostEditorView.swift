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
    /// Suppresses the Update button after one update attempt this sheet
    /// session, even if the post-update retest still reports
    /// outdated/legacy — avoids nagging the user in a retry loop.
    @State private var updateAttempted = false
    /// Version reported by a binary found on the host while term-meshd
    /// itself isn't running (`.daemonMissing`). Kept out of that case's
    /// associated value since its signature must not change.
    @State private var daemonMissingVersion: String?
    /// The exact (sshTarget, port, identityFile) — as a validated
    /// `PeerHostProfile` — that the last `runTest()` actually probed.
    /// `runInstall()` reads ONLY this, never a fresh `validatedDraft()`,
    /// so Install/Update always targets what was tested even if the form
    /// fields changed afterward. Cleared by `invalidateDoctorState()`.
    @State private var testedDraft: PeerHostProfile?

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

            HStack {
                Button("Test", action: runTest)
                    .disabled(doctorBusy
                              || profile.sshTarget.trimmingCharacters(in: .whitespaces).isEmpty)
                if case .daemonMissing = doctorState {
                    Button("Install term-meshd…") { showInstallConfirm = true }
                        .disabled(doctorBusy)
                }
                if showsUpdateButton {
                    Button("Update term-meshd…") { showUpdateConfirm = true }
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
    }

    private var doctorBusy: Bool {
        switch doctorState {
        case .testing, .installing, .diagnosing: return true
        default: return false
        }
    }

    /// Shown for `.updateAvailable`/`.legacyDaemon`, suppressed after one
    /// update attempt this session (see `updateAttempted`).
    private var showsUpdateButton: Bool {
        guard !updateAttempted else { return false }
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
            Label("term-meshd v\(displayVersion(version)) — up to date", systemImage: "checkmark.seal")
                .font(.caption).foregroundColor(.green)
        case .updateAvailable(_, let remote, let latest):
            Label("Update available: v\(displayVersion(remote)) → v\(displayVersion(latest))", systemImage: "arrow.up.circle")
                .font(.caption).foregroundColor(.orange)
        case .legacyDaemon(_, let remote):
            Label("Legacy daemon (v\(displayVersion(remote))) — update recommended (version reporting predates v\(displayVersion(PeerDaemonVersion.versionSyncFloor)))",
                  systemImage: "exclamationmark.arrow.circlepath")
                .font(.caption).foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
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

    /// `.daemonMissing`'s base copy, plus (when a binary was found on the
    /// host despite the daemon not running) the version it reports.
    private var daemonMissingStatusText: String {
        guard let version = daemonMissingVersion else {
            return "SSH OK, but term-meshd is not running on the host."
        }
        return "SSH OK, term-meshd v\(displayVersion(version)) is installed but not running on the host."
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
    /// target, port, identity file) changes — a `testedDraft` snapshot
    /// from before the edit must never be used for a later Install/Update,
    /// and a stale status label is worse than none.
    private func invalidateDoctorState() {
        doctorState = .idle
        testedDraft = nil
        daemonMissingVersion = nil
        updateAttempted = false
        showInstallConfirm = false
        showUpdateConfirm = false
    }

    // MARK: - Doctor actions

    private func runTest() {
        guard let draft = validatedDraft() else { return }
        doctorState = .testing
        daemonMissingVersion = nil
        // Snapshot NOW — this is the exact target Install/Update must use
        // later, even if the form fields change before the user acts on
        // the result (see `testedDraft`/`invalidateDoctorState()`).
        testedDraft = draft
        Task {
            let result = await PeerHostDoctor.test(
                sshTarget: draft.sshTarget, port: draft.sshPort,
                identityFile: draft.identityFile
            )
            switch result {
            case .ok(let path):
                doctorState = await resolveConnectedState(socketPath: path, draft: draft)
            case .daemonMissing:
                // Binary may still be present with the service just not
                // running — surface that without touching the frozen
                // `.daemonMissing` case's signature. exit 44 (no binary)
                // resolves to nil here, leaving the plain message as-is.
                // Stay on `.testing` (busy) until this probe finishes too
                // — same discipline as the `.ok` branch above: only the
                // terminal assignment mutates doctorState, so the Test
                // button stays disabled and a second Test can't race a
                // late-arriving response into a stale UI state.
                let version = await PeerHostDoctor.checkVersion(
                    sshTarget: draft.sshTarget, port: draft.sshPort,
                    identityFile: draft.identityFile
                )
                #if DEBUG
                dlog("peer.doctor.version state=daemonMissing remote=\(version ?? "nil") latest=n/a")
                #endif
                daemonMissingVersion = version
                doctorState = .daemonMissing
            case .sshFailed(let msg): doctorState = .sshFailed(msg)
            }
        }
    }

    private func runInstall() {
        // ONLY the last Test's validated target — never re-derive from
        // the live form, which may have been edited since (see
        // `testedDraft`). No test on file means nothing to install onto.
        guard let draft = testedDraft else { return }
        doctorState = .installing
        daemonMissingVersion = nil
        Task {
            do {
                _ = try await PeerHostDoctor.install(
                    sshTarget: draft.sshTarget, port: draft.sshPort,
                    identityFile: draft.identityFile
                )
            } catch {
                doctorState = .installFailed(String(describing: error))
                return
            }
            // Re-test; if the daemon still isn't up, surface why
            // (e.g. release binary built against a newer glibc).
            let result = await PeerHostDoctor.test(
                sshTarget: draft.sshTarget, port: draft.sshPort,
                identityFile: draft.identityFile
            )
            switch result {
            case .ok(let path):
                doctorState = await resolveConnectedState(socketPath: path, draft: draft)
            case .daemonMissing:
                doctorState = .diagnosing
                let raw = await PeerHostDoctor.diagnose(
                    sshTarget: draft.sshTarget, port: draft.sshPort,
                    identityFile: draft.identityFile
                )
                doctorState = .diagnosed(PeerHostDoctor.summarizeDiagnosis(raw))
            case .sshFailed(let msg):
                doctorState = .sshFailed(msg)
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
        guard let installed = await PeerHostDoctor.checkVersion(
            sshTarget: draft.sshTarget, port: draft.sshPort, identityFile: draft.identityFile
        ) else {
            #if DEBUG
            dlog("peer.doctor.version state=unknown remote=nil latest=n/a")
            #endif
            return .okVersionUnknown(socket: socketPath)
        }
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
