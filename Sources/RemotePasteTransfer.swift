import AppKit
import Bonsplit
import Foundation

/// Makes an image or file paste work in a remote pane.
///
/// Pasting a picture locally is really a file paste: the clipboard image is
/// written to a temp file and the PATH is what lands in the terminal, because
/// that is what a CLI agent can act on. Over a relay that breaks — the path
/// arrives on the peer, the file does not, and the agent reports a missing
/// file. The bytes have to travel with it.
///
/// Deliberately a transfer, not a sync: one direction, at the moment of the
/// paste, to a fresh name every time. There is no shared state to reconcile and
/// so no conflict to resolve — the whole class of problem a mirrored folder
/// creates simply does not arise here.
enum RemotePasteTransfer {
    struct Destination: Equatable, Sendable {
        let sshTarget: String
        let port: Int?
        let identityFile: String?
    }

    /// Resolve a scratch directory that both the SSH login and the peer pane
    /// can see. A system service with `PrivateTmp=true` gets a private /tmp
    /// (and /var/tmp), so either of those silently produces a path that exists
    /// for SSH and is missing from the pane. The connecting account's cache is
    /// shared across both processes when the installer keeps their identities
    /// aligned. `serviceAccountCommand` also switches a root SSH login
    /// to an explicitly selected system-service account before touching it.
    static let remoteDirectoryCommand =
        serviceAccountCommand(
            #"umask 077; d="${XDG_CACHE_HOME:-$HOME/.cache}/term-mesh/paste"; mkdir -p "$d" && chmod 700 "$d" && printf %s "$d""#
        )

    /// The peer to send a paste to, or nil when the pane is local.
    ///
    /// The pane being pasted into decides, not the connection roster. Asking
    /// "is any peer connected" answers a different question and gets the
    /// common case wrong: with one relay open, a paste into an ordinary local
    /// pane would be shipped away and pasted back as a path that exists only
    /// on the peer. A pane knows its own host, so ask the pane.
    @MainActor
    static func destination(for context: GhosttySurfaceCallbackContext) -> Destination? {
        // Relay-window panes live outside every tabManager workspace, so the
        // panel lookup below cannot see them; their host is the window's own
        // connection. The debug single-pane relay window has no ssh target by
        // construction, which reads as local — the right fallback, since
        // there is nowhere to send the bytes.
        if let window = context.surfaceView?.window {
            if let controller = window.windowController as? PeerRelayWorkspaceWindowController {
                return destination(from: controller.connectionInfo)
            }
            if window.windowController is PeerRelayWindowController { return nil }
        }

        guard let tunnel = terminalPanel(for: context)?.peerPaneSession?.lease.tunnel,
              !tunnel.sshTarget.isEmpty else { return nil }
        return Destination(
            sshTarget: tunnel.sshTarget,
            port: tunnel.port,
            identityFile: tunnel.identityFile
        )
    }

    @MainActor
    private static func destination(from info: PeerRelayConnectionInfo) -> Destination? {
        guard let target = info.sshTarget, !target.isEmpty else { return nil }
        return Destination(
            sshTarget: target,
            port: info.sshPort,
            identityFile: info.identityFile
        )
    }

    /// The panel that owns `context`'s surface, searched across every window.
    ///
    /// The surface's tab id is not trusted as an index: moving a pane between
    /// workspaces leaves the context's cached id behind, and a miss here would
    /// silently downgrade a remote pane to a local paste. Scanning every
    /// workspace is a handful of dictionary lookups on a single paste.
    @MainActor
    private static func terminalPanel(for context: GhosttySurfaceCallbackContext) -> TerminalPanel? {
        guard let app = AppDelegate.shared else { return nil }
        for windowContext in app.mainWindowContexts.values {
            for workspace in windowContext.tabManager.tabs {
                if let panel = workspace.terminalPanel(for: context.surfaceId) { return panel }
            }
        }
        return nil
    }

    /// Whether `text` is a local file path this machine produced for a paste.
    ///
    /// Both clipboard paths take this shape: a Finder file URL, and the temp
    /// file an image paste writes. Anything else — ordinary text — is left
    /// alone, which is why a normal paste keeps working untouched.
    static func localPath(from text: String) -> String? {
        let unescaped = text.replacingOccurrences(of: "\\", with: "")
        guard unescaped.hasPrefix("/"),
              !unescaped.contains("\n"),
              FileManager.default.fileExists(atPath: unescaped) else { return nil }
        return unescaped
    }

    /// Copy `localPath` to `sshTarget` and return the path it now has there.
    ///
    /// Blocking on purpose: the caller is Ghostty's clipboard request, which
    /// keeps its state alive until completed, and it runs off the main thread.
    /// A failed copy returns nil so the caller can fall back to pasting the
    /// original text rather than silently pasting nothing.
    static func send(localPath: String, to destination: Destination) -> String? {
        let sshTarget = destination.sshTarget
        guard let directoryArguments = sshArguments(
            to: destination,
            command: remoteDirectoryCommand
        ) else {
            RemoteWorkLog.infoOffMain("Paste not sent: invalid SSH settings for \(sshTarget)")
            return nil
        }
        let name = uniqueName(for: localPath)
        let label = (localPath as NSString).lastPathComponent
        let started = Date()
        RemoteWorkLog.debugOffMain("Sending \(label) (\(describeSize(of: localPath))) → \(sshTarget)")

        guard let remoteDirectory = capture("/usr/bin/ssh", directoryArguments),
              validRemoteDirectory(remoteDirectory) else {
            log("mkdir failed on \(sshTarget)")
            RemoteWorkLog.infoOffMain("Paste failed: could not create a shared cache on \(sshTarget)")
            return nil
        }
        let remotePath = "\(remoteDirectory)/\(name)"
        guard sendFile(localPath, to: remotePath, using: destination) else {
            log("stream failed \(localPath) -> \(sshTarget)")
            RemoteWorkLog.infoOffMain("Paste failed: could not copy \(label) to \(sshTarget)")
            return nil
        }
        log("sent \(localPath) -> \(sshTarget):\(remotePath)")
        // The elapsed time is here because this blocks the paste: a picture
        // that takes four seconds to land reads as the terminal being frozen,
        // and this is the line that explains it.
        RemoteWorkLog.infoOffMain(
            "Pasted \(label) (\(describeSize(of: localPath))) → \(sshTarget):\(remotePath) in \(elapsed(since: started))"
        )
        return remotePath
    }

    // MARK: - Internals

    /// A name that cannot collide with an earlier paste, so a second paste of
    /// the same picture never lands on a file an agent is still reading.
    private static func uniqueName(for path: String) -> String {
        let base = (path as NSString).lastPathComponent
        let stamp = UInt64(Date().timeIntervalSince1970 * 1000)
        return "\(stamp)-\(base)"
    }

    /// The file's size for the log line, or "unknown size" when it cannot be
    /// read — a size that cannot be told is not worth failing a paste over.
    private static func describeSize(of path: String) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let bytes = attributes[.size] as? NSNumber else { return "unknown size" }
        return ByteCountFormatter.string(fromByteCount: bytes.int64Value, countStyle: .file)
    }

    private static func elapsed(since start: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(start))
    }

    private static func validTarget(_ target: String) -> Bool {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@[]:"
        )
        return !target.isEmpty
            && target.unicodeScalars.allSatisfy(allowed.contains)
            && !target.hasPrefix("-")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func validRemoteDirectory(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("\n") && !value.contains("\0")
    }

    /// Stream over ssh instead of handing a quoted remote path to scp. Modern
    /// scp switches between legacy shell parsing and SFTP across OS versions;
    /// stdin + `cat > quoted-path` has one meaning on all supported peers.
    private static func sendFile(
        _ localPath: String,
        to remotePath: String,
        using destination: Destination
    ) -> Bool {
        guard let input = FileHandle(forReadingAtPath: localPath) else { return false }
        defer { try? input.close() }
        guard let arguments = sshArguments(
            to: destination,
            command: serviceAccountCommand("umask 077; cat > \(shellQuote(remotePath))")
        ) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Build one SSH argv for every phase of the transfer so cache creation
    /// and byte streaming cannot disagree about port or identity.
    static func sshArguments(to destination: Destination, command: String) -> [String]? {
        guard validTarget(destination.sshTarget) else { return nil }
        if let port = destination.port,
           (try? PeerSSHTunnel.validatePort(port)) == nil { return nil }
        if let identityFile = destination.identityFile,
           (try? PeerSSHTunnel.validateIdentityFile(identityFile)) == nil { return nil }

        var arguments: [String] = []
        if let port = destination.port {
            arguments += ["-p", String(port)]
        }
        if let identityFile = destination.identityFile {
            arguments += ["-i", (identityFile as NSString).expandingTildeInPath]
        }
        arguments += ["--", destination.sshTarget, command]
        return arguments
    }

    private static func capture(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// A direct root SSH login normally stays root. Only when the installed
    /// system unit explicitly names another User= do file operations switch
    /// to that account, matching the pane without running the daemon itself
    /// through sudo. Non-root and user-service connections stay untouched.
    /// Run a file operation as the account that owns the remote pane.
    ///
    /// Leader prompt staging shares this identity resolution with paste
    /// transfer so the two paths cannot disagree about a system service's
    /// `User=` account.
    static func serviceAccountCommand(_ command: String) -> String {
        let quoted = shellQuote(command)
        return "u=$(systemctl show -p User --value term-meshd.service 2>/dev/null || true); "
            + "[ -n \"$u\" ] || u=$(id -un); "
            + "if [ \"$(id -u)\" -eq 0 ] && [ \"$u\" != root ]; then "
            + "h=$(getent passwd \"$u\" | awk -F: '{print $6}'); [ -n \"$h\" ] || exit 127; "
            + "command -v runuser >/dev/null 2>&1 || exit 127; "
            + "exec runuser -u \"$u\" -- env HOME=\"$h\" XDG_CACHE_HOME= /bin/sh -c \(quoted); "
            + "else exec /bin/sh -c \(quoted); fi"
    }

    private static func log(_ message: String) {
        #if DEBUG
        dlog("paste.remote.\(message)")
        #endif
    }
}
