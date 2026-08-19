import AppKit
import SwiftUI

/// Fills the machine-knowable half of `.github/ISSUE_TEMPLATE/bug_report.yml`.
///
/// The template is a GitHub *issue form*, so each field can be prefilled by its
/// `id` in the query string. That is what makes the split possible: the app
/// answers every question it can measure — version, OS, chip, install method,
/// shell, diagnostics — and leaves `description`, `expected`, and `steps` blank.
/// Those three are the ones no probe can answer and the ones bug reports are
/// always missing.
///
/// `screenshots` is deliberately absent, and not because it is hard. Pixels
/// cannot be redacted: a terminal screenshot carries whatever the user was
/// doing, and this app is not going to put that on a path to a public tracker.
/// Taking one stays the user's decision, made outside the app.
struct GitHubIssueDraft {
    /// Values must match the dropdown options in `bug_report.yml` character for
    /// character. GitHub silently ignores a prefill it cannot match to an
    /// option, so a typo here fails invisibly — it just looks like the field
    /// was never filled. `GitHubIssueDraftTests` reads the template and
    /// compares, because a silent failure needs a loud test.
    enum Chip: String {
        case appleSilicon = "Apple Silicon (M1/M2/M3/M4)"
        case intel = "Intel"
    }

    enum InstallMethod: String {
        case homebrew = "Homebrew"
        case directDownload = "Direct download (DMG)"
        case builtFromSource = "Built from source"
    }

    var appVersion: String
    var buildNumber: String
    var macOSVersion: String
    var chip: Chip
    var installMethod: InstallMethod
    var shellInfo: String
    /// The redacted diagnostics bundle. Included head-first up to the URL
    /// budget; the rest travels via the clipboard.
    var diagnostics: String

    /// Browsers and GitHub both tolerate more, but a request line has to
    /// survive proxies and redirects intact, and a bug report that fails to
    /// open is worse than one that carries less. What does not fit goes on the
    /// clipboard, which has no such limit.
    static let maxURLBytes = 7500

    static let templateName = "bug_report.yml"

    func url(repositorySlug: String = AboutPanelView.repositorySlug) -> URL? {
        var items: [URLQueryItem] = [
            .init(name: "template", value: Self.templateName),
            .init(name: "term-mesh-version", value: "\(appVersion) (\(buildNumber))"),
            .init(name: "macos-version", value: macOSVersion),
            .init(name: "chip", value: chip.rawValue),
            .init(name: "install-method", value: installMethod.rawValue),
            .init(name: "shell-info", value: shellInfo),
        ]

        var components = URLComponents(string: "https://github.com/\(repositorySlug)/issues/new")
        components?.queryItems = items
        guard let withoutLogs = components?.url else { return nil }

        let spent = withoutLogs.absoluteString.utf8.count
        // "&logs=" plus room for the value to be worth including at all.
        let remaining = Self.maxURLBytes - spent - "&logs=".utf8.count
        if remaining > 200 {
            items.append(.init(name: "logs", value: Self.fitted(diagnostics, encodedBudget: remaining)))
            components?.queryItems = items
        }
        return components?.url
    }

    /// Trim the raw text until its percent-encoded form fits.
    ///
    /// Truncating the *encoded* string would be simpler and wrong: a cut
    /// landing inside a `%E1%84` escape produces a malformed URL. So the raw
    /// text is shortened and re-encoded until it fits, head-first — the head
    /// carries versions, peer hosts, and health fields, which is what a
    /// triager reads before anything else.
    static func fitted(_ text: String, encodedBudget: Int) -> String {
        let notice = "\n\n… truncated — the full diagnostics bundle is on your clipboard; paste it here."
        guard encodedLength(text) > encodedBudget else { return text }

        let budgetForBody = max(0, encodedBudget - encodedLength(notice))
        var low = 0
        var high = text.count
        while low < high {
            let mid = (low + high + 1) / 2
            if encodedLength(String(text.prefix(mid))) <= budgetForBody {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return String(text.prefix(low)) + notice
    }

    private static func encodedLength(_ text: String) -> Int {
        (text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text).utf8.count
    }
}

extension GitHubIssueDraft {
    /// Read the environment the report should describe.
    @MainActor
    static func current(diagnostics: String) -> GitHubIssueDraft {
        GitHubIssueDraft(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            chip: detectedChip(),
            installMethod: detectedInstallMethod(),
            shellInfo: detectedShellInfo(),
            diagnostics: diagnostics
        )
    }

    /// Ask the CPU rather than the compiler. `#if arch(arm64)` describes the
    /// binary, which under Rosetta is not the machine the user is reporting.
    static func detectedChip() -> Chip {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return .appleSilicon
        }
        var brand = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0) == 0 else {
            return .appleSilicon
        }
        return String(cString: brand).localizedCaseInsensitiveContains("apple") ? .appleSilicon : .intel
    }

    static let caskroomPaths = [
        "/opt/homebrew/Caskroom/term-mesh",
        "/usr/local/Caskroom/term-mesh",
    ]

    /// The Caskroom paths are a parameter so this stays a pure decision in
    /// tests. Probing the real filesystem would make the result depend on
    /// whether the machine running the tests happens to have term-mesh
    /// installed through brew — which is exactly the kind of environment
    /// coupling that makes a test lie.
    static func detectedInstallMethod(
        bundlePath: String = Bundle.main.bundlePath,
        caskroomPaths: [String] = caskroomPaths,
        fileManager: FileManager = .default
    ) -> InstallMethod {
        // A build that never left the build directory is a source build, no
        // matter what else is on disk.
        if bundlePath.contains("/DerivedData/") || !bundlePath.hasPrefix("/Applications/") {
            return .builtFromSource
        }
        if caskroomPaths.contains(where: { fileManager.fileExists(atPath: $0) }) {
            return .homebrew
        }
        return .directDownload
    }

    /// Which shell, and whether something is multiplexing inside it. Both have
    /// been the difference between "term-mesh is broken" and "the prompt is".
    static func detectedShellInfo(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        var parts: [String] = []
        parts.append("SHELL=\(environment["SHELL"] ?? "unknown")")
        if environment["TMUX"] != nil { parts.append("inside tmux") }
        if let term = environment["TERM"], !term.isEmpty { parts.append("TERM=\(term)") }
        return parts.joined(separator: ", ")
    }
}

/// Holds the bundle while it fills in.
///
/// The daemon status arrives over an RPC, and a daemon that has stopped
/// answering is one of the things people open this window to report. Blocking
/// the window on that call would make the feature fail exactly when it is
/// needed, so the bundle renders immediately from in-memory state and the
/// daemon section fills in when — or if — the answer arrives.
@MainActor
final class BugReportModel: ObservableObject {
    @Published private(set) var bundle: String = ""
    @Published private(set) var isAwaitingDaemon = false

    func refresh(daemon: (any DaemonService)? = TermMeshDaemon.shared) {
        bundle = DiagnosticsReport.build(daemonStatus: nil)
        isAwaitingDaemon = true
        DispatchQueue.global(qos: .userInitiated).async {
            let status = daemon?.daemonStatus()
            DispatchQueue.main.async {
                self.bundle = DiagnosticsReport.build(daemonStatus: status)
                self.isAwaitingDaemon = false
            }
        }
    }
}

/// Review-before-send. The bundle is shown in full, and nothing leaves the app
/// until the person reading it presses a button.
struct BugReportView: View {
    @ObservedObject var model: BugReportModel
    var onOpenIssue: (String) -> Void
    var onCopy: (String) -> Void
    var onSave: (String) -> Void

    private var bundle: String { model.bundle }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report an Issue")
                .font(.title2).bold()

            Text("These diagnostics describe this app's current state. Secrets, home paths, account names, and host addresses are already replaced — read them over anyway before sending, since only you can tell whether something here is sensitive.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(bundle)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor))
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text("Opening the issue copies the full bundle to your clipboard and fills in everything the app can measure. What it cannot know — what you were doing, what you expected, and how to reproduce it — is left for you.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Copy") { onCopy(bundle) }
                Button("Save…") { onSave(bundle) }
                if model.isAwaitingDaemon {
                    ProgressView().controlSize(.small)
                    Text("waiting for the daemon…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open GitHub Issue…") { onOpenIssue(bundle) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520)
    }
}

@MainActor
final class BugReportWindowController: NSWindowController, NSWindowDelegate {
    static let shared = BugReportWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Report an Issue"
        window.identifier = NSUserInterfaceItemIdentifier("term-mesh.bug-report")
        window.center()
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private let model = BugReportModel()

    /// Rebuild the bundle each time the window opens. A report describing the
    /// app as it was three hours ago is the failure this feature exists to fix.
    func show() {
        guard let window else { return }
        model.refresh()
        window.contentView = NSHostingView(
            rootView: BugReportView(
                model: model,
                onOpenIssue: { [weak self] text in self?.openIssue(with: text) },
                onCopy: { Self.copy($0) },
                onSave: { [weak self] text in self?.save(text) }
            )
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Prime the clipboard before opening the browser: the URL carries only as
    /// much of the bundle as fits, and the rest is one paste away rather than a
    /// trip back into the app.
    private func openIssue(with bundle: String) {
        Self.copy(bundle)
        guard let url = GitHubIssueDraft.current(diagnostics: bundle).url() else { return }
        NSWorkspace.shared.open(url)
    }

    private func save(_ text: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "term-mesh-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
