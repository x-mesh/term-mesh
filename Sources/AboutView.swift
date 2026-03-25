import AppKit
import SwiftUI

struct AcknowledgmentsView: View {
    private let content: String = {
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_LICENSES", withExtension: "md"),
           let text = try? String(contentsOf: url) {
            return text
        }
        return "Licenses file not found."
    }()

    var body: some View {
        ScrollView {
            Text(content)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("term-mesh.settings")
        window.center()
        window.contentView = NSHostingView(rootView: SettingsRootView())
        SettingsAboutTitlebarDebugStore.shared.applyCurrentOptions(to: window, for: .settings)
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Hard floor enforced by NSWindowDelegate — overrides any NSHostingView/SwiftUI resizing.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let min = SettingsAboutWindowKind.settings.minimumSize
        return NSSize(
            width: max(frameSize.width, min.width),
            height: max(frameSize.height, min.height)
        )
    }

    func show() {
        guard let window else { return }
        SettingsAboutTitlebarDebugStore.shared.applyCurrentOptions(to: window, for: .settings)
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }
}

final class SidebarDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SidebarDebugWindowController()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Sidebar Debug"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("term-mesh.sidebarDebug")
        window.center()
        window.contentView = NSHostingView(rootView: SidebarDebugView())
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AboutPanelView: View {
    @Environment(\.openURL) private var openURL

    private var version: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }
    private var build: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
    @State private var commitHash: String?
    private var copyright: String? { Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String }

    private func loadCommitHash() {
        // Fast path: bundle info or env (synchronous, no I/O)
        if let value = Bundle.main.infoDictionary?["TermMeshCommit"] as? String, !value.isEmpty {
            commitHash = value
            return
        }
        let env = termMeshEnv("COMMIT") ?? ""
        if !env.isEmpty {
            commitHash = env
            return
        }
        // Fallback: git subprocess — run off main thread
        Task.detached(priority: .utility) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            proc.arguments = ["rev-parse", "--short", "HEAD"]
            proc.currentDirectoryURL = Bundle.main.bundleURL
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            try? proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let hash = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            await MainActor.run { commitHash = hash.isEmpty ? nil : hash }
        }
    }

    var body: some View {
        VStack(alignment: .center) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .renderingMode(.original)
                .frame(width: 96, height: 96)

            VStack(alignment: .center, spacing: 32) {
                VStack(alignment: .center, spacing: 8) {
                    Text("Term-Mesh")
                        .bold()
                        .font(.title)
                        .foregroundColor(.primary)
                    Text("A Ghostty-based terminal with vertical tabs\nand a notification panel for macOS.")
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .textSelection(.enabled)

                VStack(spacing: 2) {
                    if let version {
                        AboutPropertyRow(label: "Version", text: version)
                    }
                    if let build {
                        AboutPropertyRow(label: "Build", text: build)
                    }
                    let commitText = commitHash ?? "—"
                    let commitURL = commitHash.flatMap { hash in
                        URL(string: "https://github.com/manaflow-ai/term-mesh/commit/\(hash)")
                    }
                    AboutPropertyRow(label: "Commit", text: commitText, url: commitURL)
                    AboutPropertyRow(label: "Author", text: "Jinwoo")
                }
                .frame(maxWidth: .infinity)

                HStack(spacing: 8) {
                    Button {
                        // No action — link removed
                    } label: {
                        Label("Docs", systemImage: "book")
                    }
                    .disabled(true)

                    Button {
                        // No action — link removed
                    } label: {
                        Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .disabled(true)

                    Button("Licenses") {
                        AcknowledgmentsWindowController.shared.show()
                    }
                }

                if let copy = copyright, !copy.isEmpty {
                    Text(copy)
                        .font(.caption)
                        .textSelection(.enabled)
                        .tint(.secondary)
                        .opacity(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 8)
        .padding(32)
        .frame(minWidth: 280)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .onAppear {
            if commitHash == nil { loadCommitHash() }
        }
    }
}


private struct AboutPropertyRow: View {
    private let label: String
    private let text: String
    private let url: URL?

    init(label: String, text: String, url: URL? = nil) {
        self.label = label
        self.text = text
        self.url = url
    }

    @ViewBuilder private var textView: some View {
        Text(text)
            .frame(width: 140, alignment: .leading)
            .padding(.leading, 2)
            .tint(.secondary)
            .opacity(0.8)
            .monospaced()
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .frame(width: 126, alignment: .trailing)
                .padding(.trailing, 2)
            if let url {
                Link(destination: url) {
                    textView
                }
            } else {
                textView
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity)
    }
}

struct AboutVisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let isEmphasized: Bool

    init(
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        isEmphasized: Bool = false
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.isEmphasized = isEmphasized
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.isEmphasized = isEmphasized
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffect = NSVisualEffectView()
        visualEffect.autoresizingMask = [.width, .height]
        return visualEffect
    }
}

