import AppKit
import Bonsplit
import UniformTypeIdentifiers

/// Opens a link that came from terminal output according to its
/// `UntrustedURL` decision. Ported from ghostty-org macOS `UntrustedURLAlert`
/// (#14683), using term-mesh's sheet presentation.
enum UntrustedURLOpener {
    /// Call on the main thread, after the Ghostty action callback has returned:
    /// that callback holds the renderer mutex, and an alert or a focus change
    /// can reenter it.
    static func open(_ value: String) {
        let target = UntrustedURL(value)
        #if DEBUG
        dlog("terminal.link.untrusted decision=\(target.decision) target=\(target.displayString)")
        #endif
        switch target.decision {
        case .allow(let url):
            _ = NSWorkspace.shared.open(url)

        case .openInEditor(let url):
            openInEditor(url, displayString: target.displayString)

        case .confirm(let url):
            presentConfirmation(for: url, displayString: target.displayString)

        case .deny(let reason):
            presentBlock(reason: reason, displayString: target.displayString)
        }
    }

    private static func openInEditor(_ url: URL, displayString: String) {
        let workspace = NSWorkspace.shared
        guard let editor = workspace.urlForApplication(toOpen: .sourceCode)
            ?? workspace.urlForApplication(toOpen: .plainText)
        else {
            presentBlock(reason: .unsafeFile, displayString: displayString)
            return
        }
        workspace.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func presentConfirmation(for url: URL, displayString: String) {
        let workspace = NSWorkspace.shared
        let handler = workspace.urlForApplication(toOpen: url)
            .map { "\u{201c}\($0.deletingPathExtension().lastPathComponent)\u{201d}" }
            ?? "the default application"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSImage(named: NSImage.cautionName)
        alert.messageText = "Open Link from Terminal Output?"
        alert.informativeText = """
        This link will open in \(handler). Only continue if you recognize \
        and trust the destination.
        """
        alert.accessoryView = targetView(displayString)
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open Link")
        alert.presentAsSheet { response in
            // Cancel is deliberately the default action.
            guard response == .alertSecondButtonReturn else { return }
            _ = workspace.open(url)
        }
    }

    private static func presentBlock(reason: UntrustedURL.DenialReason, displayString: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.icon = NSImage(named: NSImage.cautionName)
        alert.messageText = "Term-Mesh Blocked This Link"
        alert.informativeText = reason.message
        alert.accessoryView = targetView(displayString)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Link")
        alert.presentAsSheet { response in
            // Keep blocked targets out of Launch Services. Copying the
            // displayed, sanitized value gives the user an explicit path
            // forward without adding a one-click policy bypass.
            guard response == .alertSecondButtonReturn else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(displayString, forType: .string)
        }
    }

    private static func targetView(_ target: String) -> NSView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 96))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = target
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        return scrollView
    }
}
