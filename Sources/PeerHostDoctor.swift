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

    /// OS-only fallback for states where the peer or version probe cannot
    /// identify a serving process. The reinstall action is Linux-only, so
    /// unknown must never be treated as Linux by default.
    static let hostKindProbeCommand =
        #"sh -c 'case "$(uname -s)" in Darwin) echo term-mesh-app ;; Linux) echo term-meshd ;; *) exit 44 ;; esac'"#

    /// Which `term-meshd` processes a Mac host is running, and which sockets
    /// each one holds — enough to tell a daemon the app is using from one
    /// nothing points at any more.
    ///
    /// Darwin only (exit 44 elsewhere): a Linux host runs its daemon under
    /// systemd, where a parent of 1 and a lifetime longer than any app are
    /// both correct. Applying this judgement there would report every healthy
    /// host as broken.
    ///
    /// `lsof -a` is not optional. Without `-a`, `-p` and `-U` are OR-ed and
    /// every process reports every unix socket on the machine — which reads as
    /// "the app is connected to all of them" and finds nothing stale, ever.
    ///
    /// No single quotes in the body (same `sh -c '…'` wrapper constraint as
    /// remoteCommand/diagnoseCommand).
    /// The probe body, without the `sh -c '…'` wrapper.
    ///
    /// Split out so a caller that already has a script of its own can append
    /// this one instead of paying a second ssh round trip for it — see
    /// `TeamOrchestrator.leaderDaemonDiagnostic`. Keeping one body means the
    /// two callers cannot drift into disagreeing about what a daemon is.
    static let daemonInstancesProbeBody =
        #"if [ "$(uname -s)" != Darwin ]; then exit 44; fi; app=$(pgrep -f "term-mesh.app/Contents/MacOS/term-mesh" | head -1); echo "app=${app:-none}"; if [ -n "$app" ]; then echo "appsocks=$(lsof -a -p "$app" -U -F n 2>/dev/null | sed -n "s/^n//p" | grep term-mesh | sort -u | tr "\n" " ")"; fi; for p in $(pgrep -f "Resources/bin/term-meshd" 2>/dev/null); do ppid=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d " "); etime=$(ps -o etime= -p "$p" 2>/dev/null | tr -d " "); socks=$(lsof -a -p "$p" -U -F n 2>/dev/null | sed -n "s/^n//p" | grep term-mesh | sort -u | tr "\n" " "); echo "daemon=$p ppid=${ppid:-0} etime=$etime socks=$socks"; done; exit 0"#

    static let daemonInstancesProbeCommand = "sh -c '" + daemonInstancesProbeBody + "'"

    /// One `term-meshd` process on a peer, as the probe above reports it.
    struct DaemonInstance: Equatable {
        var pid: Int
        var parentPid: Int
        /// `ps -o etime=` form (`01-05:10:54`), shown as-is; the point is
        /// "since yesterday", not arithmetic.
        var elapsed: String
        var sockets: [String]
    }

    /// A Mac peer's daemon situation: the app that serves the peer socket, and
    /// every daemon process around it.
    struct DaemonSnapshot: Equatable {
        var appPid: Int?
        var appSockets: [String]
        var daemons: [DaemonInstance]
    }

    static func parseDaemonSnapshot(_ output: String) -> DaemonSnapshot {
        var snapshot = DaemonSnapshot(appPid: nil, appSockets: [], daemons: [])
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if let value = text.dropPrefixIfPresent("app=") {
                snapshot.appPid = Int(value)
            } else if let value = text.dropPrefixIfPresent("appsocks=") {
                snapshot.appSockets = splitSocketList(value)
            } else if text.hasPrefix("daemon=") {
                if let instance = parseDaemonInstance(text) {
                    snapshot.daemons.append(instance)
                }
            }
        }
        return snapshot
    }

    private static func splitSocketList(_ value: String) -> [String] {
        value.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.hasPrefix("/") }
    }

    private static func parseDaemonInstance(_ line: String) -> DaemonInstance? {
        // `daemon=<pid> ppid=<n> etime=<t> socks=<a> <b> …` — socks runs to the
        // end of the line, so split the head off by its known keys rather than
        // by whitespace alone.
        guard let socksRange = line.range(of: " socks=") else { return nil }
        let head = String(line[line.startIndex..<socksRange.lowerBound])
        let sockets = splitSocketList(String(line[socksRange.upperBound...]))
        var pid: Int?
        var parentPid = 0
        var elapsed = ""
        for field in head.split(separator: " ", omittingEmptySubsequences: true) {
            let text = String(field)
            if let value = text.dropPrefixIfPresent("daemon=") { pid = Int(value) }
            else if let value = text.dropPrefixIfPresent("ppid=") { parentPid = Int(value) ?? 0 }
            else if let value = text.dropPrefixIfPresent("etime=") { elapsed = value }
        }
        guard let pid else { return nil }
        return DaemonInstance(
            pid: pid, parentPid: parentPid, elapsed: elapsed, sockets: sockets
        )
    }

    /// Daemons nothing on this host points at any more.
    ///
    /// The test is the app's own socket list: a daemon the app adopted appears
    /// there as a client connection, so an empty intersection means this
    /// process is serving nobody. Being parented to 1 is NOT the test —
    /// outliving the app is deliberate (`daemonShouldOutliveApp`), which is
    /// exactly why the leftovers accumulate and why a lifetime alone cannot
    /// separate them.
    ///
    /// With no app running, the answer is "none": a daemon may legitimately be
    /// holding sessions for the next launch to adopt, and killing those would
    /// destroy the very thing outliving the app exists to protect.
    static func staleDaemons(in snapshot: DaemonSnapshot) -> [DaemonInstance] {
        guard snapshot.appPid != nil else { return [] }
        let appSockets = Set(snapshot.appSockets)
        return snapshot.daemons.filter { daemon in
            daemon.sockets.allSatisfy { !appSockets.contains($0) }
        }
    }

    /// One term-mesh binary a host would run, and which copy it is.
    struct BinaryEntry: Equatable {
        var path: String
        var version: String
    }

    /// What a host would actually execute, and what else is lying around.
    struct BinaryInventory: Equatable {
        var appVersion: String?
        /// OS and effective accounts from the same SSH session. On Linux,
        /// panes inherit the daemon account, not the SSH account.
        var hostOS: String?
        var sshUser: String?
        var daemonUser: String?
        /// The login shell a pane on this host would run, and the `PATH` that
        /// shell builds. A pane's `PATH` comes from the profile, so it is
        /// routinely different from the one this probe searches — and when a
        /// CLI is "installed but not found", this is the pair that says why.
        var loginShell: String?
        var agentShell: String?
        var loginPath: String?
        var homeDirectory: String?
        /// Shell-independent agent configuration. The probe checks only the
        /// file's path and presence; it never reads credential values.
        var agentEnvironmentPath: String?
        var agentEnvironmentFileExists: Bool?
        /// The `tm-agent` an agent launched here would get.
        var cli: BinaryEntry?
        /// Other `tm-agent` copies on the same PATH, in search order after
        /// the winner. A different version here is the drift.
        var cliShadowed: [BinaryEntry] = []
        var daemon: BinaryEntry?
        var daemonShadowed: [BinaryEntry] = []
        /// The bridge this host would run an agent through, when it has one.
        ///
        /// Carries no version — it has no `--version` flag — so only the path
        /// is meaningful here. Absent means codex / kiro / cursor / agy agents
        /// on this host cannot be held as native panels.
        var bridge: BinaryEntry?
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
            + #"echo "os=$(uname -s 2>/dev/null)"; echo "ssh-user=$(id -un 2>/dev/null)"; daemon_user=$(ps -o user= -C term-meshd 2>/dev/null | head -1 | tr -d "[:space:]"); [ -n "$daemon_user" ] && echo "daemon-user=$daemon_user"; "#
            // The pane's shell and PATH, resolved the way the daemon resolves
            // them: `$SHELL` is unset here on purpose, because a daemon
            // started by systemd has none either and falls through to the
            // passwd entry. Reading the profile's PATH needs a login shell,
            // and `-c` keeps it non-interactive. Shares
            // `accountLoginShellResolve` with the launcher — asking the
            // question a second way is how the probe came to report a shell
            // the launcher would not use (`getent` is absent on macOS).
            + RemoteAgentEnvironmentShell.accountLoginShellResolve
            + #"pane_shell=$term_mesh_login_shell; "#
            + #"echo "login-shell=$pane_shell"; "#
            + #"agent_shell=$pane_shell; case "${agent_shell##*/}" in sh|bash|zsh|dash|ksh|mksh) ;; *) agent_shell=/bin/sh;; esac; echo "agent-shell=$agent_shell"; "#
            // `\$PATH` so the *login* shell expands it, not this one. Single
            // quotes would be the obvious way to protect it and are exactly
            // what this probe cannot contain — the whole body ships inside
            // `sh -c '…'`.
            + #"pane_path=$(env -u SHELL "$pane_shell" -lc "printf %s \$PATH" 2>/dev/null | tr -d "\n"); "#
            + #"[ -n "$pane_path" ] && echo "login-path=$pane_path"; "#
            + #"[ -n "$HOME" ] && echo "home=$HOME"; "#
            + #"agent_env="$HOME/.config/term-mesh/agent-env"; echo "agent-env-path=$agent_env"; if [ -f "$agent_env" ]; then echo agent-env-present=1; else echo agent-env-present=0; fi; "#
            + #"if [ "$(uname -s)" = Darwin ]; then v=$(/usr/bin/defaults read /Applications/term-mesh.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null); [ -n "$v" ] && echo "app=$v"; fi; "#
            // tm-agent-bridge is asked for but never `--version`ed: it is
            // spoken to over a pipe and has no such flag. Presence is the
            // whole question — without it this host cannot run a codex / kiro
            // / cursor / agy agent as a native panel, and nothing on either
            // side says so.
            + #"for b in tm-agent term-meshd tm-agent-bridge; do first=1; seen=""; for d in $(echo "$PATH" | tr : " "); do p="$d/$b"; case " $seen " in *" $p "*) continue ;; esac; if [ -x "$p" ]; then seen="$seen $p"; if [ "$b" = tm-agent-bridge ]; then v=""; else v=$("$p" --version 2>/dev/null | head -1); fi; if [ "$first" = 1 ]; then echo "$b=$p|$v"; first=0; else echo "$b.shadowed=$p|$v"; fi; fi; done; done; exit 0"#
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
    /// Ask a Mac host which daemons it is running. Never throws: a Linux host
    /// answers `exit 44` by design, and an unreachable one simply has nothing
    /// to report — neither is a condition the caller should have to handle.
    static func daemonSnapshot(
        sshTarget: String,
        port: Int?,
        identityFile: String?
    ) async -> DaemonSnapshot? {
        do {
            let output = try await runRemote(
                sshTarget: sshTarget,
                port: port,
                identityFile: identityFile,
                command: daemonInstancesProbeCommand,
                timeoutSeconds: 20
            )
            let snapshot = parseDaemonSnapshot(output)
            return snapshot.daemons.isEmpty && snapshot.appPid == nil ? nil : snapshot
        } catch {
            return nil
        }
    }

    /// Ends the pids fed to it on stdin, one per line.
    ///
    /// The pids ride on stdin rather than in the command text for the same
    /// reason every other probe here is a fixed string: nothing this side
    /// computes gets to become remote shell syntax. The `*[!0-9]*` guard is
    /// the remote half of that promise — a line that is not a plain number is
    /// skipped rather than run.
    ///
    /// SIGTERM only. A daemon that ignores it is a different problem, and
    /// SIGKILL would take its unix sockets with it uncleaned.
    static let daemonCleanupCommand =
        #"sh -c 'while read -r pid; do case "$pid" in ""|*[!0-9]*) continue ;; esac; if kill "$pid" 2>/dev/null; then echo "killed=$pid"; else echo "failed=$pid"; fi; done'"#

    /// Stop the daemons this host is no longer using.
    ///
    /// Deliberately takes explicit pids rather than re-deriving them here: the
    /// caller showed the user exactly which processes it was about to end, and
    /// a list recomputed after that dialog could differ from the one they
    /// agreed to.
    @discardableResult
    static func terminateDaemons(
        sshTarget: String,
        port: Int?,
        identityFile: String?,
        pids: [Int]
    ) async throws -> [Int] {
        guard !pids.isEmpty else { return [] }
        RemoteWorkLog.infoOffMain(
            "Stopping \(pids.count) unused term-meshd process(es) on \(sshTarget)"
        )
        let payload = pids.map(String.init).joined(separator: "\n") + "\n"
        let output = try await runRemote(
            sshTarget: sshTarget,
            port: port,
            identityFile: identityFile,
            command: daemonCleanupCommand,
            timeoutSeconds: 20,
            input: Data(payload.utf8)
        )
        let killed = parseTerminatedPids(output)
        RemoteWorkLog.infoOffMain(
            killed.count == pids.count
                ? "Stopped \(killed.count) unused term-meshd process(es) on \(sshTarget)"
                : "Stopped \(killed.count) of \(pids.count) on \(sshTarget) — the rest were already gone or refused"
        )
        return killed
    }

    static func parseTerminatedPids(_ output: String) -> [Int] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let value = line.trimmingCharacters(in: .whitespaces)
                .dropPrefixIfPresent("killed=") else { return nil }
            return Int(value)
        }
    }

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
            if key == "agent-env-path" {
                inventory.agentEnvironmentPath = value.isEmpty ? nil : value
                continue
            }
            if key == "agent-env-present" {
                inventory.agentEnvironmentFileExists = value == "1"
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
            case "os": inventory.hostOS = value.isEmpty ? nil : value
            case "ssh-user": inventory.sshUser = value.isEmpty ? nil : value
            case "daemon-user": inventory.daemonUser = value.isEmpty ? nil : value
            case "login-shell": inventory.loginShell = value.isEmpty ? nil : value
            case "agent-shell": inventory.agentShell = value.isEmpty ? nil : value
            case "login-path": inventory.loginPath = value.isEmpty ? nil : value
            case "home": inventory.homeDirectory = value.isEmpty ? nil : value
            case "tm-agent": inventory.cli = entry
            case "tm-agent.shadowed": inventory.cliShadowed.append(entry)
            case "term-meshd": inventory.daemon = entry
            case "term-meshd.shadowed": inventory.daemonShadowed.append(entry)
            case "tm-agent-bridge": inventory.bridge = entry
            // A shadowed bridge is not drift the way a shadowed CLI is: with
            // no version to compare, two copies are indistinguishable. The
            // first one found is the one that runs, which is all this reports.
            case "tm-agent-bridge.shadowed": continue
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
        // A terminal pane builds its PATH from the login profile, while an
        // agent gets a fixed one. So a CLI can be installed, found by this
        // probe, used happily by every agent — and still be missing from the
        // pane beside them. Measured: `~/.local/bin` held claude, codex and
        // git-kit while the login shell's PATH did not mention it, because the
        // line that adds it lives in `.bashrc` and a login shell skips that.
        //
        // `~/.local/bin` is excluded: the daemon prepends that one itself, so
        // naming it here would report a gap that is already closed.
        if let loginPath = inventory.loginPath,
           let cliPath = inventory.cli?.path, cliPath.hasPrefix("/") {
            let directory = (cliPath as NSString).deletingLastPathComponent
            let daemonPrepends = inventory.homeDirectory.map {
                ($0 as NSString).appendingPathComponent(".local/bin")
            }
            let searched = Set(loginPath.split(separator: ":").map(String.init))
            if !directory.isEmpty,
               !searched.contains(directory),
               directory != daemonPrepends {
                let shell = inventory.loginShell ?? "the login shell"
                warnings.append(
                    "Terminal panes cannot find tm-agent: it lives in \(directory), and "
                        + "\(shell) builds a PATH without it. Agents are unaffected — they run "
                        + "with a fixed PATH. Add \(directory) to the profile that shell reads "
                        + "at login, or set PATH for this host explicitly (a literal list; "
                        + "$PATH is not expanded there)."
                )
            }
        }
        if inventory.hostOS == "Linux",
           let sshUser = inventory.sshUser,
           let daemonUser = inventory.daemonUser,
           sshUser != daemonUser {
            warnings.append(
                "Agent account: SSH connects as \(sshUser), but term-meshd runs as "
                    + "\(daemonUser). Projects are prepared as \(sshUser) while panes run as "
                    + "\(daemonUser). Reinstall term-meshd to make both use \(sshUser)."
            )
        }
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
        // A daemon without a bridge beside it. Not drift — a capability this
        // host does not have, and the one place a person is already looking at
        // that host. Agents still run there; they just cannot be held as
        // native panels, which otherwise shows up only as "why is this a
        // terminal pane" with nothing to answer it.
        //
        // Only said when the host runs a daemon at all: a Mac peer serves from
        // the app bundle, which carries its own bridge, so asking about PATH
        // there would report a problem that does not exist.
        if inventory.daemon != nil, inventory.bridge == nil {
            warnings.append(
                "tm-agent-bridge is not installed here — codex/kiro/cursor/agy agents "
                    + "on this host stay plain terminal panes. Reinstall term-meshd to add it."
            )
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

    /// Identifies only the remote OS/process kind. Used after a successful
    /// SSH probe when no version can be read, so Linux-only install actions
    /// remain available without ever being offered to a Mac or unknown host.
    static func checkHostKind(
        sshTarget: String,
        port: Int?,
        identityFile: String?
    ) async -> PeerHostKind? {
        guard let output = try? await runRemote(
            sshTarget: sshTarget, port: port, identityFile: identityFile,
            command: hostKindProbeCommand, timeoutSeconds: 15
        ) else { return nil }
        return parseHostKindLine(from: output)
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

    /// Pure parser for `hostKindProbeCommand`; scans past MOTD noise and
    /// accepts only the two exact process-kind sentinels.
    static func parseHostKindLine(from output: String) -> PeerHostKind? {
        var found: PeerHostKind?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            switch rawLine.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "term-meshd": found = .daemon
            case "term-mesh-app": found = .app
            default: continue
            }
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

private extension String {
    /// `hasPrefix` + `dropFirst` as one step, so the probe parser reads as a
    /// list of keys rather than a chain of index arithmetic.
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
