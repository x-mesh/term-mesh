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
    case ok(details: PeerRelayTestDetails, hostCLIBinDirs: [String])
    /// SSH reached the host but no live peer socket was found —
    /// term-meshd is likely not installed/running. Install is offered.
    case daemonMissing
    /// A socket file exists, but the SSH forward or peer protocol handshake
    /// could not reach a live compatible server. Kept separate from
    /// `sshFailed` so a stale socket never produces a false-green result.
    case relayFailed(details: PeerRelayTestDetails, message: String)
    /// SSH itself failed (auth, DNS, timeout…).
    case sshFailed(String)
}

/// Exact route proven by Test Relay. Kept separate from the connection state
/// so the editor can show which socket was configured, which one discovery
/// found, which endpoint answered, and which durable session owner the host
/// advertised. A green result without these identities is not actionable.
struct PeerRelayTestDetails: Equatable, Sendable {
    var configuredSocket: String?
    var discoveredSocket: String?
    var discoveredVerified: Bool?
    var connectedSocket: String
    var connectedVerified: Bool
    var sessionOwnerSocket: String?
    var sessionOwnerVerified: Bool
    var hostDisplayName: String
    var hostAppVersion: String

    /// The profile-selected route and its advertised session owner are the
    /// release gate. A reachable alternate discovered socket is diagnostic
    /// evidence only and can never turn a failed configured route green.
    var routeVerified: Bool { connectedVerified && sessionOwnerVerified }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
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

enum PeerHostHealthVerdict: String, Equatable {
    case healthy
    case degraded
    case unhealthy
    case unknown
}

enum PeerHostControlRPCStatus: Equatable {
    case available
    case unavailable
    case probeUnavailable
}

/// A measured Linux-peer baseline. A peer handshake alone is insufficient:
/// the daemon control plane must also have a reachable pathname, and recent
/// protocol mismatches must be absent.
struct PeerHostHealthBaseline: Equatable {
    var serviceActive = false
    /// The `root` field of the daemon's own `/tmp` mount, read from
    /// `/proc/<pid>/mountinfo`.
    ///
    /// Empty on a host where it could not be read, and `/` on an ordinary
    /// one. Under `PrivateTmp=true` it reads
    /// `/tmp/systemd-private-<id>-term-meshd.service-<rand>/tmp`, which names
    /// the unit outright — that is the whole reason it is collected. Without
    /// it the probe can say the control socket is missing but not that it is
    /// missing *because the daemon's /tmp is a private mount the prober
    /// cannot see*, and those two lead to opposite conclusions about whether
    /// the host is broken.
    ///
    /// Deliberately outside the verdict and outside the parser's required
    /// keys: it explains a failure, it does not define one, and an additive
    /// diagnostic must never be able to turn a readable baseline into no
    /// baseline at all.
    var daemonTmpRoot = ""
    var controlPath = "/tmp/term-meshd.sock"
    var controlPathPresent = false
    var controlRPC: PeerHostControlRPCStatus = .unavailable
    var peerPath = ""
    var peerPathPresent = false
    var relayLagCount = 0
    var resumeHealCount = 0
    var protocolMismatchCount = 0

    var verdict: PeerHostHealthVerdict {
        guard serviceActive, controlPathPresent, peerPathPresent else {
            return .unhealthy
        }
        guard protocolMismatchCount == 0 else { return .unhealthy }
        guard controlRPC != .probeUnavailable else { return .unknown }
        guard controlRPC == .available else { return .unhealthy }
        return relayLagCount > 0 || resumeHealCount > 0 ? .degraded : .healthy
    }

    var unhealthyReasons: [String] {
        var reasons: [String] = []
        if !serviceActive { reasons.append("service inactive") }
        if !controlPathPresent {
            reasons.append("control socket missing at \(controlPath)")
        } else if controlRPC == .unavailable {
            reasons.append("control RPC unavailable at \(controlPath)")
        }
        if !peerPathPresent { reasons.append("peer socket missing at \(peerPath)") }
        if protocolMismatchCount > 0 {
            reasons.append("protocol mismatches \(protocolMismatchCount) in 5 min")
        }
        return reasons
    }
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

    /// Linux peer health baseline. Key/value output is secret-free and makes
    /// a split-brain host (working peer socket, missing daemon control path)
    /// unambiguously unhealthy. The tm-agent call is a real JSON-RPC round
    /// trip; checking -S alone would false-green an orphaned socket.
    static var healthBaselineCommand: String {
        healthBaselineCommandTemplate.replacingOccurrences(
            of: #"[ -n "$control" ] || control=/tmp/term-meshd.sock"#,
            with: #"configured=$control; t=${TMPDIR:-}; [ -n "$t" ] || t=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null); control=; for c in "$configured" "${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/term-meshd.sock}" "/run/user/$(id -u)/term-meshd.sock" "/run/term-mesh/term-meshd.sock" "${t:+${t%/}/term-meshd.sock}" "/tmp/term-meshd.sock"; do [ -n "$c" ] && [ -S "$c" ] || continue; control=$c; break; done; if [ -z "$control" ]; then if [ -n "$configured" ]; then control=$configured; elif [ "$s" = active ]; then control=/run/term-mesh/term-meshd.sock; elif [ "$u" = active ]; then control=/run/user/$(id -u)/term-meshd.sock; else control=/tmp/term-meshd.sock; fi; fi"#
        )
    }

    private static let healthBaselineCommandTemplate =
        #"sh -c 'if [ "$(uname -s)" != Linux ]; then exit 44; fi; u=$(systemctl --user is-active term-meshd 2>/dev/null); s=$(systemctl is-active term-meshd 2>/dev/null); if [ "$s" = active ] || [ "$u" = active ]; then active=1; else active=0; fi; control=${TERMMESH_DAEMON_UNIX_PATH:-}; if [ -z "$control" ]; then control=$(sed -n "s/^TERMMESH_DAEMON_UNIX_PATH=//p" "$HOME/.config/term-mesh/peer.env" /etc/term-mesh/peer.env 2>/dev/null | tail -1 | tr -d "\""); fi; [ -n "$control" ] || control=/tmp/term-meshd.sock; peer=${TERMMESH_PEER_SOCKET:-}; if [ -z "$peer" ]; then peer=$(sed -n "s/^TERMMESH_PEER_SOCKET=//p" "$HOME/.config/term-mesh/peer.env" /etc/term-mesh/peer.env 2>/dev/null | tail -1 | tr -d "\""); fi; [ -n "$peer" ] || peer=/run/term-mesh/tm-peer.sock; [ -S "$control" ] && cpresent=1 || cpresent=0; [ -S "$peer" ] && ppresent=1 || ppresent=0; cli=$(command -v tm-agent 2>/dev/null); [ -x "$cli" ] || cli=$HOME/.local/bin/tm-agent; if [ ! -x "$cli" ]; then crpc=unknown; elif TERMMESH_DAEMON_UNIX_PATH="$control" "$cli" daemon replay-capacity >/dev/null 2>&1; then crpc=1; else crpc=0; fi; if [ "$s" = active ]; then logs=$(journalctl -u term-meshd --since=-5min --no-pager 2>/dev/null); else logs=$(journalctl --user -u term-meshd --since=-5min --no-pager 2>/dev/null); fi; lag=$(printf "%s\n" "$logs" | grep -c "attach relay lagged"); heal=$(printf "%s\n" "$logs" | grep -c "resume-heal reconnect"); proto=$(printf "%s\n" "$logs" | grep -c "frame length .* exceeds"); dpid=$(systemctl show -p MainPID --value term-meshd 2>/dev/null); if [ -z "$dpid" ] || [ "$dpid" = 0 ]; then dpid=$(systemctl --user show -p MainPID --value term-meshd 2>/dev/null); fi; tmproot=$(grep " /tmp " /proc/$dpid/mountinfo 2>/dev/null | head -1 | cut -d" " -f4); echo "health-service-active=$active"; echo "health-daemon-tmp-root=$tmproot"; echo "health-control-path=$control"; echo "health-control-present=$cpresent"; echo "health-control-rpc=$crpc"; echo "health-peer-path=$peer"; echo "health-peer-present=$ppresent"; echo "health-relay-lag-5m=$lag"; echo "health-resume-heal-5m=$heal"; echo "health-protocol-mismatch-5m=$proto"'"#

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
        #"if [ "$(uname -s)" != Darwin ]; then exit 44; fi; app=$(pgrep -f "term-mesh.app/Contents/MacOS/term-mesh" | head -1); net=$(netstat -anv -f unix 2>/dev/null); echo "app=${app:-none}"; if [ -n "$app" ]; then appraw=$(lsof -a -p "$app" -U -F fn 2>/dev/null); printf "%s\n" "$appraw" | sed -n "s/^n\(\/.*\)/\1/p" | sort -u | while IFS= read -r s; do [ -n "$s" ] || continue; encoded=$(printf %s "$s" | base64 | tr -d "\n"); echo "app-socket=$encoded"; done; fi; for p in $(pgrep -f "Resources/bin/term-meshd" 2>/dev/null); do ppid=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d " "); etime=$(ps -o etime= -p "$p" 2>/dev/null | tr -d " "); started=$(ps -o lstart= -p "$p" 2>/dev/null | tr -s " " "_" | sed "s/^_//;s/_$//"); pgid=$(ps -o pgid= -p "$p" 2>/dev/null | tr -d " "); sid=$(ps -o sess= -p "$p" 2>/dev/null | tr -d " "); identity=${started}_${pgid}_${sid}; exe=$(lsof -a -p "$p" -d txt -F n 2>/dev/null | sed -n "s/^n//p" | head -1); raw=$(lsof -a -p "$p" -U -F fn 2>/dev/null); probe=$?; named=$(printf "%s\n" "$raw" | sed -n "s/^n\(\/.*\)/\1/p"); unixfds=$(printf "%s\n" "$raw" | grep -c "^f"); socketfds=$(printf "%s\n" "$named" | grep -c .); anonfds=$((unixfds - socketfds)); peerfds=$(printf "%s\n" "$named" | grep -c peer); if [ "$probe" = 0 ]; then complete=1; else complete=0; fi; echo "daemon=$p ppid=${ppid:-0} etime=$etime probe=$complete unixfds=$unixfds socketfds=$socketfds anonfds=$anonfds peerfds=$peerfds started=$identity exe=$exe socks="; printf "%s\n" "$named" | sort -u | while IFS= read -r s; do [ -n "$s" ] || continue; encoded=$(printf %s "$s" | base64 | tr -d "\n"); echo "daemon-socket=$p encoded=$encoded"; [ -S "$s" ] && echo "daemon-existing=$p encoded=$encoded"; current=$(printf "%s\n" "$net" | awk -v proc="term-meshd:$p" -v path="$s" "index(\$0, proc) && index(\$0, \" 00000002 \") && substr(\$0, length(\$0) - length(path) + 1) == path { print 1; exit }"); [ "$current" = 1 ] && echo "daemon-current=$p encoded=$encoded"; done; done; exit 0"#

    static let daemonInstancesProbeCommand = "sh -c '" + daemonInstancesProbeBody + "'"

    /// One `term-meshd` process on a peer, as the probe above reports it.
    struct DaemonInstance: Equatable {
        var pid: Int
        var parentPid: Int
        /// `ps -o etime=` form (`01-05:10:54`), shown as-is; the point is
        /// "since yesterday", not arithmetic.
        var elapsed: String
        var sockets: [String]
        /// Socket names that currently exist in the filesystem. This is kept
        /// separate from `sockets`: after unlink/rebind two daemon generations
        /// can report the same name, so the classifier also needs duplicate
        /// ownership and peer-FD counts before calling either one stale.
        var existingSockets: [String]
        /// Pathnames whose kernel `SO_ACCEPTCONN` listener row is attributed
        /// to this exact PID by Darwin netstat. Unlike an lsof pathname, this
        /// distinguishes the current bind owner from an unlinked generation.
        var currentListenerSockets: [String]
        /// Listener plus accepted peer connections. More than one FD for one
        /// peer pathname proves an existing client still depends on this
        /// daemon even when the pathname itself was unlinked.
        var peerFDCount: Int
        var socketFDCount: Int
        /// Every UNIX FD record from `lsof -Ffn`, including anonymous
        /// `n->0x…` records that have no pathname.
        var unixSocketFDCount: Int
        var anonymousSocketFDCount: Int
        /// `lsof` completed successfully. An incomplete probe is never
        /// cleanup evidence: failure to observe a client must fail closed.
        var socketProbeComplete: Bool
        /// Stable process identity captured with the PID. Cleanup rechecks both
        /// values immediately before signaling so PID reuse cannot target an
        /// unrelated process.
        var startIdentity: String
        var executablePath: String
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
            } else if let value = text.dropPrefixIfPresent("app-socket="),
                      let path = decodeSocketPath(value) {
                snapshot.appSockets.append(path)
            } else if text.hasPrefix("daemon=") {
                if let instance = parseDaemonInstance(text) {
                    snapshot.daemons.append(instance)
                }
            } else if text.hasPrefix("daemon-socket=") {
                appendEncodedDaemonSocket(
                    text, key: "daemon-socket", destination: .reported, to: &snapshot
                )
            } else if text.hasPrefix("daemon-current=") {
                appendEncodedDaemonSocket(
                    text, key: "daemon-current", destination: .current, to: &snapshot
                )
            } else if text.hasPrefix("daemon-existing=") {
                if text.contains(" encoded=") {
                    appendEncodedDaemonSocket(
                        text, key: "daemon-existing", destination: .existing, to: &snapshot
                    )
                } else {
                    guard let pathRange = text.range(of: " path=") else { continue }
                    let head = text[..<pathRange.lowerBound]
                    let path = String(text[pathRange.upperBound...])
                    guard let pid = Int(head.dropFirst("daemon-existing=".count)),
                          path.hasPrefix("/"),
                          let index = snapshot.daemons.firstIndex(where: { $0.pid == pid })
                    else { continue }
                    snapshot.daemons[index].existingSockets.append(path)
                }
            }
        }
        return snapshot
    }

    private static func decodeSocketPath(_ encoded: String) -> String? {
        guard let data = Data(base64Encoded: encoded),
              let path = String(data: data, encoding: .utf8),
              path.hasPrefix("/")
        else { return nil }
        return path
    }

    private enum DaemonSocketDestination {
        case reported
        case existing
        case current
    }

    private static func appendEncodedDaemonSocket(
        _ text: String,
        key: String,
        destination: DaemonSocketDestination,
        to snapshot: inout DaemonSnapshot
    ) {
        guard let encodedRange = text.range(of: " encoded=") else { return }
        let head = text[..<encodedRange.lowerBound]
        let encoded = String(text[encodedRange.upperBound...])
        guard let pid = Int(head.dropFirst(key.count + 1)),
              let path = decodeSocketPath(encoded),
              let index = snapshot.daemons.firstIndex(where: { $0.pid == pid })
        else { return }
        switch destination {
        case .existing:
            snapshot.daemons[index].existingSockets.append(path)
        case .reported:
            snapshot.daemons[index].sockets.append(path)
        case .current:
            snapshot.daemons[index].currentListenerSockets.append(path)
        }
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
        var peerFDCount = 0
        var socketFDCount = 0
        var parsedUnixSocketFDCount: Int?
        var anonymousSocketFDCount = 0
        var socketProbeComplete = false
        var startIdentity = ""
        var executablePath = ""
        for field in head.split(separator: " ", omittingEmptySubsequences: true) {
            let text = String(field)
            if let value = text.dropPrefixIfPresent("daemon=") { pid = Int(value) }
            else if let value = text.dropPrefixIfPresent("ppid=") { parentPid = Int(value) ?? 0 }
            else if let value = text.dropPrefixIfPresent("etime=") { elapsed = value }
            else if let value = text.dropPrefixIfPresent("peerfds=") { peerFDCount = Int(value) ?? 0 }
            else if let value = text.dropPrefixIfPresent("socketfds=") { socketFDCount = Int(value) ?? 0 }
            else if let value = text.dropPrefixIfPresent("unixfds=") { parsedUnixSocketFDCount = Int(value) }
            else if let value = text.dropPrefixIfPresent("anonfds=") { anonymousSocketFDCount = Int(value) ?? 0 }
            else if let value = text.dropPrefixIfPresent("probe=") { socketProbeComplete = value == "1" }
            else if let value = text.dropPrefixIfPresent("started=") { startIdentity = value }
            else if let value = text.dropPrefixIfPresent("exe=") { executablePath = value }
        }
        guard let pid else { return nil }
        let unixSocketFDCount = parsedUnixSocketFDCount
            ?? socketFDCount + anonymousSocketFDCount
        return DaemonInstance(
            pid: pid, parentPid: parentPid, elapsed: elapsed,
            sockets: sockets, existingSockets: [], currentListenerSockets: [],
            peerFDCount: peerFDCount,
            socketFDCount: socketFDCount,
            unixSocketFDCount: unixSocketFDCount,
            anonymousSocketFDCount: anonymousSocketFDCount,
            socketProbeComplete: socketProbeComplete,
            startIdentity: startIdentity, executablePath: executablePath
        )
    }

    /// Daemons nothing on this host points at any more.
    ///
    /// Parentage, accepted peer connections, and pathname ownership are
    /// separate evidence. No one signal decides this: daemons intentionally
    /// outlive an app, and an unlinked listener can still carry existing
    /// clients. Cleanup is offered only when those protections are absent or
    /// another independently protected generation owns the duplicate path.
    ///
    /// With no app running, the answer is "none": a daemon may legitimately be
    /// holding sessions for the next launch to adopt, and killing those would
    /// destroy the very thing outliving the app exists to protect.
    static func staleDaemons(
        in snapshot: DaemonSnapshot,
        protecting protectedPIDs: Set<Int> = []
    ) -> [DaemonInstance] {
        guard let appPid = snapshot.appPid else { return [] }
        let ownersByPath = Dictionary(grouping: snapshot.daemons.flatMap { daemon in
            daemon.sockets.map { (path: $0, daemon: daemon) }
        }, by: { $0.path })
        let intrinsicallyProtected = Set(snapshot.daemons.compactMap { daemon -> Int? in
            let hasAcceptedClient = daemon.socketFDCount > Set(daemon.sockets).count
            // The Tokio runtime in every bundled Mac daemon owns a stable
            // three-FD anonymous wakeup/socketpair set. Zero is accepted for
            // older builds that do not expose it through lsof. Any other
            // anonymous shape may be a client and therefore fails closed.
            let anonymousShapeKnown = daemon.anonymousSocketFDCount == 0
                || daemon.anonymousSocketFDCount == 3
            let fdCountsConsistent = daemon.unixSocketFDCount
                == daemon.socketFDCount + daemon.anonymousSocketFDCount
            return daemon.parentPid == appPid
                || hasAcceptedClient
                || !daemon.currentListenerSockets.isEmpty
                || !anonymousShapeKnown
                || !fdCountsConsistent
                || !daemon.socketProbeComplete
                || protectedPIDs.contains(daemon.pid)
                ? daemon.pid : nil
        }).union(protectedPIDs)

        return snapshot.daemons.filter { daemon in
            guard !intrinsicallyProtected.contains(daemon.pid) else { return false }
            if daemon.existingSockets.isEmpty { return true }
            for path in daemon.existingSockets {
                let owners = ownersByPath[path]?.map(\.daemon) ?? []
                // A unique reachable pathname is an idle but valid daemon.
                guard owners.count > 1 else { return false }
                // Duplicate names are conclusive only when Darwin's kernel
                // socket table attributes the current SO_ACCEPTCONN listener
                // for this exact pathname to another generation. Parentage
                // and accepted clients may belong to an unlinked old owner.
                guard owners.contains(where: {
                    $0.pid != daemon.pid && $0.currentListenerSockets.contains(path)
                }) else { return false }
            }
            return true
        }
    }

    /// One term-mesh binary a host would run, and which copy it is.
    struct BinaryEntry: Equatable {
        var path: String
        var version: String
        var identity: String = ""
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
    /// Emits `key=path|version|identity` lines and always exits 0 — absence is data,
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
            + #"for b in tm-agent term-meshd tm-agent-bridge; do first=1; seen=""; for d in $(echo "$PATH" | tr : " "); do p="$d/$b"; case " $seen " in *" $p "*) continue ;; esac; if [ -x "$p" ]; then seen="$seen $p"; if [ "$b" = tm-agent-bridge ]; then v=""; else v=$("$p" --version 2>/dev/null | head -1); fi; fid=$(stat -f "%d:%i:%m:%z" "$p" 2>/dev/null || stat -c "%d:%i:%Y:%s" "$p" 2>/dev/null); if [ "$first" = 1 ]; then echo "$b=$p|$v|$fid"; first=0; else echo "$b.shadowed=$p|$v|$fid"; fi; fi; done; done; exit 0"#
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
    /// Detached daemons receive SIGTERM together, then share one bounded grace
    /// period longer than the daemon's own five-second server shutdown budget.
    /// A process that does not finish is reported, never SIGKILLed here:
    /// cutting its shutdown short is how agent descendants became a second
    /// generation of garbage.
    static let daemonCleanupCommand =
        #"sh -c 'tab=$(printf "\t"); identity() { p=$1; started=$(ps -o lstart= -p "$p" 2>/dev/null | tr -s " " "_" | sed "s/^_//;s/_$//"); pgid=$(ps -o pgid= -p "$p" 2>/dev/null | tr -d " "); sid=$(ps -o sess= -p "$p" 2>/dev/null | tr -d " "); echo ${started}_${pgid}_${sid}; }; executable() { lsof -a -p "$1" -d txt -F n 2>/dev/null | sed -n "s/^n//p" | head -1; }; active=$(mktemp /tmp/term-mesh-cleanup-active.XXXXXX) || exit 65; trap "rm -f $active" EXIT HUP INT TERM; while IFS="$tab" read -r pid expected_start expected_exe; do case "$pid" in ""|*[!0-9]*) continue ;; esac; [ "$(identity "$pid")" = "$expected_start" ] && [ "$(executable "$pid")" = "$expected_exe" ] || { echo "replaced=$pid"; continue; }; ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d " "); parent=$(ps -o command= -p "$ppid" 2>/dev/null); case "$parent" in *.app/Contents/MacOS/term-mesh*) echo "protected=$pid"; continue ;; esac; if ! raw=$(lsof -a -p "$pid" -U -F fn 2>/dev/null); then echo "protected=$pid"; continue; fi; named=$(printf "%s\n" "$raw" | sed -n "s/^n\(\/.*\)/\1/p"); unixfds=$(printf "%s\n" "$raw" | grep -c "^f"); socketfds=$(printf "%s\n" "$named" | grep -c .); socketnames=$(printf "%s\n" "$named" | sort -u | grep -c .); anonfds=$((unixfds - socketfds)); [ "$socketfds" -le "$socketnames" ] || { echo "protected=$pid"; continue; }; [ "$unixfds" -eq $((socketfds + anonfds)) ] || { echo "protected=$pid"; continue; }; case "$anonfds" in 0|3) ;; *) echo "protected=$pid"; continue ;; esac; [ "$(identity "$pid")" = "$expected_start" ] && [ "$(executable "$pid")" = "$expected_exe" ] || { echo "replaced=$pid"; continue; }; if kill "$pid" 2>/dev/null; then printf "%s\t%s\t%s\n" "$pid" "$expected_start" "$expected_exe" >> "$active"; else echo "failed=$pid"; fi; done; n=0; while [ "$n" -lt 120 ]; do alive=0; while IFS="$tab" read -r pid expected_start expected_exe; do if kill -0 "$pid" 2>/dev/null && [ "$(identity "$pid")" = "$expected_start" ] && [ "$(executable "$pid")" = "$expected_exe" ]; then alive=1; fi; done < "$active"; [ "$alive" = 0 ] && break; sleep 0.1; n=$((n + 1)); done; while IFS="$tab" read -r pid expected_start expected_exe; do if ! kill -0 "$pid" 2>/dev/null; then echo "killed=$pid"; elif [ "$(identity "$pid")" != "$expected_start" ] || [ "$(executable "$pid")" != "$expected_exe" ]; then echo "replaced=$pid"; else echo "failed=$pid"; fi; done < "$active"'"#

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
        daemons: [DaemonInstance]
    ) async throws -> [Int] {
        let safe = daemons.filter {
            $0.pid > 1
                && !$0.startIdentity.isEmpty
                && !$0.startIdentity.contains("\t")
                && !$0.executablePath.contains("\t")
                && !$0.executablePath.contains("\n")
                && ($0.executablePath as NSString).lastPathComponent == "term-meshd"
        }
        guard safe.count == daemons.count, !safe.isEmpty else { return [] }
        RemoteWorkLog.infoOffMain(
            "Stopping \(daemons.count) unused term-meshd process(es) on \(sshTarget)"
        )
        let payload = safe.map {
            "\($0.pid)\t\($0.startIdentity)\t\($0.executablePath)"
        }.joined(separator: "\n") + "\n"
        let output = try await runRemote(
            sshTarget: sshTarget,
            port: port,
            identityFile: identityFile,
            command: daemonCleanupCommand,
            timeoutSeconds: 30,
            input: Data(payload.utf8)
        )
        let killed = parseTerminatedPids(output)
        RemoteWorkLog.infoOffMain(
            killed.count == daemons.count
                ? "Stopped \(killed.count) unused term-meshd process(es) on \(sshTarget)"
                : "Stopped \(killed.count) of \(daemons.count) on \(sshTarget) — the rest were already gone or refused"
        )
        return killed
    }

    static func parseTerminatedPids(_ output: String) -> [Int] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let value = text.dropPrefixIfPresent("killed=") else { return nil }
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
        var discoveredSocket: String?
        let configuredSocket = remoteSocket?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
        do {
            if let explicit = configuredSocket {
                try PeerSSHTunnel.validateRemoteSockPath(explicit)
                // A custom socket may sit outside every auto-detect
                // candidate. Run discovery only as an SSH reachability
                // check: `noSocketFound` still proves SSH worked, while
                // auth/DNS/timeout failures remain correctly classified
                // as SSH failures instead of relay failures.
                do {
                    discoveredSocket = try await PeerSocketProber.probe(
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
                discoveredSocket = socketPath
            }
        } catch PeerSocketProbeError.noSocketFound {
            return .daemonMissing
        } catch {
            return .sshFailed(String(describing: error))
        }

        return await testResolvedRoute(
            sshTarget: sshTarget, port: port, identityFile: identityFile,
            configuredSocket: configuredSocket, discoveredSocket: discoveredSocket,
            selectedSocket: socketPath
        )
    }

    /// Transport half of Test Relay after endpoint resolution. Production and
    /// the split-route E2E share this exact path; the E2E supplies isolated
    /// resolved endpoints so it can prove a dead configured route is not
    /// replaced by a reachable alternate without editing host config files.
    static func testResolvedRoute(
        sshTarget: String,
        port: Int?,
        identityFile: String?,
        configuredSocket: String?,
        discoveredSocket: String?,
        selectedSocket socketPath: String
    ) async -> PeerHostTestResult {
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
            let discoveredVerified: Bool?
            if let discoveredSocket, discoveredSocket != socketPath {
                discoveredVerified = await verifyPeerEndpoint(
                    sshTarget: sshTarget, port: port, identityFile: identityFile,
                    remoteSocket: discoveredSocket
                )
            } else {
                discoveredVerified = discoveredSocket == nil ? nil : true
            }
            let ownerPath = connection.sessionHostSockPath.nonEmpty
            var ownerVerified = ownerPath == nil || ownerPath == socketPath
            if let ownerPath, ownerPath != socketPath {
                let ownerTunnel = PeerSSHTunnel(
                    sshTarget: sshTarget, remoteSockPath: ownerPath,
                    port: port, identityFile: identityFile
                )
                do {
                    try await ownerTunnel.start()
                    let owner = try await PeerRelaySession.connect(
                        hostSockPath: ownerTunnel.localSockPath
                    )
                    await owner.cancel()
                    ownerTunnel.stop()
                    ownerVerified = true
                } catch {
                    ownerTunnel.stop()
                    await connection.cancel()
                    tunnel.stop()
                    let message = "connected via \(socketPath), but advertised session owner \(ownerPath) failed: \(error)"
                    RemoteWorkLog.infoOffMain(
                        "Relay health check failed for \(sshTarget): \(message)"
                    )
                    return .relayFailed(
                        details: PeerRelayTestDetails(
                            configuredSocket: configuredSocket,
                            discoveredSocket: discoveredSocket,
                            discoveredVerified: discoveredVerified,
                            connectedSocket: socketPath,
                            connectedVerified: true,
                            sessionOwnerSocket: ownerPath,
                            sessionOwnerVerified: false,
                            hostDisplayName: connection.hostDisplayName,
                            hostAppVersion: connection.hostAppVersion ?? "unknown"
                        ),
                        message: message
                    )
                }
            }
            let details = PeerRelayTestDetails(
                configuredSocket: configuredSocket,
                discoveredSocket: discoveredSocket,
                discoveredVerified: discoveredVerified,
                connectedSocket: socketPath,
                connectedVerified: true,
                sessionOwnerSocket: ownerPath,
                sessionOwnerVerified: ownerVerified,
                hostDisplayName: connection.hostDisplayName,
                hostAppVersion: connection.hostAppVersion ?? "unknown"
            )
            await connection.cancel()
            tunnel.stop()
            RemoteWorkLog.debugOffMain(
                "Relay health check passed for \(sshTarget) via \(socketPath)"
            )
            return .ok(
                details: details,
                hostCLIBinDirs: connection.hostCLIBinDirs
            )
        } catch {
            tunnel.stop()
            let message = String(describing: error)
            let discoveredVerified: Bool?
            if let discoveredSocket, discoveredSocket != socketPath {
                discoveredVerified = await verifyPeerEndpoint(
                    sshTarget: sshTarget, port: port, identityFile: identityFile,
                    remoteSocket: discoveredSocket
                )
            } else {
                discoveredVerified = discoveredSocket == nil ? nil : false
            }
            RemoteWorkLog.infoOffMain(
                "Relay health check failed for \(sshTarget) via \(socketPath): \(message)"
            )
            return .relayFailed(
                details: PeerRelayTestDetails(
                    configuredSocket: configuredSocket,
                    discoveredSocket: discoveredSocket,
                    discoveredVerified: discoveredVerified,
                    connectedSocket: socketPath,
                    connectedVerified: false,
                    sessionOwnerSocket: nil,
                    sessionOwnerVerified: false,
                    hostDisplayName: "Handshake failed",
                    hostAppVersion: "unknown"
                ),
                message: message
            )
        }
    }

    /// Probe a secondary endpoint without changing the route selected by the
    /// profile. Test Relay uses this for diagnosis only: a reachable discovered
    /// socket never silently replaces a failed configured socket.
    private static func verifyPeerEndpoint(
        sshTarget: String,
        port: Int?,
        identityFile: String?,
        remoteSocket: String
    ) async -> Bool {
        let tunnel = PeerSSHTunnel(
            sshTarget: sshTarget, remoteSockPath: remoteSocket,
            port: port, identityFile: identityFile
        )
        do {
            try await tunnel.start()
            let connection = try await PeerRelaySession.connect(
                hostSockPath: tunnel.localSockPath
            )
            await connection.cancel()
            tunnel.stop()
            return true
        } catch {
            tunnel.stop()
            return false
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
        for line in stdout.split(whereSeparator: { $0.isNewline }) {
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
            // `path|version|identity`. A binary that ran but printed nothing still
            // gets an entry — where it is matters even when it won't say
            // what it is.
            let parts = value.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard let path = parts.first, !path.isEmpty else { continue }
            let entry = BinaryEntry(
                path: String(path),
                version: parts.count > 1 ? String(parts[1]) : "",
                identity: parts.count > 2 ? String(parts[2]) : ""
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
        // Only said for a Linux daemon host. A Mac peer's app starts its own
        // bundled daemon and bridge from Resources/bin; the SSH inventory
        // PATH can see one without the other while the app still has the full
        // pair. Treating that partial PATH view as a missing capability is a
        // false warning. An unknown OS stays silent for the same reason: the
        // probe did not collect enough evidence to prescribe a reinstall.
        if inventory.hostOS == "Linux",
           inventory.daemon != nil,
           inventory.bridge == nil {
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

    /// Old PATH copies the doctor can safely archive without sudo. System and
    /// package-manager paths remain diagnostic-only; only files below the SSH
    /// account's HOME are eligible, and only when their version differs from
    /// the binary that actually wins PATH resolution.
    static func shadowedBinaryCleanupCandidates(
        _ inventory: BinaryInventory
    ) -> [BinaryEntry] {
        guard let rawHome = inventory.homeDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawHome.isEmpty, rawHome.hasPrefix("/")
        else { return [] }
        let homePrefix = rawHome.hasSuffix("/") ? rawHome : rawHome + "/"
        var seen = Set<String>()
        var result: [BinaryEntry] = []
        for (winner, shadowed) in [
            (inventory.cli, inventory.cliShadowed),
            (inventory.daemon, inventory.daemonShadowed),
        ] {
            guard let winner else { continue }
            for candidate in shadowed where candidate.version != winner.version {
                let path = (candidate.path as NSString).standardizingPath
                guard path.hasPrefix(homePrefix),
                      !path.contains("\n"),
                      !candidate.identity.isEmpty,
                      seen.insert(path).inserted
                else { continue }
                result.append(BinaryEntry(
                    path: path, version: candidate.version, identity: candidate.identity
                ))
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    /// Moves exact HOME-owned paths supplied on stdin into a unique,
    /// path-preserving backup. Nothing computed by the client enters shell
    /// syntax, and physical HOME/backup guards refuse symlink escapes.
    static let shadowedBinaryArchiveCommand =
        #"sh -c 'tab=$(printf "\t"); home_real=$(realpath "$HOME") || exit 65; root="$HOME/.term-mesh"; parent="$root/cleanup-backups"; [ ! -L "$root" ] && [ ! -L "$parent" ] || exit 66; mkdir -p "$parent" || exit 65; [ ! -L "$root" ] && [ ! -L "$parent" ] || exit 66; root_real=$(realpath "$root") || exit 65; parent_real=$(realpath "$parent") || exit 65; [ "$root_real" = "$home_real/.term-mesh" ] && [ "$parent_real" = "$root_real/cleanup-backups" ] || exit 66; backup=$(mktemp -d "$parent/archive-XXXXXXXX") || exit 65; while IFS="$tab" read -r p expected_version expected_identity; do case "$p" in "$HOME"/*) ;; *) echo "protected=$p"; continue ;; esac; if [ ! -f "$p" ]; then echo "missing=$p"; continue; fi; rel_lex=${p#"$HOME"/}; physical=$(realpath "$p" 2>/dev/null) || { echo "failed=$p"; continue; }; [ "$physical" = "$home_real/$rel_lex" ] || { echo "protected=$p"; continue; }; actual_identity=$(stat -f "%d:%i:%m:%z" "$p" 2>/dev/null || stat -c "%d:%i:%Y:%s" "$p" 2>/dev/null); actual_version=$("$p" --version 2>/dev/null | head -1); if [ "$actual_identity" != "$expected_identity" ] || [ "$actual_version" != "$expected_version" ]; then echo "changed=$p"; continue; fi; dest="$backup/$rel_lex"; mkdir -p "$(dirname "$dest")" || { echo "failed=$p"; continue; }; [ ! -e "$dest" ] && [ ! -L "$dest" ] || { echo "failed=$p"; continue; }; final_identity=$(stat -f "%d:%i:%m:%z" "$p" 2>/dev/null || stat -c "%d:%i:%Y:%s" "$p" 2>/dev/null); [ "$final_identity" = "$expected_identity" ] || { echo "changed=$p"; continue; }; if mv "$p" "$dest"; then echo "archived=$p"; else echo "failed=$p"; fi; done'"#

    struct BinaryArchiveResult: Equatable {
        var archived: [String] = []
        var protected: [String] = []
        var changed: [String] = []
        var missing: [String] = []
        var failed: [String] = []
    }

    static func archiveShadowedBinaries(
        sshTarget: String,
        port: Int?,
        identityFile: String?,
        candidates: [BinaryEntry]
    ) async throws -> BinaryArchiveResult {
        let safe = candidates.filter {
            $0.path.hasPrefix("/")
                && !$0.path.contains("\n") && !$0.path.contains("\r")
                && !$0.version.contains("\n") && !$0.version.contains("\t")
                && !$0.identity.isEmpty && !$0.identity.contains("\t")
        }
        guard safe.count == candidates.count, !safe.isEmpty else {
            return BinaryArchiveResult(failed: candidates.map(\.path))
        }
        let payload = safe.map {
            "\($0.path)\t\($0.version)\t\($0.identity)"
        }.joined(separator: "\n") + "\n"
        let output = try await runRemote(
            sshTarget: sshTarget,
            port: port,
            identityFile: identityFile,
            command: shadowedBinaryArchiveCommand,
            timeoutSeconds: 20,
            input: Data(payload.utf8)
        )
        return parseBinaryArchiveResult(output)
    }

    static func parseBinaryArchiveResult(_ output: String) -> BinaryArchiveResult {
        var result = BinaryArchiveResult()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if let value = text.dropPrefixIfPresent("archived=") {
                result.archived.append(value)
            } else if let value = text.dropPrefixIfPresent("protected=") {
                result.protected.append(value)
            } else if let value = text.dropPrefixIfPresent("changed=") {
                result.changed.append(value)
            } else if let value = text.dropPrefixIfPresent("missing=") {
                result.missing.append(value)
            } else if let value = text.dropPrefixIfPresent("failed=") {
                result.failed.append(value)
            }
        }
        return result
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

    static func parseHealthBaseline(_ stdout: String) -> PeerHostHealthBaseline? {
        let expectedKeys: Set<String> = [
            "health-service-active", "health-control-path", "health-control-present",
            "health-control-rpc", "health-peer-path", "health-peer-present",
            "health-relay-lag-5m", "health-resume-heal-5m",
            "health-protocol-mismatch-5m",
        ]
        var fields: [String: String] = [:]
        for line in stdout.split(whereSeparator: { $0.isNewline }) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let split = text.firstIndex(of: "=") else { continue }
            let key = String(text[..<split])
            guard expectedKeys.contains(key) else { continue }
            // Login output may contain a stale-looking sentinel before the
            // fixed probe runs. The probe block is last, matching the version
            // parser's established "last valid line wins" contract.
            fields[key] = String(text[text.index(after: split)...])
        }
        guard expectedKeys.allSatisfy({ fields[$0] != nil }) else { return nil }
        let controlRPC: PeerHostControlRPCStatus
        switch fields["health-control-rpc"] {
        case "1": controlRPC = .available
        case "unknown": controlRPC = .probeUnavailable
        default: controlRPC = .unavailable
        }
        return PeerHostHealthBaseline(
            serviceActive: fields["health-service-active"] == "1",
            // Not in `expectedKeys`: a host that could not read the daemon's
            // mountinfo still has a perfectly good baseline, and losing the
            // whole verdict over a missing explanatory field would be a worse
            // failure than the one this field was added to explain.
            daemonTmpRoot: fields["health-daemon-tmp-root"] ?? "",
            controlPath: fields["health-control-path"] ?? "/tmp/term-meshd.sock",
            controlPathPresent: fields["health-control-present"] == "1",
            controlRPC: controlRPC,
            peerPath: fields["health-peer-path"] ?? "",
            peerPathPresent: fields["health-peer-present"] == "1",
            relayLagCount: Int(fields["health-relay-lag-5m"] ?? "") ?? 0,
            resumeHealCount: Int(fields["health-resume-heal-5m"] ?? "") ?? 0,
            protocolMismatchCount: Int(fields["health-protocol-mismatch-5m"] ?? "") ?? 0
        )
    }

    static func healthBaseline(
        sshTarget: String,
        port: Int?,
        identityFile: String?
    ) async -> PeerHostHealthBaseline? {
        guard let output = try? await runRemote(
            sshTarget: sshTarget, port: port, identityFile: identityFile,
            command: healthBaselineCommand, timeoutSeconds: 20
        ) else { return nil }
        return parseHealthBaseline(output)
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
