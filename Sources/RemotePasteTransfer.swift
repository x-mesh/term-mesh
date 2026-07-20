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
    /// Directory the pasted files land in on the peer. Under `/tmp` because
    /// these are scratch: an agent reads one and moves on, and a reboot is a
    /// perfectly good cleanup policy.
    static let remoteDirectory = "/tmp/term-mesh-paste"

    /// The peer to send a paste to, or nil when nothing is connected.
    ///
    /// A single connected host is the overwhelmingly common case and needs no
    /// choosing. With several, this cannot tell which pane the paste is aimed
    /// at from the clipboard callback alone, so it declines rather than
    /// guessing and shipping a file to the wrong machine.
    @MainActor
    static func destination() -> String? {
        let targets = Set(
            PeerClientCoordinator.shared.activeConnections()
                .compactMap(\.sshTarget)
                .filter { !$0.isEmpty }
        )
        // Only reported when there IS a choice to get wrong. No peer at all is
        // an ordinary local paste and saying so on every one would bury the
        // drawer; several peers means the file is about to be pasted as a path
        // that resolves nowhere, which looks like the agent being broken.
        if targets.count > 1 {
            RemoteWorkLog.info(
                "Paste not sent: \(targets.count) hosts connected and the pane it is aimed at cannot be told apart — pasting the local path unchanged"
            )
        }
        guard targets.count == 1 else { return nil }
        return targets.first
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
    static func send(localPath: String, to sshTarget: String) -> String? {
        guard validTarget(sshTarget) else {
            RemoteWorkLog.infoOffMain("Paste not sent: refused the host name \(sshTarget)")
            return nil
        }
        let name = uniqueName(for: localPath)
        let remotePath = "\(remoteDirectory)/\(name)"
        let label = (localPath as NSString).lastPathComponent
        let started = Date()
        RemoteWorkLog.debugOffMain("Sending \(label) (\(describeSize(of: localPath))) → \(sshTarget)")

        guard run("/usr/bin/ssh", [sshTarget, "mkdir -p \(shellQuote(remoteDirectory))"]) else {
            log("mkdir failed on \(sshTarget)")
            RemoteWorkLog.infoOffMain("Paste failed: could not create \(remoteDirectory) on \(sshTarget)")
            return nil
        }
        guard run("/usr/bin/scp", ["-q", localPath, "\(sshTarget):\(remotePath)"]) else {
            log("scp failed \(localPath) -> \(sshTarget)")
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

    private static func run(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
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

    private static func log(_ message: String) {
        #if DEBUG
        dlog("paste.remote.\(message)")
        #endif
    }
}
