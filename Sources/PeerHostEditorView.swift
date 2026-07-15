//  PeerHostEditorView: add/edit sheet for saved remote-host profiles
//  (sidebar-first peer UX, Phase 3). Mounted from the sidebar's Remote
//  Hosts section via .sheet(item:). SwiftUI by design — the legacy
//  NSAlert connect dialogs stay untouched until Phase 4 retires them.

import AppKit
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
    }
    @State private var doctorState: DoctorState = .idle
    @State private var showInstallConfirm = false

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
        .confirmationDialog(
            "Install term-meshd on \"\(profile.sshTarget)\"?",
            isPresented: $showInstallConfirm
        ) {
            Button("Install") { runInstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runs the official install script over SSH: downloads the latest release binary and registers a systemd user service.")
        }
    }

    private var doctorBusy: Bool {
        switch doctorState {
        case .testing, .installing, .diagnosing: return true
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
            Label("SSH OK, but term-meshd is not running on the host.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundColor(.orange)
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

    // MARK: - Doctor actions

    private func runTest() {
        guard let draft = validatedDraft() else { return }
        doctorState = .testing
        Task {
            let result = await PeerHostDoctor.test(
                sshTarget: draft.sshTarget, port: draft.sshPort,
                identityFile: draft.identityFile
            )
            switch result {
            case .ok(let path): doctorState = .ok(path)
            case .daemonMissing: doctorState = .daemonMissing
            case .sshFailed(let msg): doctorState = .sshFailed(msg)
            }
        }
    }

    private func runInstall() {
        guard let draft = validatedDraft() else { return }
        doctorState = .installing
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
                doctorState = .ok(path)
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
