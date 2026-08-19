import Foundation

/// An issue this build already knows about, with the answer attached.
struct KnownIssue: Equatable {
    let number: Int
    let title: String
    /// What the user can do right now, before any fix ships. Written for
    /// someone who has not read the issue.
    let workaround: String

    var url: URL? {
        URL(string: "https://github.com/\(AboutPanelView.repositorySlug)/issues/\(number)")
    }
}

/// A failure shape recognised in a diagnostics bundle.
///
/// The point is not classification for its own sake. Recognising a shape is
/// what lets the app answer instead of collecting: this project's own history
/// has a case where a maintainer needed SSH access, `nsenter`, and a mount
/// namespace comparison to reach a conclusion that the evidence already
/// contained. Every rule here is one such conclusion, written down once.
struct DiagnosticsSignature: Equatable {
    let id: String
    let summary: String
    let knownIssue: KnownIssue?
}

/// Matches bundles against known failure shapes.
///
/// Rules are data rather than branches so that adding one is an entry, not a
/// refactor — and so an unrecognised bundle still carries its own evidence
/// forward rather than being dropped on the floor.
enum DiagnosticsTriage {
    struct Rule {
        let id: String
        let summary: String
        let knownIssue: KnownIssue?
        let matches: (DiagnosticsSnapshot) -> Bool
    }

    static func signatures(for snapshot: DiagnosticsSnapshot) -> [DiagnosticsSignature] {
        rules.filter { $0.matches(snapshot) }
            .map { DiagnosticsSignature(id: $0.id, summary: $0.summary, knownIssue: $0.knownIssue) }
    }

    /// The first known issue among the matches, if any. Drives the "you do not
    /// need to file this" panel.
    static func firstKnownIssue(for snapshot: DiagnosticsSnapshot) -> (DiagnosticsSignature, KnownIssue)? {
        for signature in signatures(for: snapshot) {
            if let known = signature.knownIssue { return (signature, known) }
        }
        return nil
    }

    static let rules: [Rule] = [
        privateTmpControlSocket,
        leaderRPCInflightCollision,
    ]

    // MARK: - Seeds

    /// A system-scope install puts the control socket in `/tmp`, and the unit
    /// enables `PrivateTmp=true`, so the socket lands in a mount namespace
    /// nothing outside the daemon's own process tree can see. The daemon is
    /// healthy; every observer says it is not.
    ///
    /// All three conditions are required. `PrivateTmp` alone is fine when the
    /// socket lives under `/run`, and a socket under `/tmp` is fine when
    /// `/tmp` is shared — only the combination breaks, which is also why it
    /// took an investigation to see.
    static let privateTmpControlSocket = Rule(
        id: "peer.control-socket.privatetmp",
        summary: "A peer host's control socket is inside the daemon's private /tmp, so nothing outside the daemon can reach it.",
        knownIssue: KnownIssue(
            number: 315,
            title: "Control socket bound inside PrivateTmp on a system-scope Linux install",
            workaround: "Add TERMMESH_DAEMON_UNIX_PATH=/run/term-mesh/term-meshd.sock to the host's peer.env and restart term-meshd. The restart ends every session on that host, so pick the moment."
        ),
        matches: { snapshot in
            snapshot.peerHosts.contains { host in
                guard let health = host.healthBaseline else { return false }
                guard !health.controlPathPresent else { return false }
                guard health.controlPath.hasPrefix("/tmp/") else { return false }
                return isPrivateTmp(health.daemonTmpRoot)
            }
        }
    )

    /// systemd's private-tmp bind mount names the unit it was made for, which
    /// makes this an exact test rather than a guess about `/tmp` in general.
    static func isPrivateTmp(_ mountRoot: String) -> Bool {
        mountRoot.contains("systemd-private") && mountRoot.contains("term-meshd.service")
    }

    /// The CLI retries a failed leader call with the same `request_id` on
    /// purpose, so the viewer can return a cached outcome. Its own deadline is
    /// shorter than the daemon's, so the retry lands while the first attempt
    /// is still parked — and the daemon rejects it as a duplicate. Every
    /// command reports a collision it caused itself.
    static let leaderRPCInflightCollision = Rule(
        id: "peer.leader-rpc.inflight-collision",
        summary: "Leader commands are failing with a duplicate request id — the CLI's retry is colliding with its own first attempt.",
        knownIssue: KnownIssue(
            number: 314,
            title: "Every tm-agent command fails with \"request_id already in flight\"",
            workaround: "Run the command with TERMMESH_RPC_TIMEOUT=20 so the CLI waits longer than the daemon holds the request. Restarting term-meshd is not required and would kill every agent under it."
        ),
        matches: { snapshot in
            snapshot.allText.contains { $0.contains("request_id already in flight") }
        }
    )
}

extension DiagnosticsSnapshot {
    /// Every free-text line a rule might match on, in one place, so a rule
    /// cannot accidentally look at only one of the three sources.
    var allText: [String] {
        activityTail + daemonLogTail + peerHosts.compactMap(\.failureReason)
    }
}
