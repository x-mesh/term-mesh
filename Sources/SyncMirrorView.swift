import AppKit
import SwiftUI

/// The Mirror tab: keep a project folder the same on both machines.
///
/// Sits beside Checkpoints rather than replacing it, because the two answer
/// different questions. A checkpoint captures a reviewable unit of work as
/// commits; a mirror keeps the working trees equal while you are still in them.
/// The protocol ADR makes that split permanent — sync never touches `HEAD`, a
/// branch, the index, or the worktree, so it cannot carry commits and is not a
/// replacement for the git path.
struct SyncMirrorTab: View {
    @ObservedObject var store: WorkspaceRetrievalStore
    @ObservedObject var mirrors: SyncMirrorStore
    /// Resolves a peer's ssh target and dialable address from its label. The
    /// pane record carries the ssh target; the address the transport dials is a
    /// separate question, so the host list answers it.
    let peerLookup: (String) -> (sshTarget: String, address: String)?

    var body: some View {
        Group {
            if store.projectBindings.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.projectBindings, id: \.id) { binding in
                            MirrorRow(
                                binding: binding,
                                mirrors: mirrors,
                                peer: peerLookup(binding.peerID)
                            )
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No Mirrored Folders")
                .font(.headline)
            Text("Open a remote pane on a peer host to bind a project folder, then mirror it here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// One folder pair, with its paths editable before it is mirrored.
private struct MirrorRow: View {
    let binding: ProjectBinding
    @ObservedObject var mirrors: SyncMirrorStore
    let peer: (sshTarget: String, address: String)?

    @State private var localPath: String = ""
    @State private var remotePath: String = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(binding.peerID).font(.headline)
                Spacer()
                if mirrors.state(for: binding.id).isBusy {
                    ProgressView().controlSize(.small)
                }
                Button(mirrors.isProvisioned(binding.id) ? "Sync Now" : "Mirror", action: startMirror)
                    .disabled(peer == nil || mirrors.state(for: binding.id).isBusy || !pathsAreUsable)
                    .accessibilityIdentifier("sync.mirror.\(binding.peerID)")
            }

            pathField(
                label: "This Mac",
                text: $localPath,
                placeholder: binding.localRoot,
                browsable: true
            )
            pathField(
                label: binding.peerID,
                text: $remotePath,
                placeholder: binding.remoteRoot,
                browsable: false
            )

            if let warning = broadRootWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            statusLine(mirrors.state(for: binding.id))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear {
            guard !loaded else { return }
            let paths = mirrors.paths(for: binding)
            localPath = paths.local
            remotePath = paths.remote
            loaded = true
        }
    }

    @ViewBuilder
    private func pathField(
        label: String,
        text: Binding<String>,
        placeholder: String,
        browsable: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .disabled(mirrors.isProvisioned(binding.id))
                .onSubmit(commitPaths)
            if browsable {
                Button("Choose…", action: choose)
                    .controlSize(.small)
                    .disabled(mirrors.isProvisioned(binding.id))
            }
        }
    }

    /// Mirrored folders are fixed once provisioned: the sync project is
    /// anchored to its local root, and a daemon offers no way to unregister
    /// one. Re-pointing means starting a new mirror, which `Reset` does.
    private var pathsAreUsable: Bool {
        !localPath.trimmed.isEmpty && !remotePath.trimmed.isEmpty
            && localPath.hasPrefix("/") && remotePath.hasPrefix("/")
    }

    private var broadRootWarning: String? {
        let broad = [localPath, remotePath]
            .filter { !$0.trimmed.isEmpty && MirrorPaths.isBroadRoot($0.trimmed) }
        guard !broad.isEmpty else { return nil }
        return "\(broad.joined(separator: ", ")) covers a whole home or filesystem root. "
            + "Mirroring propagates deletions — pick the project folder instead."
    }

    private func commitPaths() {
        guard pathsAreUsable else { return }
        mirrors.setPaths(
            MirrorPaths(local: localPath.trimmed, remote: remotePath.trimmed),
            for: binding
        )
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: localPath.trimmed.isEmpty ? binding.localRoot : localPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        localPath = url.path
        commitPaths()
    }

    private func startMirror() {
        guard let peer else { return }
        commitPaths()
        Task {
            await mirrors.mirror(
                binding: binding,
                sshTarget: peer.sshTarget,
                peerAddress: peer.address,
                remoteToolPath: SyncMirrorTab.remoteToolPath,
                remoteSocketPath: SyncMirrorTab.remoteSocketPath
            )
        }
    }

    @ViewBuilder
    private func statusLine(_ state: SyncMirrorState) -> some View {
        HStack(spacing: 8) {
            switch state {
            case .idle:
                Text("Not mirrored yet")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case .provisioning:
                Text("Provisioning trust on both machines…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .syncing:
                Text("Syncing…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .synced(let at, let entries):
                Text("\(entries) item(s) moved · \(at.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            if mirrors.isProvisioned(binding.id) || state == .idle {
                Button("Reset") { mirrors.reset(binding: binding.id) }
                    .buttonStyle(.link)
                    .font(.caption2)
                    .help("Forget this mirror's provisioning so the folders can be changed.")
            }
        }
    }
}

extension SyncMirrorTab {
    /// Where `tm-agent` lives on the peer.
    ///
    /// Fixed for now. A peer installed by `install-linux.sh` puts it here, and
    /// making it configurable is a settings question that should wait until the
    /// git-vs-mirror decision this tab exists to inform.
    static let remoteToolPath = "/root/.local/bin/tm-agent"

    /// Which daemon on the peer gets provisioned.
    ///
    /// Pointed at an isolated test daemon on purpose while the git-vs-mirror
    /// comparison is being run: provisioning writes trust state, a project key
    /// and a project registration, and doing that to a long-lived daemon that
    /// other sessions are attached to is not something a first trial should do.
    /// Switch to the peer's real socket once the approach is chosen.
    static let remoteSocketPath = "/tmp/synctest-B.sock"
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
