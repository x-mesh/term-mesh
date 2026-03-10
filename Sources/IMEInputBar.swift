import SwiftUI

/// A floating input bar for CJK IME composition.
///
/// Raw-mode TUI apps (ink/Claude Code) break IME preedit rendering because
/// they move the terminal cursor to unpredictable positions during re-renders.
/// This bar provides a native NSTextField where IME composition works perfectly,
/// then sends the completed text to the terminal on Enter.
///
/// - Enter: send text + execute
/// - Shift+Enter: new line
/// - Esc: close
///
/// Activated via Cmd+Shift+I (or menu: Edit → IME Input Bar).
struct IMEInputBar: View {
    let onSubmit: (String) -> Void
    let onBroadcast: ((String) -> Void)?
    let onClose: () -> Void

    @State private var text: String = ""
    @FocusState private var isFieldFocused: Bool

    private var lineCount: Int {
        max(1, text.components(separatedBy: "\n").count)
    }

    var body: some View {
        GeometryReader { geo in
            VStack {
                Spacer(minLength: 20)

                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "keyboard")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                            .padding(.top, 5)

                        IMETextEditor(
                            text: $text,
                            onSubmit: {
                                guard !text.isEmpty else { return }
                                onSubmit(text)
                                text = ""
                            },
                            onCancel: onClose
                        )
                        .frame(minHeight: 22, maxHeight: CGFloat(min(lineCount, 8)) * 20 + 10)
                        .focused($isFieldFocused)

                        HStack(spacing: 4) {
                            if !text.isEmpty {
                                Button(action: {
                                    onSubmit(text)
                                    text = ""
                                }) {
                                    Image(systemName: "paperplane.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.white)
                                        .frame(width: 22, height: 22)
                                        .background(Color.green)
                                        .cornerRadius(5)
                                }
                                .buttonStyle(.plain)
                                .help("Send to current pane (Enter)")

                                if onBroadcast != nil {
                                    Button(action: {
                                        onBroadcast?(text)
                                        text = ""
                                    }) {
                                        Image(systemName: "antenna.radiowaves.left.and.right")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(.white)
                                            .frame(width: 22, height: 22)
                                            .background(Color.orange)
                                            .cornerRadius(5)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Broadcast to all panes")
                                }
                            }

                            Button(action: { onClose() }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.secondary)
                                    .frame(width: 22, height: 22)
                                    .background(Color.primary.opacity(0.08))
                                    .cornerRadius(5)
                            }
                            .buttonStyle(.plain)
                            .help("Close (Esc)")
                        }
                        .padding(.top, 3)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    // Hint bar
                    HStack(spacing: 12) {
                        Text("Enter: send")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.6))
                        Text("Shift+Enter: new line")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.6))
                        Text("Esc: close")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .padding(.bottom, 6)
                }
                .background(.ultraThinMaterial)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
                .padding(.horizontal, geo.size.width * 0.12)

                Spacer(minLength: 20)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFieldFocused = true
            }
        }
    }
}

// MARK: - Custom NSTextView wrapper for Enter/Shift+Enter handling

struct IMETextEditor: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = IMETextView()
        textView.delegate = context.coordinator
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.submitHandler = onSubmit
        textView.cancelHandler = onCancel

        scrollView.documentView = textView
        context.coordinator.textView = textView

        // Focus the text view
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? IMETextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.submitHandler = onSubmit
        textView.cancelHandler = onCancel
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: IMETextEditor
        weak var textView: NSTextView?

        init(_ parent: IMETextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

/// Custom NSTextView that intercepts Enter (submit) vs Shift+Enter (newline).
final class IMETextView: NSTextView {
    var submitHandler: (() -> Void)?
    var cancelHandler: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Enter without Shift → submit
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) {
            submitHandler?()
            return
        }
        // Shift+Enter → insert newline (default behavior)
        if event.keyCode == 36 && event.modifierFlags.contains(.shift) {
            insertNewline(nil)
            return
        }
        // Escape → cancel
        if event.keyCode == 53 {
            cancelHandler?()
            return
        }
        super.keyDown(with: event)
    }
}
