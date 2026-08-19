import AppKit
import Foundation

/// The one gate every diagnostics bundle passes through before it can be
/// copied, saved, or put in a URL.
///
/// A bug report goes to a public issue tracker, so the question is not "is
/// this field sensitive" but "can this bundle be published as-is". Two
/// properties follow from that:
///
/// - **Redaction is not optional.** `DiagnosticsReport` has no path to text
///   that skips this type. A future section author cannot forget to call it,
///   because there is nothing else to call.
/// - **Identity is removed, correlation is kept.** A host becomes `<host-1>`
///   rather than disappearing: a maintainer still needs to see that the same
///   host appears in three sections. Deleting the value would destroy the
///   thing that makes a report readable; aliasing keeps the shape and drops
///   the name.
///
/// Aliases are stable within one report and meaningless across reports, which
/// is the correct trade: within a bundle they carry the relationship, and
/// between bundles they leak nothing.
///
/// Main-actor bound because the credential rules it delegates to live on
/// `AgentSession`, and because every bundle it serves is assembled from
/// AppKit and `AppDelegate` state that is main-actor bound anyway. Nothing
/// here needs a background thread — the work is regex over a few kilobytes.
@MainActor
final class DiagnosticsRedactor {
    private let homeDirectory: String
    private let userName: String
    private let localHostName: String
    private var aliases: [String: String] = [:]
    private var nextHostIndex = 1

    /// Usernames shorter than this are left alone. A global substring swap of
    /// a two-character name would corrupt unrelated text (`ci` appears inside
    /// ordinary words), and a corrupted bundle is worse than a named one —
    /// it sends the reader chasing a defect that the redactor invented.
    private static let minimumRedactableNameLength = 3

    init(
        homeDirectory: String = NSHomeDirectory(),
        userName: String = NSUserName(),
        localHostName: String = ProcessInfo.processInfo.hostName,
        seedHosts: [String] = []
    ) {
        self.homeDirectory = homeDirectory
        self.userName = userName
        self.localHostName = localHostName
        // Seeding first makes the numbering follow the caller's order (the
        // peer host list) instead of whichever section happened to mention a
        // host first, so `<host-1>` means the same thing across two reports
        // from the same machine.
        for host in seedHosts { _ = alias(forHost: host) }
    }

    /// Order is load-bearing. Credentials go first because a token may sit
    /// inside a path or a URI that the later rules would rewrite around,
    /// leaving the secret behind in a shape the token patterns no longer
    /// match. Host aliasing precedes path rewriting for the same reason: an
    /// `ssh://user@host/path` loses its host to `<host-1>` before the path
    /// rules touch anything.
    func redact(_ text: String) -> String {
        var result = AgentSession.redactingCredentials(text)
        result = redactingHosts(result)
        result = redactingIdentity(result)
        return result
    }

    /// Assign (or reuse) the alias for one host. Exposed so a caller that
    /// already knows a host's identity can pre-register it in a chosen order.
    @discardableResult
    func alias(forHost host: String) -> String {
        let key = normalizedHost(host)
        guard !key.isEmpty else { return host }
        if let existing = aliases[key] { return existing }
        let alias = "<host-\(nextHostIndex)>"
        nextHostIndex += 1
        aliases[key] = alias
        return alias
    }

    /// Strip anything that is addressing rather than identity: a `user@`
    /// prefix, a `:port` suffix, and surrounding whitespace. `root@10.0.0.1`
    /// and `10.0.0.1:22` are the same host and must share an alias, otherwise
    /// the bundle reads as if two machines were involved.
    private func normalizedHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let atIndex = value.lastIndex(of: "@") {
            value = String(value[value.index(after: atIndex)...])
        }
        // Only strip a port when the remainder is unambiguous. An IPv6
        // literal is full of colons and splitting it would produce garbage.
        if !value.contains("["), value.filter({ $0 == ":" }).count == 1,
           let colonIndex = value.lastIndex(of: ":"),
           value[value.index(after: colonIndex)...].allSatisfy(\.isNumber) {
            value = String(value[..<colonIndex])
        }
        return value.lowercased()
    }

    private func redactingHosts(_ text: String) -> String {
        var result = text
        // Longest first: a seeded host may be a suffix of another
        // (`web.example.com` inside `api.web.example.com`), and replacing the
        // short one first would leave a spliced alias in the middle of the
        // long one.
        for key in aliases.keys.sorted(by: { $0.count > $1.count }) {
            guard let alias = aliases[key] else { continue }
            result = result.replacingOccurrences(of: key, with: alias, options: .caseInsensitive)
        }
        result = redactingBareIPv4(result)
        if localHostName.count >= Self.minimumRedactableNameLength {
            result = result.replacingOccurrences(
                of: localHostName,
                with: "<local-host>",
                options: .caseInsensitive
            )
        }
        return redactingRemoteAccounts(result)
    }

    /// Aliasing a host leaves `alice@<host-1>` behind, and the account name is
    /// as identifying as the hostname was. This runs after host aliasing and
    /// anchors on the alias, so it can only ever match text the redactor
    /// itself just produced — no risk of eating an unrelated `@`.
    ///
    /// System accounts are kept verbatim. "runs as root" versus "runs as a
    /// login user" is a real diagnostic signal — it is the difference between
    /// a system-scope and a user-scope install, which is exactly the
    /// distinction a peer-host report exists to make — and `root` names a
    /// role, not a person.
    private func redactingRemoteAccounts(_ text: String) -> String {
        guard let regex = Self.aliasedAccountPattern else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges == 2 else { continue }
            let account = nsText.substring(with: match.range(at: 1))
            guard !Self.systemAccounts.contains(account.lowercased()) else { continue }
            result = (result as NSString).replacingCharacters(
                in: match.range(at: 1),
                with: "<user>"
            )
        }
        return result
    }

    private static let systemAccounts: Set<String> = ["root", "daemon", "nobody"]

    /// An account immediately followed by an alias this redactor emitted.
    private static let aliasedAccountPattern = try? NSRegularExpression(
        pattern: #"([A-Za-z0-9._-]+)@(?=<host-\d+>|<local-host>)"#
    )

    /// Any IPv4 literal that survived host aliasing. Loopback stays: it names
    /// no machine, and a reader needs to tell "the daemon listened on
    /// localhost" apart from "the daemon listened on a routable address" —
    /// that distinction has already been the difference between a real defect
    /// and a misconfiguration.
    private func redactingBareIPv4(_ text: String) -> String {
        guard let regex = Self.ipv4Pattern else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        var result = text
        for match in matches.reversed() {
            let literal = nsText.substring(with: match.range)
            guard !Self.isNonIdentifyingIPv4(literal) else { continue }
            let replacement = alias(forHost: literal)
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }
        return result
    }

    private static func isNonIdentifyingIPv4(_ literal: String) -> Bool {
        literal.hasPrefix("127.") || literal == "0.0.0.0" || literal == "255.255.255.255"
    }

    /// Four dotted octets. Deliberately not anchored to word boundaries on
    /// the dots so `1.2.3.4:22` still matches; the octet count is what keeps
    /// this from eating a three-component version string like `0.196.0`.
    private static let ipv4Pattern = try? NSRegularExpression(
        pattern: #"\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b"#
    )

    private func redactingIdentity(_ text: String) -> String {
        var result = text
        if homeDirectory.count >= Self.minimumRedactableNameLength {
            result = result.replacingOccurrences(of: homeDirectory, with: "~")
        }
        if userName.count >= Self.minimumRedactableNameLength {
            result = result.replacingOccurrences(of: userName, with: "<user>")
        }
        return result
    }
}

/// One peer host as the app knows it, without asking the host anything.
///
/// Everything here is already in `RemoteHostStore`, so a bundle can name the
/// hosts involved without an SSH round trip. `healthBaseline` is the
/// exception: it comes from a probe, so it is nil unless a caller that had
/// one — the host editor, or the failure-detection capture — supplies it.
struct PeerHostSnapshot {
    var id: String
    var displayName: String
    var state: String
    var sshTarget: String?
    var remoteSockPath: String?
    var activeSockPath: String
    var servingAppVersion: String?
    var workspaceCount: Int
    var teamCount: Int
    var isLaunchable: Bool
    /// Rendered readiness rather than a yes/no. The host store distinguishes
    /// never-probed, probing, unreachable, and ready-but-without-the-route,
    /// and flattening those into a Bool would throw away exactly the kind of
    /// difference a report is read for — "we never asked" is not "the host
    /// said no".
    var teamHostReadiness: String
    var failureReason: String?
    var healthBaseline: PeerHostHealthBaseline?
}

/// Which windows, workspaces, and panes existed when the snapshot was taken.
struct DiagnosticsContextSnapshot {
    struct WorkspaceEntry {
        var title: String
        var isSelected: Bool
        var terminalPanels: Int
        var browserPanels: Int
        var agentPanels: Int
        var remoteAgentPanes: Int
    }

    var windowCount: Int
    var workspaces: [WorkspaceEntry]
}

/// Everything a bundle renders from, captured at one instant.
///
/// Collection and rendering are separate on purpose. The failure-detection
/// capture has to freeze state at the moment a host goes unhealthy and render
/// it minutes later, when the app has moved on; fusing the two would make that
/// impossible. It also keeps the report a pure function of its input, so the
/// section formatting can be tested against a synthesized host instead of a
/// live machine — and it guarantees the Help menu never blocks on SSH.
struct DiagnosticsSnapshot {
    var capturedAt: Date
    /// Set when this snapshot was frozen by the capture store rather than
    /// taken live. A reader has to know which one they are holding: a frozen
    /// bundle describes a machine that has probably moved on since, and
    /// mistaking one for the other is how a stale reading sends an
    /// investigation after the wrong thing.
    var captureReason: String?
    var daemonStatus: TermMeshDaemon.DaemonStatus?
    var peerHosts: [PeerHostSnapshot]
    var context: DiagnosticsContextSnapshot?
    var activityTail: [String]
    var daemonLogTail: [String]

    init(
        capturedAt: Date = Date(),
        captureReason: String? = nil,
        daemonStatus: TermMeshDaemon.DaemonStatus? = nil,
        peerHosts: [PeerHostSnapshot] = [],
        context: DiagnosticsContextSnapshot? = nil,
        activityTail: [String] = [],
        daemonLogTail: [String] = []
    ) {
        self.capturedAt = capturedAt
        self.captureReason = captureReason
        self.daemonStatus = daemonStatus
        self.peerHosts = peerHosts
        self.context = context
        self.activityTail = activityTail
        self.daemonLogTail = daemonLogTail
    }
}

/// A human-readable snapshot of what the app knows about itself, built for
/// pasting into a bug report.
///
/// Sections are assembled raw and redacted once at the end rather than being
/// individually sanitized. One pass over the whole text is what lets the
/// redactor keep a host's alias consistent across sections — a per-section
/// pass would have to rediscover the mapping each time, and any section that
/// forgot to run it would leak silently.
@MainActor
enum DiagnosticsReport {
    /// Lines of log tail carried in a bundle. Enough to show what led up to a
    /// failure; short enough that the bundle stays readable and fits beside a
    /// URL-length budget.
    static let activityTailLines = 80
    static let daemonLogTailLines = 40

    /// Build the redacted bundle. This is the only way text leaves this type.
    ///
    /// The redactor is passed as an optional rather than defaulted to a fresh
    /// instance: a default argument is evaluated in a nonisolated context, and
    /// `DiagnosticsRedactor` is main-actor bound. Constructing it here also
    /// lets the snapshot seed the host aliases, so `<host-1>` follows the
    /// peer host list rather than whichever section mentioned a host first.
    static func build(
        _ snapshot: DiagnosticsSnapshot,
        redactor: DiagnosticsRedactor? = nil
    ) -> String {
        let redactor = redactor ?? DiagnosticsRedactor(
            seedHosts: snapshot.peerHosts.compactMap(\.sshTarget)
        )
        return redactor.redact(rawText(snapshot))
    }

    /// Convenience for callers that only have the daemon status to hand; the
    /// rest of the snapshot is gathered from live app state.
    static func build(
        daemonStatus: TermMeshDaemon.DaemonStatus?,
        redactor: DiagnosticsRedactor? = nil
    ) -> String {
        build(current(daemonStatus: daemonStatus), redactor: redactor)
    }

    /// Capture what the app knows right now. Reads only in-memory state and
    /// two local log files — no SSH, no RPC — so it is safe to call from a
    /// menu action without leaving the user staring at a spinner.
    static func current(daemonStatus: TermMeshDaemon.DaemonStatus?) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            daemonStatus: daemonStatus,
            peerHosts: currentPeerHosts(),
            context: currentContext(),
            activityTail: DiagnosticsLogTail.tail(
                path: RemoteWorkLog.path,
                lines: activityTailLines
            ),
            daemonLogTail: DiagnosticsLogTail.tail(
                path: daemonStatus?.logPath ?? "",
                lines: daemonLogTailLines
            )
        )
    }

    private static func currentPeerHosts() -> [PeerHostSnapshot] {
        RemoteHostStore.shared.sortedHosts.map { host in
            var failureReason: String?
            if case .failed(let reason) = host.connectionState { failureReason = reason }
            return PeerHostSnapshot(
                id: host.id,
                displayName: host.displayName,
                state: describe(host.connectionState),
                sshTarget: host.sshTarget,
                remoteSockPath: host.remoteSockPath,
                activeSockPath: host.activeSockPath,
                servingAppVersion: host.servingAppVersion,
                workspaceCount: host.workspaces.count,
                teamCount: host.teams.count,
                isLaunchable: host.isLaunchable,
                teamHostReadiness: describe(host.teamHostReadiness),
                failureReason: failureReason,
                healthBaseline: nil
            )
        }
    }

    private static func describe(_ state: HostConnectionState) -> String {
        switch state {
        case .saved: return "saved"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .failed: return "failed"
        }
    }

    private static func currentContext() -> DiagnosticsContextSnapshot? {
        guard let appDelegate = AppDelegate.shared else { return nil }
        var workspaces: [DiagnosticsContextSnapshot.WorkspaceEntry] = []
        for context in appDelegate.mainWindowContexts.values {
            let selectedId = context.tabManager.selectedTabId
            for workspace in context.tabManager.tabs {
                var terminals = 0
                var browsers = 0
                var agents = 0
                for panel in workspace.panels.values {
                    switch panel.panelType {
                    case .terminal: terminals += 1
                    case .browser: browsers += 1
                    case .agent: agents += 1
                    }
                }
                workspaces.append(
                    .init(
                        title: workspace.customTitle ?? workspace.title,
                        isSelected: workspace.id == selectedId,
                        terminalPanels: terminals,
                        browserPanels: browsers,
                        agentPanels: agents,
                        remoteAgentPanes: workspace.remoteAgentPaneSessions.count
                    )
                )
            }
        }
        return DiagnosticsContextSnapshot(
            windowCount: appDelegate.mainWindowContexts.count,
            workspaces: workspaces
        )
    }

    /// Unredacted assembly. Private on purpose: the only caller is `build`,
    /// so there is no way to obtain the raw text from outside this file.
    private static func rawText(_ snapshot: DiagnosticsSnapshot) -> String {
        var lines: [String] = []
        lines.append("term-mesh diagnostics")
        lines.append("=====================")
        lines.append("Date: \(ISO8601DateFormatter().string(from: snapshot.capturedAt))")
        if let reason = snapshot.captureReason {
            lines.append("Captured automatically at the time of: \(reason)")
            lines.append("(frozen snapshot — the host may have changed since)")
        }
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        lines.append("App: \(appVersion) (\(buildNumber))")

        // Early on purpose. The issue URL carries the bundle head-first under a
        // byte budget, so anything that must survive truncation has to be near
        // the top — and a recognised failure shape is the single most useful
        // line a triager can read.
        appendSignatures(DiagnosticsTriage.signatures(for: snapshot), to: &lines)
        appendDaemon(snapshot.daemonStatus, to: &lines)
        appendPeerHosts(snapshot.peerHosts, to: &lines)
        appendContext(snapshot.context, to: &lines)
        appendShellIntegration(to: &lines)
        appendIMERendering(to: &lines)
        appendLogTail("Remote Work log", snapshot.activityTail, to: &lines)
        appendLogTail("Daemon log", snapshot.daemonLogTail, to: &lines)

        return lines.joined(separator: "\n")
    }

    /// Names the shapes this build recognised, and says plainly when it
    /// recognised none. "No known signature" is information: it tells a
    /// triager the bundle was checked and did not match, rather than leaving
    /// them to wonder whether checking happened at all.
    private static func appendSignatures(
        _ signatures: [DiagnosticsSignature],
        to lines: inout [String]
    ) {
        lines.append("")
        lines.append("Signatures:")
        guard !signatures.isEmpty else {
            lines.append("  (none matched — this build did not recognise the failure shape)")
            return
        }
        for signature in signatures {
            lines.append("  \(signature.id)")
            lines.append("    \(signature.summary)")
            if let known = signature.knownIssue {
                lines.append("    known issue: #\(known.number) — \(known.title)")
                lines.append("    workaround: \(known.workaround)")
            }
        }
    }

    private static func appendPeerHosts(_ hosts: [PeerHostSnapshot], to lines: inout [String]) {
        lines.append("")
        lines.append("Peer Hosts:")
        guard !hosts.isEmpty else {
            lines.append("  (none configured)")
            return
        }
        for host in hosts {
            lines.append("  \(host.displayName) [\(host.state)]")
            if let reason = host.failureReason { lines.append("    failure: \(reason)") }
            if let ssh = host.sshTarget, !ssh.isEmpty { lines.append("    ssh: \(ssh)") }
            lines.append("    serving version: \(host.servingAppVersion ?? "unknown")")
            if let remote = host.remoteSockPath, !remote.isEmpty {
                lines.append("    remote sock: \(remote)")
            }
            if !host.activeSockPath.isEmpty {
                lines.append("    active sock: \(host.activeSockPath)")
            }
            lines.append("    workspaces: \(host.workspaceCount), teams: \(host.teamCount)")
            lines.append("    launchable: \(host.isLaunchable), team host: \(host.teamHostReadiness)")
            appendHealthBaseline(host.healthBaseline, to: &lines)
        }
    }

    /// Emit the probe's own `health-*` keys rather than the verdict they add
    /// up to. A rendered verdict — "control unavailable" — states a conclusion
    /// about the host; the raw fields state what was measured, and the two
    /// come apart exactly when the probe is wrong about the host. That gap is
    /// what a bug report needs to show.
    private static func appendHealthBaseline(
        _ health: PeerHostHealthBaseline?,
        to lines: inout [String]
    ) {
        guard let health else { return }
        lines.append("    health baseline (verdict: \(health.verdict.rawValue)):")
        let fields: [(String, String)] = [
            ("health-service-active", health.serviceActive ? "1" : "0"),
            ("health-control-path", health.controlPath),
            ("health-control-present", health.controlPathPresent ? "1" : "0"),
            ("health-control-rpc", rawValue(health.controlRPC)),
            ("health-peer-path", health.peerPath),
            ("health-peer-present", health.peerPathPresent ? "1" : "0"),
            ("health-relay-lag-5m", String(health.relayLagCount)),
            ("health-resume-heal-5m", String(health.resumeHealCount)),
            ("health-protocol-mismatch-5m", String(health.protocolMismatchCount)),
        ]
        for (key, value) in fields {
            lines.append("      \(key)=\(value)")
        }
    }

    /// Keeps the four states apart. `ready (no team route)` in particular is a
    /// working host that simply cannot carry team work — reporting it the same
    /// as an unreachable one would send a reader after the connection instead
    /// of the capability.
    private static func describe(_ readiness: TeamHostReadiness) -> String {
        switch readiness {
        case .unresolved: return "unresolved"
        case .probing: return "probing"
        case .unreachable: return "unreachable"
        case .ready(let snapshot):
            return snapshot.lacksRemoteTeamRoute ? "ready (no team route)" : "ready"
        }
    }

    /// Round-trips back to the token the probe emitted, so the bundle shows
    /// the measurement rather than this app's reading of it. `unknown` is the
    /// one that matters: it means the probe could not run, which is a
    /// different claim from "the daemon did not answer" and must not be
    /// flattened into it.
    private static func rawValue(_ status: PeerHostControlRPCStatus) -> String {
        switch status {
        case .available: return "1"
        case .unavailable: return "0"
        case .probeUnavailable: return "unknown"
        }
    }

    private static func appendContext(
        _ context: DiagnosticsContextSnapshot?,
        to lines: inout [String]
    ) {
        lines.append("")
        lines.append("Context:")
        guard let context else {
            lines.append("  (no app delegate)")
            return
        }
        lines.append("  windows: \(context.windowCount), workspaces: \(context.workspaces.count)")
        for workspace in context.workspaces {
            let marker = workspace.isSelected ? "*" : " "
            var line = "  \(marker) \(workspace.title): term=\(workspace.terminalPanels)"
            line += " browser=\(workspace.browserPanels) agent=\(workspace.agentPanels)"
            if workspace.remoteAgentPanes > 0 {
                line += " remoteAgent=\(workspace.remoteAgentPanes)"
            }
            lines.append(line)
        }
    }

    private static func appendLogTail(_ title: String, _ tail: [String], to lines: inout [String]) {
        lines.append("")
        lines.append("\(title) (last \(tail.count)):")
        guard !tail.isEmpty else {
            lines.append("  (empty or unreadable)")
            return
        }
        for line in tail {
            lines.append("  \(line)")
        }
    }

    private static func appendDaemon(
        _ status: TermMeshDaemon.DaemonStatus?,
        to lines: inout [String]
    ) {
        guard let status else {
            lines.append("Daemon: status not available")
            return
        }
        lines.append("Variant: \(status.appVariant)")
        lines.append("Bundle ID: \(status.bundleIdentifier)")
        lines.append("")
        lines.append("Daemon: \(status.connected ? "connected" : "not connected")")
        if let pid = status.pid { lines.append("PID: \(pid)") }
        if let uptime = status.uptimeSecs { lines.append("Uptime: \(formatUptime(uptime))") }
        lines.append("Binary: \(status.binaryPath ?? "(not found)") [\(status.binaryExists ? "exists" : "MISSING")]")
        lines.append("Socket: \(status.socketPath) [\(status.socketExists ? "exists" : "MISSING")]")
        lines.append("Log: \(status.logPath) [\(status.logExists ? "exists" : "MISSING")]")

        guard !status.subsystems.isEmpty else { return }
        lines.append("")
        lines.append("Subsystems:")
        for sub in status.subsystems {
            var line = "  \(sub.name): \(sub.status)"
            if let detail = sub.detail { line += " (\(detail))" }
            lines.append(line)
        }
    }

    private static func appendShellIntegration(to lines: inout [String]) {
        lines.append("")
        lines.append("Shell Integration:")
        guard let appDelegate = AppDelegate.shared else { return }
        var panelIndex = 0
        for context in appDelegate.mainWindowContexts.values {
            for workspace in context.tabManager.tabs {
                for panelId in workspace.panels.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                    guard workspace.panels[panelId] is TerminalPanel else { continue }
                    let health = workspace.shellIntegrationHealth[panelId]
                        ?? ShellIntegrationHealth(createdAt: workspace.createdAt)
                    let now = Date()
                    let pwdAge: String
                    if let lastPwd = health.lastReportPwd {
                        pwdAge = "last \(Int(now.timeIntervalSince(lastPwd)))s ago"
                    } else {
                        pwdAge = "never"
                    }
                    let age = Int(now.timeIntervalSince(health.createdAt))
                    let title = workspace.customTitle ?? workspace.title
                    let panelLabel = workspace.panelTitles[panelId] ?? String(panelId.uuidString.prefix(8))
                    panelIndex += 1
                    lines.append("  \(title)/\(panelLabel): \(health.status.rawValue) (pwd: \(health.reportPwdCount) msgs, \(pwdAge), tty: \(health.reportTtyCount > 0 ? "yes" : "no"), git: \(health.reportGitBranchCount > 0 ? "yes" : "no"), age: \(age)s)")
                }
            }
        }
        if panelIndex == 0 {
            lines.append("  (no terminal panels)")
        }
    }

    private static func appendIMERendering(to lines: inout [String]) {
        lines.append("")
        lines.append("IME Text Rendering:")
        guard let appDelegate = AppDelegate.shared,
              let window = appDelegate.mainWindowContexts.values.first?.window else {
            lines.append("  (no main window)")
            return
        }
        guard let tv = findIMETextView(in: window.contentView ?? NSView()) else {
            lines.append("  (IME text view not found — input bar may not be open)")
            return
        }
        let hasLM = tv.layoutManager != nil
        lines.append("  TextKit: \(hasLM ? "1 (layoutManager)" : "2 (textContentStorage)")")
        lines.append("  textColor: \(tv.textColor?.description ?? "nil")")
        lines.append("  insertionPointColor: \(tv.insertionPointColor.description)")
        lines.append("  drawsBackground: \(tv.drawsBackground)")
        lines.append("  isRichText: \(tv.isRichText)")
        lines.append("  font: \(tv.font?.displayName ?? "nil") \(tv.font?.pointSize ?? 0)pt")
        lines.append("  frame: \(Int(tv.frame.width))x\(Int(tv.frame.height))")
        if let storage = tv.textStorage {
            lines.append("  textStorage.length: \(storage.length)")
            if storage.length > 0 {
                let attrs = storage.attributes(at: 0, effectiveRange: nil)
                let fgDesc = (attrs[.foregroundColor] as? NSColor)?.description ?? "nil"
                lines.append("  textStorage[0].foregroundColor: \(fgDesc)")
            }
        }
        let typingFg = (tv.typingAttributes[.foregroundColor] as? NSColor)?.description ?? "nil"
        lines.append("  typingAttributes.foregroundColor: \(typingFg)")
        lines.append("  isHidden: \(tv.isHidden), alphaValue: \(tv.alphaValue)")
        lines.append("  wantsLayer: \(tv.wantsLayer), layer: \(tv.layer != nil ? "yes" : "nil")")
    }

    private static func findIMETextView(in view: NSView) -> NSTextView? {
        if let tv = view as? IMETextView { return tv }
        for sub in view.subviews {
            if let found = findIMETextView(in: sub) { return found }
        }
        return nil
    }

    private static func formatUptime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(secs)s" }
        return "\(secs)s"
    }
}

/// Reads the end of a log file without pulling the whole thing into memory.
///
/// `RemoteWorkLog` truncates at 8 MB and the daemon log at 50 MB, so reading a
/// log whole to keep its last 40 lines would allocate megabytes for kilobytes
/// of answer — on the main thread, in a menu action. Seeking to the tail keeps
/// the cost proportional to what is actually reported.
enum DiagnosticsLogTail {
    /// How far back to read. Comfortably more than `lines` worth of log at any
    /// plausible line length, so the cap is the line count rather than this.
    static let readBudgetBytes = 128 * 1024

    /// A single log line long enough to dominate the bundle is almost always a
    /// dumped payload rather than a message worth reading in full.
    static let maxLineLength = 500

    static func tail(path: String, lines: Int) -> [String] {
        guard !path.isEmpty,
              let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else { return [] }
        let budget = UInt64(readBudgetBytes)
        let start = end > budget ? end - budget : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return [] }

        var split = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        // A seek lands mid-line unless we started at byte zero. Drop that
        // fragment rather than reporting a truncated line as if the log
        // contained it.
        if start > 0, !split.isEmpty { split.removeFirst() }
        return split.suffix(lines).map { bounded(stripped($0)) }
    }

    /// Remove terminal control sequences.
    ///
    /// The daemon writes its log through `tracing`, which colours its output,
    /// so the file holds real `ESC[0m` bytes. Carried into a bundle they end
    /// up in a GitHub comment and in an agent's prompt as `[0m` litter that
    /// looks like corrupted data and buries the line it decorates. Worse, an
    /// escape sequence pasted into a terminal is not inert — a bug report
    /// should never be something you have to be careful about reading.
    ///
    /// Stripped here rather than in the redactor: this is encoding noise from
    /// reading a log file, and this is the type that reads log files. The
    /// redactor's job is secrets.
    static func stripped(_ line: String) -> String {
        var result = line
        if let regex = ansiPattern {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..<result.endIndex, in: result),
                withTemplate: ""
            )
        }
        // Whatever control bytes survived — a lone ESC, a stray BEL. Tab is
        // kept because log lines use it for alignment.
        return String(String.UnicodeScalarView(
            result.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\t" }
        ))
    }

    /// CSI (`ESC[…`), OSC (`ESC]…` terminated by BEL or ST), and any other
    /// two-character escape. Ordered so the longer forms match before the
    /// catch-all consumes their introducer.
    private static let ansiPattern = try? NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]"
            + "|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)"
            + "|\u{1B}."
    )

    private static func bounded(_ line: String) -> String {
        guard line.count > maxLineLength else { return line }
        return String(line.prefix(maxLineLength)) + "… (truncated)"
    }
}
