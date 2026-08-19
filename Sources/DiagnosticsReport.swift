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
    /// Build the redacted bundle. This is the only way text leaves this type.
    ///
    /// The redactor is passed as an optional rather than defaulted to a fresh
    /// instance: a default argument is evaluated in a nonisolated context, and
    /// `DiagnosticsRedactor` is main-actor bound. Constructing it inside the
    /// body keeps the call site a plain `build(daemonStatus:)`.
    static func build(
        daemonStatus: TermMeshDaemon.DaemonStatus?,
        redactor: DiagnosticsRedactor? = nil
    ) -> String {
        let redactor = redactor ?? DiagnosticsRedactor()
        return redactor.redact(rawText(daemonStatus: daemonStatus))
    }

    /// Unredacted assembly. Private on purpose: the only caller is `build`,
    /// so there is no way to obtain the raw text from outside this file.
    private static func rawText(daemonStatus: TermMeshDaemon.DaemonStatus?) -> String {
        var lines: [String] = []
        lines.append("term-mesh diagnostics")
        lines.append("=====================")
        lines.append("Date: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        lines.append("App: \(appVersion) (\(buildNumber))")

        appendDaemon(daemonStatus, to: &lines)
        appendShellIntegration(to: &lines)
        appendIMERendering(to: &lines)

        return lines.joined(separator: "\n")
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
