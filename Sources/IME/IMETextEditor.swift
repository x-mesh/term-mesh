import Bonsplit
import SwiftUI

// MARK: - Custom NSTextView wrapper for Enter/Shift+Enter/History handling

struct IMETextEditor: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void
    var onCtrlC: (() -> Void)? = nil
    /// Stop all team agents (Ctrl+Shift+C) — sends Ctrl+C to every agent panel.
    var onStopAllAgents: (() -> Void)? = nil
    var onSendKey: ((_ keycode: UInt16, _ mods: UInt32) -> Void)? = nil
    var onSubmitAndClose: (() -> Void)? = nil
    let onHistoryUp: () -> Void
    let onHistoryDown: () -> Void
    var onHistorySearch: (() -> Void)? = nil
    var onComposingChanged: ((Bool) -> Void)? = nil
    /// History entries for ghost suggestion prefix matching.
    var history: [String] = []
    /// Claude slash commands for ghost suggestion when text starts with "/".
    var slashCommands: [String] = []
    /// Whether the fuzzy history picker overlay is visible.
    var isHistoryPickerOpen: Bool = false
    // M1: History picker callbacks
    var onHistoryPickerToggle: (() -> Void)? = nil
    var onHistoryPickerMove: ((Int) -> Void)? = nil
    var onHistoryPickerConfirm: (() -> Void)? = nil
    var onHistoryPickerCancel: (() -> Void)? = nil
    // Slash command picker
    var isSlashPickerOpen: Bool = false
    var onSlashPickerMove: ((Int) -> Void)? = nil
    var onSlashPickerConfirm: (() -> Void)? = nil
    var onSlashPickerCancel: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// Resolve an explicit text color from the SwiftUI colorScheme.
    /// Using a concrete NSColor instead of NSColor.textColor avoids appearance-
    /// propagation mismatches between the NSHostingView and the embedded NSTextView.
    private var explicitTextColor: NSColor {
        colorScheme == .dark ? .white : .black
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let fg = explicitTextColor
        let imeFont = NSFont.monospacedSystemFont(ofSize: IMEInputBarSettings.fontSize, weight: .regular)
        let textView = IMETextView()
        textView.delegate = context.coordinator
        textView.font = imeFont
        textView.resolvedTextColor = fg
        textView.textColor = fg
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.insertionPointColor = fg
        // Explicitly set typing attributes so new keystrokes always get the right color/font,
        // regardless of NSTextView's rich-text attribute inheritance chain.
        textView.typingAttributes = [.foregroundColor: fg, .font: imeFont]
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        // Explicit marked text (IME composing) attributes — use concrete color
        textView.markedTextAttributes = [
            .foregroundColor: fg,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.cyan.withAlphaComponent(0.6),
        ]

        textView.submitHandler = onSubmit
        textView.cancelHandler = onCancel
        textView.ctrlCHandler = onCtrlC
        textView.stopAllAgentsHandler = onStopAllAgents
        textView.sendKeyHandler = onSendKey
        textView.submitAndCloseHandler = onSubmitAndClose
        textView.historyUpHandler = onHistoryUp
        textView.historyDownHandler = onHistoryDown
        textView.historySearchHandler = onHistorySearch
        textView.composingHandler = onComposingChanged
        // Q2: ghost suggestion source
        textView.historySource = history
        // Slash command ghost source
        textView.slashCommands = slashCommands
        // M1: picker state and callbacks
        textView.isHistoryPickerOpen = isHistoryPickerOpen
        textView.historyPickerToggleHandler = onHistoryPickerToggle
        textView.historyPickerMoveHandler = onHistoryPickerMove
        textView.historyPickerConfirmHandler = onHistoryPickerConfirm
        textView.historyPickerCancelHandler = onHistoryPickerCancel
        // Slash command picker state and callbacks
        textView.isSlashPickerOpen = isSlashPickerOpen
        textView.slashPickerMoveHandler = onSlashPickerMove
        textView.slashPickerConfirmHandler = onSlashPickerConfirm
        textView.slashPickerCancelHandler = onSlashPickerCancel

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // Focus the text view
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let textView = scrollView.documentView as? IMETextView {
            textView.undoManager?.removeAllActions()
            // Cancel any deferred applyHighlightingDeferred calls so they don't fire
            // after the view has been removed from the SwiftUI tree (TERM-MESH-9 fix).
            NSObject.cancelPreviousPerformRequests(withTarget: textView)
        }
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? IMETextView else { return }
        if textView.submittableText() != text && !textView.hasMarkedText() {
            // Clear image attachments when text is reset externally (e.g. after submit)
            if text.isEmpty {
                textView.imageAttachments.removeAll()
            }
            textView.string = text
            textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
        }
        // Update colors when appearance changes (must run BEFORE applyRainbowKeywords).
        // Use explicit color derived from SwiftUI colorScheme to avoid NSColor.textColor
        // resolving against the wrong effectiveAppearance in NSViewRepresentable contexts.
        let fg = explicitTextColor
        let imeFont = textView.font ?? NSFont.monospacedSystemFont(ofSize: IMEInputBarSettings.fontSize, weight: .regular)
        textView.resolvedTextColor = fg
        textView.textColor = fg
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.insertionPointColor = fg
        textView.typingAttributes = [.foregroundColor: fg, .font: imeFont]
        textView.markedTextAttributes = [
            .foregroundColor: fg,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.cyan.withAlphaComponent(0.6),
        ]
        #if DEBUG
        let tvFrame = textView.frame
        dlog("ime.update fg=\(fg) font=\(imeFont.pointSize)pt frame=\(Int(tvFrame.width))x\(Int(tvFrame.height)) scheme=\(colorScheme == .dark ? "dark" : "light") textLen=\(textView.string.count)")
        #endif
        // Re-apply rainbow keywords AFTER all color resets so they aren't overwritten.
        // Use the deferred path (next run-loop iteration) to avoid layout invalidation
        // collisions with the current SwiftUI update cycle (TERM-MESH-9 fix).
        if !textView.hasMarkedText() {
            NSObject.cancelPreviousPerformRequests(
                withTarget: textView,
                selector: #selector(IMETextView.applyHighlightingDeferred),
                object: nil
            )
            textView.perform(
                #selector(IMETextView.applyHighlightingDeferred),
                with: nil,
                afterDelay: 0
            )
        }

        textView.submitHandler = onSubmit
        textView.cancelHandler = onCancel
        textView.ctrlCHandler = onCtrlC
        textView.stopAllAgentsHandler = onStopAllAgents
        textView.sendKeyHandler = onSendKey
        textView.submitAndCloseHandler = onSubmitAndClose
        textView.historyUpHandler = onHistoryUp
        textView.historyDownHandler = onHistoryDown
        textView.historySearchHandler = onHistorySearch
        textView.composingHandler = onComposingChanged
        // Q2: keep history source in sync for ghost suggestions
        textView.historySource = history
        // Slash command ghost source
        textView.slashCommands = slashCommands
        // M1: sync picker open state and callbacks
        textView.isHistoryPickerOpen = isHistoryPickerOpen
        textView.historyPickerToggleHandler = onHistoryPickerToggle
        textView.historyPickerMoveHandler = onHistoryPickerMove
        textView.historyPickerConfirmHandler = onHistoryPickerConfirm
        textView.historyPickerCancelHandler = onHistoryPickerCancel
        // Slash command picker state and callbacks
        textView.isSlashPickerOpen = isSlashPickerOpen
        textView.slashPickerMoveHandler = onSlashPickerMove
        textView.slashPickerConfirmHandler = onSlashPickerConfirm
        textView.slashPickerCancelHandler = onSlashPickerCancel
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: IMETextEditor
        weak var textView: NSTextView?

        init(_ parent: IMETextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? IMETextView else { return }
            parent.text = textView.submittableText()
        }
    }
}
