//  PeerHostDoctor: connection test + remote install + diagnosis for
//  saved host profiles (the editor sheet's "Test" / "Install" buttons).
//
//  Security posture matches PeerSocketProber: every remote command is a
//  FIXED string (zero interpolation — user input never reaches the
//  remote shell), the target rides behind `--` as a validated positional
//  argv element, and optional port/identity go through the same
//  validators as the tunnel.

import Foundation

enum PeerHostTestResult: Equatable {
    /// SSH tunnel + peer protocol handshake both succeeded.
    case ok(socketPath: String, hostCLIBinDirs: [String])
    /// SSH reached the host but no live peer socket was found —
    /// term-meshd is likely not installed/running. Install is offered.
    case daemonMissing
    /// A socket file exists, but the SSH forward or peer protocol handshake
    /// could not reach a live compatible server. Kept separate from
    /// `sshFailed` so a stale socket never produces a false-green result.
    case relayFailed(socketPath: String, message: String)
    /// SSH itself failed (auth, DNS, timeout…).
    case sshFailed(String)
}

/// Which process is actually serving this peer. The version-probe
/// unification principle is "ask whoever is serving the peer, not
/// whichever binary the Linux install script would have dropped": a
/// Linux host runs the term-meshd systemd service, but a Mac host
/// serves peers from the term-mesh.app itself — there is no separate
/// daemon binary there, so a `command -v term-meshd` miss on a Mac is
/// not "not installed", it's "wrong question".
enum PeerHostKind: String, Equatable {
    case daemon
    case app
}

/// What the agent-notification stack looks like on a remote host: the
/// two in-band scripts, whether Claude's hooks reference them, and the
/// prerequisites the stack leans on. One probe fills all of it — the
/// point is that the editor sheet can say exactly which piece is
/// missing instead of the user reverse-engineering it over ssh.
struct PeerAgentStackStatus: Equatable {
    /// Where agent-notify.sh was found, nil = not installed.
    var notifyPath: String?
    /// Where agent-title.sh was found, nil = not installed.
    var titlePath: String?
    /// ~/.claude/settings.json references agent-notify.sh somewhere.
    var hooksWired = false
    /// ~/.claude/settings.json exists at all (false also covers "claude
    /// never ran here").
    var hasSettingsFile = false
    /// python3 present — the JSON leg of agent-notify.sh (the one Claude
    /// hooks actually take) needs it, and so does the hook wiring.
    var hasPython3 = false
    /// A claude binary is on PATH — hook wiring only matters when it is.
    var hasClaude = false

    var scriptsInstalled: Bool { notifyPath != nil && titlePath != nil }
    /// Hooks count as complete when wired, or when there is no claude on
    /// the host for them to serve. When claude IS present, python3 is a
    /// hard requirement too: a Claude hook runs detached, so the only
    /// path from it to the terminal is agent-notify.sh's terminalSequence
    /// JSON leg, which is python3. Without it the hooks are wired but
    /// silent — reporting that as "ready" is the exact false-green this
    /// probe exists to prevent.
    var isComplete: Bool {
        guard scriptsInstalled else { return false }
        guard hasClaude else { return true }
        return hooksWired && hasPython3
    }
}

enum PeerHostDoctor {
    /// Pinned to the repo's install entrypoint. Fixed constant — never
    /// built from user input.
    static let installCommand =
        "curl -fsSL https://raw.githubusercontent.com/x-mesh/term-mesh/main/scripts/install-linux.sh | bash"

    /// Fixed diagnosis command: service state + recent journal lines.
    /// No single quotes in the body (same constraint as the prober's
    /// remoteCommand — the sh -c wrapper must survive fish/csh).
    ///
    /// Reports BOTH systemd scopes. `install-linux.sh` installs a system
    /// unit when it runs as root and a `--user` unit otherwise, so asking
    /// only about `--user` described a root-installed host as dead while
    /// it was serving happily — and then quoted whatever the journal
    /// happened to end with, which is usually systemd's benign
    /// "Consumed ... CPU time" accounting line for the previous run.
    /// The journal tail comes from whichever scope is actually active.
    static let diagnoseCommand =
        #"sh -c 'u=$(systemctl --user is-active term-meshd 2>/dev/null); s=$(systemctl is-active term-meshd 2>/dev/null); echo "service: user=${u:-none} system=${s:-none}"; if [ "$s" = active ]; then journalctl -u term-meshd --no-pager -n 6 2>&1 | tail -n 6; else journalctl --user -u term-meshd --no-pager -n 6 2>&1 | tail -n 6; fi'"#

    /// Sentinel exit code for "no term-meshd binary found" — distinct
    /// from PeerSocketProber.noSocketExitCode (43) so the two probes'
    /// failure spaces never collide on the same wire.
    static let versionMissingExitCode: Int32 = 44

    /// Fixed, OS-aware version-probe command — asks whoever actually
    /// serves the peer on this host rather than always looking for
    /// term-meshd:
    /// - Darwin (Mac host): the peer is served by the term-mesh.app
    ///   bundle itself, so this reads its `CFBundleShortVersionString`
    ///   straight out of Info.plist and prints `term-mesh-app X.Y.Z`.
    /// - anything else (Linux host): resolves term-meshd off PATH
    ///   first, falling back to the installer's default
    ///   `~/.local/bin/term-meshd` (a non-login ssh session often has a
    ///   bare PATH that skips it), then prints `term-meshd X.Y.Z` via
    ///   `--version`.
    /// Either branch exits with `versionMissingExitCode` when it can't
    /// determine a version. No single quotes in the body (same sh -c
    /// '…' wrapper constraint as remoteCommand/diagnoseCommand).
    static let versionProbeCommand =
        #"sh -c 'if [ "$(uname -s)" = Darwin ]; then v=$(/usr/bin/defaults read /Applications/term-mesh.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null) && [ -n "$v" ] && echo "term-mesh-app $v" || exit 44; else b=$(command -v term-meshd 2>/dev/null); [ -x "$b" ] || b="$HOME/.local/bin/term-meshd"; [ -x "$b" ] && "$b" --version || exit 44; fi'"#

    /// One term-mesh binary a host would run, and which copy it is.
    struct BinaryEntry: Equatable {
        var path: String
        var version: String
    }

    /// What a host would actually execute, and what else is lying around.
    struct BinaryInventory: Equatable {
        var appVersion: String?
        /// The `tm-agent` an agent launched here would get.
        var cli: BinaryEntry?
        /// Other `tm-agent` copies on the same PATH, in search order after
        /// the winner. A different version here is the drift.
        var cliShadowed: [BinaryEntry] = []
        var daemon: BinaryEntry?
        var daemonShadowed: [BinaryEntry] = []
    }

    /// Fixed inventory probe: which term-mesh binaries this host would run,
    /// and every other copy of them on the same PATH.
    ///
    /// Searches the app's own launch PATH — `RemoteShellPath.binDirs` — not
    /// the login shell's. That distinction is the entire point.
    /// `versionProbeCommand` asks the login shell, and a host can answer
    /// 0.170.1 there while every agent launched on it runs a 0.167.0 copy out
    /// of `$HOME/.local/bin`, because that directory is searched first. A
    /// whole fleet drifted that way with nothing pointing at it: the failure
    /// surfaced as a leader whose every command died with an error naming a
    /// symbol the current tree no longer contains.
    ///
    /// Emits `key=path|version` lines and always exits 0 — absence is data,
    /// not an error. No single quotes in the body (sh -c '…' wrapper
    /// constraint, same as remoteCommand/diagnoseCommand).
    static var binaryInventoryCommand: String {
        // Built from binDirs rather than repeated here: a probe that searches
        // a different PATH than the launcher answers a different question.
        let path = RemoteShellPath.binDirs
            .map { dir in
                dir.hasPrefix("$HOME/") ? "\"$HOME/\(dir.dropFirst(6))\"" : dir
            }
            .joined(separator: ":")
        let body = "export PATH=\(path):\"$PATH\"; "
            + #"if [ "$(uname -s)" = Darwin ]; then v=$(/usr/bin/defaults read /Applications/term-mesh.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null); [ -n "$v" ] && echo "app=$v"; fi; "#
            + #"for b in tm-agent term-meshd; do first=1; seen=""; for d in $(echo "$PATH" | tr : " "); do p="$d/$b"; case " $seen " in *" $p "*) continue ;; esac; if [ -x "$p" ]; then seen="$seen $p"; v=$("$p" --version 2>/dev/null | head -1); if [ "$first" = 1 ]; then echo "$b=$p|$v"; first=0; else echo "$b.shadowed=$p|$v"; fi; fi; done; done; exit 0"#
        return "sh -c '\(body)'"
    }

    /// Fixed probe for the agent-notification stack: script locations
    /// (installer default first, then the manual /usr/local/bin), hook
    /// wiring (a grep-level check — the wiring itself is idempotent, so
    /// "referenced at all" is enough to answer install-or-not), and the
    /// two prerequisites. Exit 0 always; absence is data, not an error.
    /// No single quotes in the body (sh -c wrapper constraint, same as
    /// remoteCommand/diagnoseCommand).
    static let agentStackProbeCommand =
        #"sh -c 'for d in "$HOME/.local/bin" /usr/local/bin; do if [ -x "$d/agent-notify.sh" ]; then echo "notify=$d/agent-notify.sh"; break; fi; done; for d in "$HOME/.local/bin" /usr/local/bin; do if [ -x "$d/agent-title.sh" ]; then echo "title=$d/agent-title.sh"; break; fi; done; s="$HOME/.claude/settings.json"; if [ -f "$s" ]; then echo settings=ok; if grep -q agent-notify.sh "$s" 2>/dev/null; then echo hooks=wired; fi; fi; command -v python3 >/dev/null 2>&1 && echo python3=ok; command -v claude >/dev/null 2>&1 && echo claude=ok; exit 0'"#

    /// Upload targets for `installAgentStack`. `~/.local/bin` rather
    /// than /usr/local/bin: it needs no root on any host, and the hook
    /// command embeds the same expansion so the two always agree.
    static let agentUploadNotifyCommand =
        #"sh -c 'mkdir -p "$HOME/.local/bin" && cat > "$HOME/.local/bin/agent-notify.sh" && chmod 755 "$HOME/.local/bin/agent-notify.sh"'"#
    static let agentUploadTitleCommand =
        #"sh -c 'mkdir -p "$HOME/.local/bin" && cat > "$HOME/.local/bin/agent-title.sh" && chmod 755 "$HOME/.local/bin/agent-title.sh"'"#

    /// The hook-wiring program, delivered over stdin to a fixed
    /// `python3 -` — stdin sidesteps every quoting hazard a heredoc
    /// inside an sh -c '…' wrapper would reintroduce. Mirrors
    /// scripts/agent-remote-deploy.sh: idempotent (an existing
    /// agent-notify.sh reference is updated, not duplicated) and backed
    /// up with a timestamp before writing.
    static let agentWireHooksCommand = #"sh -c 'python3 -'"#
    static let agentWireHooksProgram = """
    import json, os, shutil, sys, time
    path = os.path.expanduser("~/.claude/settings.json")
    notify = os.path.expanduser("~/.local/bin/agent-notify.sh") + " --title \\"\u{2733} Claude\\""
    try:
        with open(path) as f:
            settings = json.load(f)
    except FileNotFoundError:
        settings = {}
    except json.JSONDecodeError as e:
        # Overwriting an unparseable settings.json would wipe hand edits;
        # a non-zero exit surfaces this as a stage message, not a raw
        # traceback (runRemote turns stderr + exit!=0 into the error).
        sys.stderr.write("existing settings.json is not valid JSON: " + str(e))
        sys.exit(1)
    hooks = settings.setdefault("hooks", {})
    def wire(event, command):
        entries = hooks.setdefault(event, [])
        for group in entries:
            for hook in group.get("hooks", []):
                if "agent-notify.sh" in hook.get("command", ""):
                    hook["command"] = command
                    return event + ": updated"
        entries.append({"hooks": [{"type": "command", "command": command, "timeout": 5}]})
        return event + ": added"
    changes = [wire("Notification", notify), wire("Stop", notify + " finished responding")]
    if os.path.exists(path):
        backup = path + ".bak." + time.strftime("%Y%m%d-%H%M%S")
        shutil.copy2(path, backup)
        print("backup: " + backup)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
    print("; ".join(changes))
    """

    /// Detached-path smoke test: no tty on either side of this ssh, so a
    /// healthy agent-notify.sh must answer with the terminalSequence
    /// JSON — the exact leg a Claude hook takes. Payload rides stdin.
    static let agentSmokeCommand =
        #"sh -c '"$HOME/.local/bin/agent-notify.sh" --title doctor'"#
    static let agentSmokePayload = #"{"message":"peer doctor check"}"#

    /// Probes the agent-notification stack. nil = the probe itself
    /// failed (ssh error/timeout) — distinct from "reachable but
    /// nothing installed", which comes back as an empty status.
    static func checkAgentStack(
        sshTarget: String,
        port: Int?,
        identityFile: String?
    ) async -> PeerAgentStackStatus? {
        guard let output = try? await runRemote(
            sshTarget: sshTarget, port: port, identityFile: identityFile,
            command: agentStackProbeCommand, timeoutSeconds: 15
        ) else { return nil }
        return parseAgentStack(from: output)
    }

    /// Pure parse of the probe's key=value lines — unit-testable without
    /// ssh, and tolerant of MOTD noise the same way the version parser
    /// is (unmatched lines are simply ignored).
    static func parseAgentStack(from output: String) -> PeerAgentStackStatus {
        var status = PeerAgentStackStatus()
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("notify=") {
                status.notifyPath = String(line.dropFirst("notify=".count))
            } else if line.hasPrefix("title=") {
                status.titlePath = String(line.dropFirst("title=".count))
            } else if line == "settings=ok" {
                status.hasSettingsFile = true
            } else if line == "hooks=wired" {
                status.hooksWired = true
            } else if line == "python3=ok" {
                status.hasPython3 = true
            } else if line == "claude=ok" {
                status.hasClaude = true
            }
        }
        return status
    }

    /// Installs the agent-notification stack: uploads both scripts from
    /// the app bundle (content over stdin — nothing is interpolated into
    /// a remote command), wires Claude's hooks when the host has both
    /// python3 and claude, then smoke-tests the detached emission path.
    /// Throws with a stage-specific message on the first failure.
    static func installAgentStack(
        sshTarget: String,
        port: Int?,
        identityFile: String?,
        status: PeerAgentStackStatus
    ) async throws -> String {
        RemoteWorkLog.infoOffMain("Installing the agent notification stack on \(sshTarget)")
        guard let scriptsDir = Bundle.main.resourceURL?
            .appendingPathComponent("scripts", isDirectory: true) else {
            RemoteWorkLog.infoOffMain("Agent stack install failed: the app bundle has no scripts directory")
            throw PeerSocketProbeError.spawnFailed("app bundle has no scripts directory")
        }
        let uploads: [(command: String, file: String)] = [
            (agentUploadNotifyCommand, "agent-notify.sh"),
            (agentUploadTitleCommand, "agent-title.sh"),
        ]
        // Re-upload even when present: install doubles as update, and the
        // scripts are tiny. Order keeps agent-notify.sh (the one the
        // smoke test needs) first.
        for upload in uploads {
            let local = scriptsDir.appendingPathComponent(upload.file)
            guard let content = try? Data(contentsOf: local) else {
                throw PeerSocketProbeError.spawnFailed(
                    "bundled \(upload.file) missing — rebuild the app")
            }
            _ = try await runRemote(
                sshTarget: sshTarget, port: port, identityFile: identityFile,
                command: upload.command, timeoutSeconds: 20, input: content
            )
        }

        // The uploads already succeeded and are useful on their own
        // (agent-title.sh names the pane; agent-notify.sh notifies over
        // /dev/tty in an interactive session), so a missing python3 is
        // reported as a partial result, not thrown — throwing after the
        // side effect landed would flag a real install as pure failure
        // and every retry would repeat the same upload. The re-probe
        // then shows the stack as incomplete (isComplete requires
        // python3 when claude is present), which is the honest state.
        var notes: [String] = ["scripts installed to ~/.local/bin"]
        if status.hasClaude {
            guard status.hasPython3 else {
                // A partial install that reads as success is the worst outcome
                // here: the scripts are there, so the host looks equipped, and
                // the reason no notification ever arrives is a missing python3
                // nobody was told about.
                RemoteWorkLog.infoOffMain(
                    "Agent stack partly installed on \(sshTarget): scripts are in ~/.local/bin, but python3 is missing so Claude's hooks were NOT wired"
                )
                return (notes + ["python3 missing — Claude hooks not wired; install python3 and re-run"])
                    .joined(separator: "; ")
            }
            let wired = try await runRemote(
                sshTarget: sshTarget, port: port, identityFile: identityFile,
                command: agentWireHooksCommand, timeoutSeconds: 20,
                input: Data(agentWireHooksProgram.utf8)
            )
            notes.append(wired.trimmingCharacters(in: .whitespacesAndNewlines))
            notes.append("restart the remote claude to load the hooks")
        }

        if status.hasPython3 {
            let smoke = try await runRemote(
                sshTarget: sshTarget, port: port, identityFile: identityFile,
                command: agentSmokeCommand, timeoutSeconds: 15,
                input: Data(agentSmokePayload.utf8)
            )
            guard smoke.contains("terminalSequence") else {
                RemoteWorkLog.infoOffMain(
                    "Agent stack smoke test failed on \(sshTarget): agent-notify.sh answered \(String(smoke.prefix(120)))"
                )
                throw PeerSocketProbeError.spawnFailed(
                    "smoke test failed — expected terminalSequence JSON, got: \(String(smoke.prefix(120)))")
            }
        }
        let summary = notes.joined(separator: "; ")
        RemoteWorkLog.infoOffMain("Agent stack installed on \(sshTarget): \(summary)")
        return summary
    }

    /// Test the connection path an actual remote pane uses:
    /// SSH → remote socket → local Unix-socket forward → peer handshake.
    ///
    /// Socket discovery alone is intentionally not considered success.
    /// `[ -S ]` also matches a stale filesystem entry; only a completed
    /// protocol handshake proves that the relay route is usable.
    static func test(
        sshTarget: String,
        port: Int?,
        identityFile: String?,
        remoteSocket: String? = nil
    ) async -> PeerHostTestResult {
        let socketPath: String
        do {
            if let explicit = remoteSocket?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !explicit.isEmpty {
                try PeerSSHTunnel.validateRemoteSockPath(explicit)
                // A custom socket may sit outside every auto-detect
                // candidate. Run discovery only as an SSH reachability
                // check: `noSocketFound` still proves SSH worked, while
                // auth/DNS/timeout failures remain correctly classified
                // as SSH failures instead of relay failures.
                do {
                    _ = try await PeerSocketProber.probe(
                        sshTarget: sshTarget, port: port,
                        identityFile: identityFile
                    )
                } catch PeerSocketProbeError.noSocketFound {
                    // Expected for a valid custom path.
                }
                socketPath = explicit
            } else {
                socketPath = try await PeerSocketProber.probe(
                    sshTarget: sshTarget, port: port, identityFile: identityFile
                )
            }
        } catch PeerSocketProbeError.noSocketFound {
            return .daemonMissing
        } catch {
            return .sshFailed(String(describing: error))
        }

        let tunnel = PeerSSHTunnel(
            sshTarget: sshTarget,
            remoteSockPath: socketPath,
            port: port,
            identityFile: identityFile
        )
        do {
            try await tunnel.start()
            let connection = try await PeerRelaySession.connect(
                hostSockPath: tunnel.localSockPath
            )
            await connection.cancel()
            tunnel.stop()
            RemoteWorkLog.debugOffMain(
                "Relay health check passed for \(sshTarget) via \(socketPath)"
            )
            return .ok(
                socketPath: socketPath,
                hostCLIBinDirs: connection.hostCLIBinDirs
            )
        } catch {
            tunnel.stop()
            let message = String(describing: error)
            RemoteWorkLog.infoOffMain(
                "Relay health check failed for \(sshTarget) via \(socketPath): \(message)"
            )
            return .relayFailed(socketPath: socketPath, message: message)
        }
    }

    /// Run the pinned install script on the host. Returns the last log
    /// lines on success; throws with stderr on failure. 3-minute budget
    /// (download + systemd setup on a slow box).
    static func install(
        sshTarget: String,
        port: Int?,
        identityFile: String?
    ) async throws -> String {
        try await runRemote(
            sshTarget: sshTarget, port: port, identityFile: identityFile,
            command: installCommand, timeoutSeconds: 180
        )
    }

    /// Pure parse of `binaryInventoryCommand` output. Unknown lines are
    /// ignored rather than failing the probe: this is diagnostics, and a
    /// future key must not turn the whole report into an error.
    static func parseBinaryInventory(_ stdout: String) -> BinaryInventory {
        var inventory = BinaryInventory()
        for line in stdout.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<separator])
            let value = String(trimmed[trimmed.index(after: separator)...])
            if key == "app" {
                inventory.appVersion = value.isEmpty ? nil : value
                continue
            }
            // `path|version`. A binary that ran but printed nothing still
            // gets an entry — where it is matters even when it won't say
            // what it is.
            let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard let path = parts.first, !path.isEmpty else { continue }
            let entry = BinaryEntry(
                path: String(path),
                version: parts.count > 1 ? String(parts[1]) : ""
            )
            switch key {
            case "tm-agent": inventory.cli = entry
            case "tm-agent.shadowed": inventory.cliShadowed.append(entry)
            case "term-meshd": inventory.daemon = entry
            case "term-meshd.shadowed": inventory.daemonShadowed.append(entry)
            default: continue
            }
        }
        return inventory
    }

    /// What is worth saying out loud about an inventory, or nothing.
    ///
    /// Deliberately quiet: a host whose binaries agree produces no lines. A
    /// warning that appears on healthy hosts is one people stop reading, and
    /// this one has to survive being read months from now, once.
    static func inventoryWarnings(_ inventory: BinaryInventory) -> [String] {
        var warnings: [String] = []
        // A copy earlier in PATH beats a newer one later, so the version that
        // matters is the one that wins — and the loser is what makes it look
        // like the host is up to date when it is not.
        for (name, winner, shadowed) in [
            ("tm-agent", inventory.cli, inventory.cliShadowed),
            ("term-meshd", inventory.daemon, inventory.daemonShadowed),
        ] {
            guard let winner else { continue }
            for other in shadowed where other.version != winner.version {
                warnings.append(
                    "\(name): this host runs \(winner.path) (\(winner.version)) — "
                        + "\(other.path) (\(other.version)) is shadowed by it."
                )
            }
        }
        if let appVersion = inventory.appVersion,
           let cli = inventory.cli,
           !cli.version.isEmpty,
           !cli.version.contains(appVersion) {
            warnings.append(
                "tm-agent here is \(cli.version) but the app is \(appVersion) — "
                    + "a leader on this host drives its team through the older one."
            )
        }
        return warnings
    }

    /// Ask a host what it would actually run. Never throws; an unreachable
    /// host simply has nothing to report.
    static func binaryInventory(
        sshTarget: String,
        port: Int?,
        identityFile: String?
    ) async -> BinaryInventory? {
        guard let output = try? await runRemote(
            sshTarget: sshTarget, port: port, identityFile: identityFile,
            command: binaryInventoryCommand, timeoutSeconds: 20
        ) else { return nil }
        return parseBinaryInventory(output)
    }

    /// Post-install health check: service state + journal tail. Used
    /// when a test still fails after install (e.g. a binary built
    /// against a newer glibc than the host ships).
    static func diagnose(
        sshTarget: String,
        port: Int?,
        identityFile: String?
    ) async -> String {
        (try? await runRemote(
            sshTarget: sshTarget, port: port, identityFile: identityFile,
            command: diagnoseCommand, timeoutSeconds: 20
        )) ?? "diagnosis unavailable"
    }

    /// Probes the remote host's version — term-meshd on Linux, the
    /// term-mesh.app bundle on a Mac (see `PeerHostKind`). Covers the
    /// "daemon down" case that a live-socket probe cannot: this shells
    /// out directly rather than going through the peer socket. Returns
    /// nil whenever no reliable version could be read — nothing found
    /// (exit 44), ssh/timeout failure, or output that doesn't match
    /// either expected shape. Never throws; the caller only cares about
    /// "known version" vs "unknown".
    static func checkVersion(
        sshTarget: String,
        port: Int?,
        identityFile: String?
    ) async -> (version: String, hostKind: PeerHostKind)? {
        do {
            let output = try await runRemote(
                sshTarget: sshTarget, port: port, identityFile: identityFile,
                command: versionProbeCommand, timeoutSeconds: 15
            )
            return classifyVersionOutput(exitCode: 0, timedOut: false, stdout: output)
        } catch PeerSocketProbeError.sshFailed(let exit, _) {
            return classifyVersionOutput(exitCode: exit, timedOut: false, stdout: "")
        } catch PeerSocketProbeError.timedOut {
            return classifyVersionOutput(exitCode: -1, timedOut: true, stdout: "")
        } catch {
            return nil
        }
    }

    /// Pure classification of a finished version-probe run — mirrors
    /// PeerSocketProber.classify so the exit-code handling (in
    /// particular versionMissingExitCode → nil) and the output parsing
    /// are unit-testable without spawning ssh.
    static func classifyVersionOutput(
        exitCode: Int32,
        timedOut: Bool,
        stdout: String
    ) -> (version: String, hostKind: PeerHostKind)? {
        guard !timedOut, exitCode == 0 else { return nil }
        return parseHostVersionLine(from: stdout)
    }

    /// Extracts (version, hostKind) from whichever probe line matched —
    /// `term-meshd X.Y.Z` (Linux daemon) or `term-mesh-app X.Y.Z` (Mac
    /// app bundle). A non-login shell can still print MOTD/banner text
    /// ahead of the real output, so this scans every line and keeps the
    /// LAST match rather than the first, regardless of which of the two
    /// prefixes it came from. Returns nil when no line matches either.
    static func parseHostVersionLine(from output: String) -> (version: String, hostKind: PeerHostKind)? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^(term-meshd|term-mesh-app)\s+(\S+)\s*$"#
        ) else { return nil }
        var found: (version: String, hostKind: PeerHostKind)?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let kindRange = Range(match.range(at: 1), in: line),
                  let versionRange = Range(match.range(at: 2), in: line) else { continue }
            let kind: PeerHostKind = line[kindRange] == "term-meshd" ? .daemon : .app
            found = (String(line[versionRange]), kind)
        }
        return found
    }

    /// Back-compat, daemon-only view of `parseHostVersionLine` — kept
    /// for call sites (and existing tests) that only ever fed it Linux
    /// `term-meshd X.Y.Z` output and don't care about `hostKind`.
    static func parseVersionLine(from output: String) -> String? {
        parseHostVersionLine(from: output)?.version
    }

    /// Compact human line out of a diagnosis dump — surfaces the known
    /// failure signatures first, else the last journal line.
    static func summarizeDiagnosis(_ raw: String) -> String {
        let lines = raw.split(separator: "\n").map(String.init)
        if let glibc = lines.first(where: { $0.contains("GLIBC_") }) {
            return "binary incompatible with this host's glibc — " +
                (glibc.split(separator: ":").last.map(String.init) ?? glibc)
                .trimmingCharacters(in: .whitespaces)
        }
        if let failed = lines.first(where: { $0.contains("Failed with result") }) {
            return failed.trimmingCharacters(in: .whitespaces)
        }
        return lines.last?.trimmingCharacters(in: .whitespaces) ?? raw
    }

    // MARK: - Fixed-command ssh runner

    private static func runRemote(
        sshTarget: String,
        port: Int?,
        identityFile: String?,
        command: String,
        timeoutSeconds: TimeInterval,
        input: Data? = nil
    ) async throws -> String {
        try PeerSSHTunnel.validateSshTarget(sshTarget)
        if let port { try PeerSSHTunnel.validatePort(port) }
        if let identityFile { try PeerSSHTunnel.validateIdentityFile(identityFile) }
        var authArgs: [String] = []
        if let port { authArgs += ["-p", String(port)] }
        if let identityFile {
            authArgs += ["-i", (identityFile as NSString).expandingTildeInPath]
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-T", "-x",
            "-S", "none",
            "-o", "ControlMaster=no",
            "-o", "ControlPersist=no",
            "-o", "LogLevel=ERROR",
            "-o", "ClearAllForwardings=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "BatchMode=no",
        ] + authArgs + [
            "--",
            sshTarget,
            command,
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        // Content upload rides stdin (script bodies, the hook-wiring
        // program) — never interpolated into the remote command line, so
        // the fixed-command security posture holds for installs too.
        let inPipe: Pipe? = input.map { _ in Pipe() }
        if let inPipe {
            proc.standardInput = inPipe
        } else {
            proc.standardInput = nil
        }

        do {
            try proc.run()
        } catch {
            throw PeerSocketProbeError.spawnFailed(String(describing: error))
        }
        if let inPipe, let input {
            DispatchQueue.global(qos: .utility).async {
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        defer { if proc.isRunning { kill(proc.processIdentifier, SIGKILL) } }

        // Drain pipes concurrently — install output exceeds pipe capacity,
        // so reading only after exit could deadlock the child.
        async let outData = readAll(outPipe)
        async let errData = readAll(errPipe)

        var timedOut = false
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while proc.isRunning {
            if Date() > deadline {
                timedOut = true
                proc.terminate()
                // ssh can ignore SIGTERM outright (documented hazard —
                // see PeerSocketProber.probe's identical escalation).
                // Without this, a stuck child never closes its pipe
                // fds, so the `await outData`/`await errData` below
                // would block on EOF forever instead of honoring
                // timeoutSeconds — the top-of-function defer can't help
                // either, since it only runs once this call returns.
                if await !waitForExit(proc, timeout: 2.0) {
                    kill(proc.processIdentifier, SIGKILL)
                    _ = await waitForExit(proc, timeout: 1.0)
                }
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        let stdout = String(data: await outData, encoding: .utf8) ?? ""
        let stderr = String(data: await errData, encoding: .utf8) ?? ""
        if timedOut { throw PeerSocketProbeError.timedOut }
        let exit = proc.isRunning ? Int32(-1) : proc.terminationStatus
        guard exit == 0 else {
            throw PeerSocketProbeError.sshFailed(
                exit: exit,
                stderr: stderr.isEmpty ? String(stdout.suffix(300)) : String(stderr.suffix(300))
            )
        }
        return stdout
    }

    private static func readAll(_ pipe: Pipe) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }

    /// Async twin of PeerSSHTunnel.waitForExit / PeerSocketProber's
    /// private helper of the same name — polls `isRunning` without
    /// blocking a thread. Not `private` (unlike PeerSocketProber's
    /// copy) so the SIGTERM→SIGKILL escalation it enables is directly
    /// unit-testable against a real child process without going
    /// through ssh.
    static func waitForExit(_ proc: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }
}
