import Foundation

/// Where bytes that nobody typed came into a local pane.
///
/// **Why this exists.** A stray `ÿ` (0xFF) keeps turning up in idle panes, and
/// twice the trail has ended at "no side records where a byte enters." The
/// relay helper gained a stdin hex dump for exactly this
/// (`daemon/term-mesh-peer-relay/src/main.rs`), and it was aimed at the wrong
/// door: on the recurrence that produced this file, `peer.pane.status`
/// reported zero pane sessions and no helper process was running, so that log
/// could not have fired. The bytes arrived at a local surface.
///
/// The recurrence also showed WHAT arrives, which the earlier ones did not: a
/// pane received fragments of its OWN rendered screen — `◉ /goal active (26m)`
/// — submitted back to it as messages, one after another. Output returning as
/// input is a loop, and the reported condition for it is a remote viewer
/// attached over a relay. That is the shape `PeerTerminalQueryStripper`
/// already documents from the other direction: on a relayed pane the bytes
/// reach TWO terminals, and both answer.
///
/// **What it decides.** Both doors are recorded, with the call site:
/// programmatic writes this app makes into a surface, and Input frames a
/// connected peer client sends. A stray byte that appears under a local site
/// was injected by this app and the site names the path; one that appears
/// under `sendPeerInputBytes` came back from a viewer's terminal; one that
/// appears under neither came from the keyboard, Ghostty, or the PTY. Nothing
/// today can tell those three apart, which is why two investigations have
/// stopped at the same place.
///
/// **Why it is not a keylog.** The real keyboard path (`keyDown`/`keyUp`) is
/// deliberately NOT recorded. Even on the doors that are, bytes are written
/// out only for chunks that are not ordinary typed text — the same rule the
/// relay helper uses, so the two logs read against each other — because an
/// injection carries pasted content and agent prompts, and a log holding all
/// of it would be worse than the bug. Site, target and length are always
/// recorded, so a plain-text injection still lands on the timeline without its
/// content.
///
/// **Off unless asked.** Gated on a marker file so it can ship in a release
/// and cost nothing until someone chasing this creates the marker — the
/// symptom happens on the released app, so a DEBUG-only log would only ever
/// watch a build where it does not occur.
///
///     mkdir -p ~/Library/Caches/term-mesh
///     touch ~/Library/Caches/term-mesh/input-debug.on     # then reproduce
///     cat ~/Library/Caches/term-mesh/input-debug.log
enum InputInjectionLog {
    /// Presence enables recording. A file rather than an env var because the
    /// app under investigation is already running and cannot be relaunched
    /// without losing the state that produced the symptom.
    private static let directoryURL = FileManager.default.urls(
        for: .cachesDirectory, in: .userDomainMask
    )[0].appendingPathComponent("term-mesh", isDirectory: true)

    static var markerPath: String {
        directoryURL.appendingPathComponent("input-debug.on").path
    }

    /// Tag-isolated like `RemoteWorkLog`, so a tagged debug build chasing this
    /// does not interleave with the production app's own recording.
    static var path: String {
        let tag = ProcessInfo.processInfo.environment["TERMMESH_TAG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let safeTag = tag.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                ? String(scalar) : "_"
        }.joined()
        let name = safeTag.isEmpty ? "input-debug.log" : "input-debug-\(safeTag).log"
        return directoryURL.appendingPathComponent(name).path
    }

    // MARK: - Enablement

    private static let lock = NSLock()
    private static var cachedEnabled = false
    private static var cachedAt: TimeInterval = -1

    /// Re-stat at most once a second.
    ///
    /// Checking once at launch would mean the marker only takes effect after a
    /// relaunch, which loses the running state; checking every call would put
    /// a `stat` on the paste path, which chunks a long agent prompt into
    /// hundreds of calls. A second is far below human reproduction time and
    /// far above the injection rate.
    private static let enabledTTL: TimeInterval = 1.0

    static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["TERMMESH_INPUT_DEBUG"] != nil { return true }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        if cachedAt >= 0, now - cachedAt < Self.enabledTTL { return cachedEnabled }
        cachedEnabled = FileManager.default.fileExists(atPath: markerPath)
        cachedAt = now
        return cachedEnabled
    }

    // MARK: - The keylog boundary

    /// Whether a chunk is nothing but text a person could have typed.
    ///
    /// Mirrors `is_ordinary_typed_text` in the relay helper so the two logs
    /// can be read against each other without holding two rules in mind.
    /// Printable ASCII plus tab/CR/LF is the shape of ordinary keystrokes;
    /// such a chunk is recorded by length only. What is worth seeing is the
    /// byte that should not be there at all — a stray control or high byte,
    /// which is how `ÿ` came to sit in an idle prompt.
    static func isOrdinaryTypedText<S: Sequence>(_ bytes: S) -> Bool where S.Element == UInt8 {
        exceptionalBytes(in: Array(bytes)).isEmpty
    }

    /// Control bytes and malformed UTF-8 bytes, without retaining valid text
    /// that happened to share their input chunk.
    private static func exceptionalBytes(in bytes: [UInt8]) -> [(Int, UInt8)] {
        var result: [(Int, UInt8)] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte < 0x80 {
                if (byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D)
                    || byte == 0x7F
                {
                    result.append((index, byte))
                }
                index += 1
                continue
            }

            let length: Int
            switch byte {
            case 0xC2...0xDF: length = 2
            case 0xE0...0xEF: length = 3
            case 0xF0...0xF4: length = 4
            default:
                result.append((index, byte))
                index += 1
                continue
            }
            guard index + length <= bytes.count else {
                result.append((index, byte))
                index += 1
                continue
            }
            let continuation = bytes[(index + 1)..<(index + length)]
            let hasValidContinuation = continuation.allSatisfy { (0x80...0xBF).contains($0) }
            let hasValidBoundary = (byte != 0xE0 || bytes[index + 1] >= 0xA0)
                && (byte != 0xED || bytes[index + 1] <= 0x9F)
                && (byte != 0xF0 || bytes[index + 1] >= 0x90)
                && (byte != 0xF4 || bytes[index + 1] <= 0x8F)
            guard hasValidContinuation, hasValidBoundary else {
                result.append((index, byte))
                index += 1
                continue
            }
            index += length
        }
        return result
    }

    // MARK: - Recording

    /// One programmatic write of `text` into a surface.
    ///
    /// `site` is the function that made it — the whole point is which path a
    /// byte came down, so it is required and spelled out at the call.
    static func record(site: String, surface: UUID?, text: String) {
        guard isEnabled else { return }
        let bytes = Array(text.utf8)
        append(site: site, surface: surface, bytes: bytes, extra: nil)
    }

    /// One synthesized key event. `keycode` rides along because the Return and
    /// Tab paths carry a keycode with no text, and "which key" is then the
    /// only thing that distinguishes them on the timeline.
    static func recordKey(site: String, surface: UUID?, keycode: UInt16, text: String?) {
        guard isEnabled else { return }
        append(
            site: site,
            surface: surface,
            bytes: Array((text ?? "").utf8),
            extra: "keycode=\(keycode)"
        )
    }

    /// One Input frame a connected peer client sent, as it reaches a local
    /// surface.
    ///
    /// The host's door, and the one that decides the open question. When a
    /// remote viewer is attached, the host's output reaches TWO terminals and
    /// a byte that comes back through here is the viewer's terminal answering
    /// into this machine's PTY. If a pane's own rendered screen shows up on
    /// this line, the loop is closed and its direction is settled — no other
    /// vantage point can distinguish that from the user typing.
    ///
    /// `label` rather than a `UUID`: the host path holds a raw
    /// `ghostty_surface_t`, and inventing an identity for it here would only
    /// be a second name for the same pointer.
    static func recordPeerInput(site: String, label: String, bytes: Data) {
        guard isEnabled else { return }
        appendLabelled(site: site, label: label, bytes: Array(bytes), extra: nil)
    }

    private static func append(site: String, surface: UUID?, bytes: [UInt8], extra: String?) {
        appendLabelled(
            site: site,
            label: surface?.uuidString.prefix(8).description ?? "none",
            bytes: bytes,
            extra: extra
        )
    }

    private static func appendLabelled(
        site: String, label: String, bytes: [UInt8], extra: String?
    ) {
        var line = "\(ISO8601DateFormatter().string(from: Date())) \(site)"
        line += " surface=\(label)"
        if let extra { line += " \(extra)" }
        line += " bytes=\(bytes.count)"
        // The content rule. Length and site are always here; the bytes only
        // when they are not something a person could have typed.
        if !bytes.isEmpty, !isOrdinaryTypedText(bytes) {
            let exceptional = exceptionalBytes(in: bytes).map { offset, byte in
                return "\(offset):" + String(format: "%02x", byte)
            }.prefix(16)
            line += " exceptional=[" + exceptional.joined(separator: " ") + "]"
        }
        write(line)
    }

    private static func write(_ line: String) {
        let path = Self.path
        lock.lock()
        defer { lock.unlock() }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(
                atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]
            )
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
