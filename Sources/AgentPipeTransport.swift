import Foundation

/// Handing an agent its task through a pipe instead of typing it into a
/// terminal.
///
/// A task is delivered today by pasting text into the agent's pane and then
/// pressing Return from another process. That is why there is paste chunking, a
/// Return retry ladder on each side of the socket, an owed-Return timer for
/// when the two halves disagree, and a reply header scraped back out of the
/// rendered screen. None of it is about agents; all of it is about the terminal
/// being the transport.
///
/// Claude also reads NDJSON on stdin (`--input-format stream-json`) and answers
/// in NDJSON on stdout, with `--replay-user-messages` echoing each message back
/// as a receipt. Measured on 2.1.220: one process takes turn after turn, keeps
/// its context, and marks the end of each with `{"type":"result"}`.
/// See `docs/spike/agent-protocol-verify.md`.
///
/// **This is opt-in and claude-only.** The pane path is untouched and remains
/// the default: it is what makes a running agent watchable, and this trades
/// that view for a channel. Turning it on shows raw NDJSON in the pane, because
/// `--print` is not the interactive UI — so this exists to measure that cost
/// honestly, not to replace anything yet.
enum AgentPipeTransport {
    /// Off unless asked for. The pane path is the product; this is an
    /// experiment running beside it.
    static let enabledKey = "agentPipeTransport.enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Only claude has been measured. The others have channels of their own —
    /// codex `app-server`, kiro `acp`, cursor `--resume` — and each speaks a
    /// different vocabulary, so each needs its own adapter and its own
    /// measurement before it is claimed to work.
    static func supports(cli: String) -> Bool {
        cli == "claude"
    }

    static func canDrive(cli: String) -> Bool {
        isEnabled && supports(cli: cli)
    }

    /// Draw the session instead of showing its wire format.
    ///
    /// `--print` is the non-interactive mode, so nothing renders the stream:
    /// the pane fills with NDJSON. Piping stdout through a filter keeps the
    /// pane a terminal and asks for no changes anywhere else, which is why it
    /// is the first thing to try — it prices the rendering work before anyone
    /// commits to owning an agent UI.
    ///
    /// Off means the pane shows the raw events, which is worth being able to
    /// see: the renderer's job is to leave things out, and that is only
    /// checkable against what it left.
    static let renderKey = "agentPipeTransport.render"

    static var rendersOutput: Bool {
        UserDefaults.standard.object(forKey: renderKey) as? Bool ?? true
    }

    /// The filter, found next to the app or in the repo it was built from.
    static func rendererPath(workingDirectory: String) -> String? {
        let name = "scripts/spike/tm-render-claude.py"
        var candidates: [String] = []
        if let res = Bundle.main.resourcePath {
            candidates.append((res as NSString).appendingPathComponent(name))
        }
        candidates.append((workingDirectory as NSString).appendingPathComponent(name))
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    // MARK: - Where the pipe lives

    private static var root: URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("term-mesh-agent-pipes", isDirectory: true)
    }

    /// One FIFO per agent, named after the agent rather than its pane: the
    /// launch command is built before the pane exists, and the name has to be
    /// in it. `agent@team` also reads plainly in a log, which the pane's UUID
    /// does not.
    ///
    /// A hard restart reuses the name, which is why the launch line removes
    /// the file before making it — a FIFO left by a dead pane would otherwise
    /// be indistinguishable from a live one.
    static func fifoPath(agentId: String) -> String {
        let safe = agentId.map { $0.isLetterOrDigitOrSafe ? $0 : "_" }
        return root.appendingPathComponent(String(safe) + ".stdin").path
    }

    static func prepareDirectory() {
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    static func discard(agentId: String) {
        try? FileManager.default.removeItem(atPath: fifoPath(agentId: agentId))
    }

    // MARK: - Launching

    /// The shell line that runs claude with its stdin on a FIFO.
    ///
    /// `exec 3<>"$F"` opens the FIFO for reading *and* writing in the pane's
    /// own shell, which does two things: claude starts immediately rather than
    /// blocking until a writer appears, and it never sees EOF when this side
    /// has nothing queued. Without it the first turn has to race the launch,
    /// and the pipe closes the moment a write finishes.
    ///
    /// `--verbose` is required by claude alongside `--print` and stream-json;
    /// `--replay-user-messages` is what makes delivery verifiable — the message
    /// comes back on stdout, so "the agent has it" stops being an inference
    /// drawn from a paste queue.
    static func launchCommand(
        claudePath: String,
        fifoPath: String,
        model: String,
        instructions: String,
        extraArgs: [String],
        rendererPath: String? = nil
    ) -> String {
        var parts = [
            quoted(claudePath),
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--replay-user-messages",
            "--dangerously-skip-permissions",
        ]
        if !model.isEmpty {
            parts += ["--model", quoted(model)]
        }
        if !instructions.isEmpty {
            parts += ["--append-system-prompt", quoted(instructions)]
        }
        parts += extraArgs.map(quoted)

        let f = quoted(fifoPath)
        var run = parts.joined(separator: " ") + " <&3 2>&1"
        // A copy for this side to read. The pane is a view; a view is not a
        // place to read state back out of, which is the whole lesson of the
        // scrollback detector.
        run += " | tee \(quoted(fifoPath + ".events"))"
        if let rendererPath {
            run += " | /usr/bin/env python3 \(quoted(rendererPath))"
        }
        let chain = [
            "rm -f \(f)",
            "mkdir -p \(quoted((fifoPath as NSString).deletingLastPathComponent))",
            "mkfifo -m 600 \(f)",
            // Hold the write end open here so the reader never blocks or ends.
            "exec 3<>\(f)",
            run,
        ].joined(separator: " && ")

        // Handed back as one command, not a chain, because the caller may
        // prefix it with `exec` — it does exactly that when the agent works in
        // a worktree. `exec` takes only the first word, so `exec rm -f … && …`
        // replaced the pane's shell with `rm`, which did its one job and left.
        // The pane then closed half a second after opening, with the launch it
        // never reached nowhere to be seen.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return "\(quoted(shell)) -c \(quoted(chain))"
    }

    // MARK: - Delivering a turn

    enum DeliveryError: Error, CustomStringConvertible {
        case noPipe(String)
        case writeFailed(String)

        var description: String {
            switch self {
            case .noPipe(let path): return "no pipe at \(path)"
            case .writeFailed(let detail): return "write failed: \(detail)"
            }
        }
    }

    /// Put one user turn on the agent's stdin.
    ///
    /// The text goes as-is. Nothing is flattened — a task carrying newlines
    /// arrives with them, because there is no composer here to submit early on
    /// one. That flattening is the clearest sign of what the terminal path
    /// costs: an instruction is reshaped to survive its own delivery.
    @discardableResult
    static func deliver(text: String, agentId: String) throws -> Int {
        let path = fifoPath(agentId: agentId)
        guard FileManager.default.fileExists(atPath: path) else {
            throw DeliveryError.noPipe(path)
        }
        let payload = try encode(text: text)

        // Non-blocking: the pane holds the FIFO open, so this should not wait —
        // and if that pane has gone, this must fail rather than hang a caller.
        let fd = open(path, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else {
            throw DeliveryError.writeFailed("open errno \(errno)")
        }
        defer { close(fd) }

        var written = 0
        try payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while written < raw.count {
                let n = write(fd, base.advanced(by: written), raw.count - written)
                if n > 0 {
                    written += n
                    continue
                }
                if n < 0, errno == EINTR || errno == EAGAIN {
                    usleep(2_000)
                    continue
                }
                throw DeliveryError.writeFailed("errno \(errno) after \(written)B")
            }
        }
        return written
    }

    /// One NDJSON line in the shape claude's stream-json input expects.
    static func encode(text: String) throws -> Data {
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": text],
        ]
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        return data
    }

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}


private extension Character {
    /// Keeps a FIFO name to characters that need no quoting anywhere it is
    /// printed — a shell line, a log, a path.
    var isLetterOrDigitOrSafe: Bool {
        isLetter || isNumber || self == "-" || self == "." || self == "@"
    }
}
