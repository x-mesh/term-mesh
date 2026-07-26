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
/// The other four CLIs reach the same place by different roads, so they run
/// behind `scripts/spike/tm-agent-bridge.py`, which speaks their protocol and
/// emits claude's events — see `needsBridge`.
///
/// **This is opt-in.** The pane path is untouched and remains the default: it
/// is what makes a running agent watchable, and this trades that view for a
/// channel. What it buys back is measurable — a receipt for every delivery, a
/// stated end to every turn, and a person who can still type into the pane —
/// so this exists to price that trade honestly, not to replace anything yet.
enum AgentPipeTransport {
    /// Off unless asked for. The pane path is the product; this is an
    /// experiment running beside it.
    static let enabledKey = "agentPipeTransport.enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Which CLIs have been measured taking turns this way.
    ///
    /// Claude is one-directional — a line of NDJSON on stdin is the whole
    /// delivery — so it needs nothing but the FIFO. Codex and Kiro are
    /// request/response: `thread/start` hands back an id every later
    /// `turn/start` must carry, `session/new` the same for `session/prompt`.
    /// Delivering a turn means reading the replies, which a one-way pipe
    /// cannot do, so those two run behind a bridge that owns the child's stdio
    /// and speaks for it.
    ///
    /// Cursor and agy are a third shape: no stdio channel at all, and a turn
    /// *is* a process. That reads like the terminal path and is not — the
    /// answer comes back on stdout and the process exiting is the end-of-turn
    /// signal, which is plainer than any of the protocols. What it costs is the
    /// context reloaded every turn and an id that has to be kept: cursor hands
    /// it back in the answer, agy announces it only in its log. Both go behind
    /// the bridge too, so the shape stays the bridge's problem.
    static func supports(cli: String) -> Bool {
        cli == "claude" || needsBridge(cli: cli)
    }

    /// CLIs the bridge has to run on the agent's behalf — either because their
    /// protocol must be spoken rather than written to, or because they have no
    /// channel to write to at all.
    static func needsBridge(cli: String) -> Bool {
        ["codex", "kiro", "cursor", "agy"].contains(cli)
    }

    /// CLIs that exist only on the pipe.
    ///
    /// The pane path has no launch line for these: it runs a CLI's interactive
    /// UI and takes its turns by typing, and a turn-per-process CLI has neither
    /// to offer. Selecting one as an agent's CLI therefore depends on the
    /// transport, which is why it is asked here rather than assumed.
    static func isPipeOnly(cli: String) -> Bool {
        cli == "cursor" || cli == "agy"
    }

    /// The bridge, found next to the app or in the repo it was built from.
    static func bridgePath(workingDirectory: String) -> String? {
        script(named: "scripts/spike/tm-agent-bridge.py",
               workingDirectory: workingDirectory)
    }

    static func canDrive(cli: String) -> Bool {
        isEnabled && supports(cli: cli)
    }

    // MARK: - Who is actually on a pipe

    /// Agents whose pane was launched on the pipe, recorded when the launch
    /// line is built.
    ///
    /// The FIFO's existence looks like the same answer and is not: the pane
    /// creates it, so there is a window after launch where an agent is on the
    /// pipe and the file is not there yet. Delivery used to read that window as
    /// "not on a pipe" and fall back to typing — into a `--print` process,
    /// which reads its stdin and never the terminal. The text went nowhere and
    /// the send reported success. An agent's transport is decided when its pane
    /// is launched, so that is where it is recorded.
    private static let drivenLock = NSLock()
    private static var driven: Set<String> = []

    static func markDriven(agentId: String) {
        drivenLock.lock(); defer { drivenLock.unlock() }
        driven.insert(agentId)
    }

    static func isDriven(agentId: String) -> Bool {
        drivenLock.lock(); defer { drivenLock.unlock() }
        return driven.contains(agentId)
    }

    static func forgetDriven(agentId: String) {
        drivenLock.lock(); defer { drivenLock.unlock() }
        driven.remove(agentId)
    }

    /// Drop the terminal entirely and hold the agent in a native pane.
    ///
    /// Measured: `claude --print` with plain pipes — no PTY, no shell, no FIFO
    /// — takes turn after turn and keeps its context. Everything
    /// terminal-shaped below exists because the *host* is a terminal, not
    /// because the agent needs one, so with a native pane it all goes: the FIFO
    /// becomes `stdin.write`, `/dev/tty` becomes a text field, and the ANSI
    /// renderer becomes a view over a model.
    ///
    /// What that buys is what a grid of cells cannot hold. The events say what
    /// each part *is* — this is a tool call, this is its result, this failed,
    /// this turn cost $0.31 — so a tool result can be folded, an answer stays
    /// selectable, and a turn's facts are laid out rather than printed.
    ///
    /// Claude only, and off by default: the pane path is the product.
    static let nativePanelKey = "agentPipeTransport.nativePanel"

    static var usesNativePanel: Bool {
        isEnabled && UserDefaults.standard.bool(forKey: nativePanelKey)
    }

    /// Which CLIs can be held without a terminal. Only the one measured that
    /// way — the others go through the bridge, which is a process this side
    /// would still have to host, and that is a separate question.
    static func canHoldNatively(cli: String) -> Bool {
        usesNativePanel && cli == "claude"
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
        script(named: "scripts/spike/tm-render-claude.py",
               workingDirectory: workingDirectory)
    }

    private static func script(named name: String, workingDirectory: String) -> String? {
        var candidates: [String] = []
        if let res = Bundle.main.resourcePath {
            candidates.append((res as NSString).appendingPathComponent(name))
        }
        candidates.append((workingDirectory as NSString).appendingPathComponent(name))
        return candidates.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    /// The launch line for a CLI that has to be spoken to rather than written
    /// at. The bridge holds the FIFO, the protocol and the normalising, and
    /// emits claude's event shape — so everything upstream, including the
    /// renderer and the completion watcher, stays single-vocabulary.
    static func bridgeLaunchCommand(
        cli: String,
        fifoPath: String,
        model: String,
        bridgePath: String,
        rendererPath: String?,
        workingDirectory: String
    ) -> String {
        var run = "/usr/bin/env python3 \(quoted(bridgePath))"
            + " --cli \(quoted(cli))"
            + " --fifo \(quoted(fifoPath))"
            + " --events \(quoted(fifoPath + ".events"))"
            + " --cwd \(quoted(workingDirectory))"
        if !model.isEmpty { run += " --model \(quoted(model))" }
        let f = quoted(fifoPath)
        if let rendererPath {
            run += " 2>&1 | /usr/bin/env python3 \(quoted(rendererPath)) --fifo \(f)"
        }
        let chain = [
            "rm -f \(f)",
            "mkdir -p \(quoted((fifoPath as NSString).deletingLastPathComponent))",
            "mkfifo -m 600 \(f)",
            run,
        ].joined(separator: " && ")
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return "\(quoted(shell)) -c \(quoted(chain))"
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
        forgetDriven(agentId: agentId)
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
            // The renderer also takes the keyboard: on the typing path a human
            // could always talk to the agent mid-session, and the pipe removes
            // that unless something reads the terminal.
            run += " | /usr/bin/env python3 \(quoted(rendererPath)) --fifo \(f)"
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

    /// How long a pipe-driven agent may still be starting up.
    ///
    /// Measured: a team's first instruction goes out about 200ms after the pane
    /// is asked for, and the pane needs roughly a second to reach its `mkfifo`.
    /// Waiting is what the typing path got for free — keystrokes sit in the
    /// PTY buffer until something reads them.
    private static let pipeReadyTimeout: TimeInterval = 5

    /// Put one user turn on the agent's stdin.
    ///
    /// The text goes as-is. Nothing is flattened — a task carrying newlines
    /// arrives with them, because there is no composer here to submit early on
    /// one. That flattening is the clearest sign of what the terminal path
    /// costs: an instruction is reshaped to survive its own delivery.
    @discardableResult
    static func deliver(text: String, agentId: String) throws -> Int {
        let path = fifoPath(agentId: agentId)
        let payload = try encode(text: text)

        // Non-blocking, so the caller is never hung by a pane that has gone —
        // but a pane that has not arrived *yet* is a different thing, and the
        // two look alike for the first second of a team's life.
        //
        // A team's first instruction goes out while the panes are still coming
        // up, and readiness has two steps, not one: the pane creates the FIFO,
        // then the process behind it opens the read end. Opening for writing in
        // between gives ENXIO — "no reader" — which is a wait, not a failure.
        // Waiting is what the terminal gave for free: keystrokes sit in the PTY
        // buffer until something reads them.
        let deadline = Date().addingTimeInterval(pipeReadyTimeout)
        var fd: Int32 = -1
        while true {
            fd = open(path, O_WRONLY | O_NONBLOCK)
            if fd >= 0 { break }
            let failure = errno
            guard failure == ENXIO || failure == ENOENT, Date() < deadline else {
                throw failure == ENOENT
                    ? DeliveryError.noPipe(path)
                    : DeliveryError.writeFailed("open errno \(failure)")
            }
            usleep(50_000)
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
