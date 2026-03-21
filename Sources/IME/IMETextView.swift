import AppKit

/// Virtual keycode constants (Carbon HIToolbox/Events.h).
private enum VK {
    static let a: UInt16           = 0x00  //  0  — 'a'
    static let v: UInt16           = 0x09  //  9  — 'v'
    static let c: UInt16           = 0x08  //  8  — 'c'
    static let e: UInt16           = 0x0E  // 14  — 'e'
    static let j: UInt16           = 0x26  // 38  — 'j'
    static let k: UInt16           = 0x28  // 40  — 'k'
    static let l: UInt16           = 0x25  // 37  — 'l'
    static let r: UInt16           = 0x0F  // 15  — 'r'
    static let u: UInt16           = 0x20  // 32  — 'u'  (Ctrl+U = clear line)
    static let w: UInt16           = 0x0D  // 13  — 'w'
    static let returnKey: UInt16   = 0x24  // 36  — Return
    static let tab: UInt16         = 0x30  // 48  — Tab
    static let delete: UInt16      = 0x33  // 51  — Backspace/Delete
    static let escape: UInt16      = 0x35  // 53  — Escape
    static let forwardDelete: UInt16 = 0x75 // 117 — Fn+Delete
    static let upArrow: UInt16     = 0x7E  // 126 — ↑
    static let downArrow: UInt16   = 0x7D  // 125 — ↓
    static let leftArrow: UInt16   = 0x7B  // 123 — ←
    static let rightArrow: UInt16  = 0x7C  // 124 — →
    static let equal: UInt16       = 0x18  // 24  — '=' (Cmd+= for zoom in)
    static let minus: UInt16       = 0x1B  // 27  — '-' (Cmd+- for zoom out)
    static let zero: UInt16        = 0x1D  // 29  — '0' (Cmd+0 for reset zoom)
}

/// Custom NSTextView that intercepts Enter (submit), Shift+Enter (newline),
/// Up/Down (history navigation), and Escape (cancel).
final class IMETextView: NSTextView {
    var submitHandler: (() -> Void)?
    var cancelHandler: (() -> Void)?
    var ctrlCHandler: (() -> Void)?
    /// Stop all team agents (Ctrl+Shift+C) — sends Ctrl+C to every agent panel.
    var stopAllAgentsHandler: (() -> Void)?
    var historyUpHandler: (() -> Void)?
    var historyDownHandler: (() -> Void)?
    var historySearchHandler: (() -> Void)?
    var composingHandler: ((Bool) -> Void)?
    /// Send a raw key event (keycode + mods) directly to the terminal surface,
    /// bypassing text input.  Used for Shift+Tab, Ctrl+Tab, and similar TUI shortcuts.
    var sendKeyHandler: ((_ keycode: UInt16, _ mods: UInt32) -> Void)?
    /// Submit current text and close the IME box in one action (Cmd+Enter).
    var submitAndCloseHandler: (() -> Void)?
    /// Tracks the last ESC keypress time for double-ESC detection.
    private var lastEscapeTime: TimeInterval = 0
    /// Double-ESC threshold in seconds.
    private let doubleEscapeThreshold: TimeInterval = 0.4

    /// Clear the undo stack when this view leaves its window to prevent
    /// dangling undo actions from crashing on Cmd+Z after the view is deallocated.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            undoManager?.removeAllActions()
        }
    }

    // MARK: - Q2: Ghost suggestion

    /// Suffix to display after the current text as a ghost/autocomplete hint.
    var ghostSuggestion: String = "" {
        didSet { if ghostSuggestion != oldValue { needsDisplay = true } }
    }

    /// History entries injected from IMEInputBar for prefix matching.
    var historySource: [String] = [] {
        didSet { updateGhostSuggestion() }
    }

    /// Claude slash command list for ghost suggestions (text starting with /).
    var slashCommands: [String] = [] {
        didSet { updateGhostSuggestion() }
    }

    // MARK: - M1: History picker routing

    /// True when the fuzzy history picker overlay is visible; routes Up/Down/Enter/Esc to picker.
    var isHistoryPickerOpen: Bool = false

    var historyPickerToggleHandler: (() -> Void)?
    var historyPickerMoveHandler: ((Int) -> Void)?     // -1 = up, 1 = down
    var historyPickerConfirmHandler: (() -> Void)?
    var historyPickerCancelHandler: (() -> Void)?

    // MARK: - Slash command picker routing

    /// True when the slash command picker is visible; takes priority over history picker.
    var isSlashPickerOpen: Bool = false

    var slashPickerMoveHandler: ((Int) -> Void)?
    var slashPickerConfirmHandler: (() -> Void)?
    var slashPickerCancelHandler: (() -> Void)?

    // MARK: - Focus activation

    override func mouseDown(with event: NSEvent) {
        // When the user clicks the IME box, ensure the app is activated and the
        // window is key — so typing works even when another app had focus.
        if let w = window, !w.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
        super.mouseDown(with: event)
    }

    // MARK: - Key equivalents

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd+C: if IME has no text selection but a terminal in the window does, copy the
        // terminal selection. This lets users mouse-select terminal text while IME is active
        // and copy it without losing IME focus.
        if event.keyCode == VK.c && flags == .command && selectedRange().length == 0 {
            if let surfaceView = Self.findTerminalSurfaceWithSelection(in: window) {
                surfaceView.copy(nil)
                return true
            }
        }

        // Cmd+= / Cmd+Plus → zoom in (increase IME font size)
        if event.keyCode == VK.equal && flags == .command {
            adjustFontSize(delta: 1)
            return true
        }

        // Cmd+- → zoom out (decrease IME font size)
        if event.keyCode == VK.minus && flags == .command {
            adjustFontSize(delta: -1)
            return true
        }

        // Cmd+0 → reset IME font size to default
        if event.keyCode == VK.zero && flags == .command {
            setFontSize(IMEInputBarSettings.defaultFontSize)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Font size adjustment

    private func adjustFontSize(delta: CGFloat) {
        let current = IMEInputBarSettings.fontSize
        let newSize = max(8, min(36, current + delta))
        setFontSize(Double(newSize))
    }

    private func setFontSize(_ size: Double) {
        UserDefaults.standard.set(size, forKey: "imeBarFontSize")
        font = NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }

    /// Walk the window's view hierarchy to find a GhosttyNSView that has an active selection.
    private static func findTerminalSurfaceWithSelection(in window: NSWindow?) -> GhosttyNSView? {
        guard let contentView = window?.contentView else { return nil }
        return findGhosttyViewWithSelection(in: contentView)
    }

    private static func findGhosttyViewWithSelection(in view: NSView) -> GhosttyNSView? {
        if let gv = view as? GhosttyNSView,
           let surface = gv.surface,
           ghostty_surface_has_selection(surface) {
            return gv
        }
        for sub in view.subviews {
            if let found = findGhosttyViewWithSelection(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        let kc   = event.keyCode
        let mods = event.modifierFlags

        switch kc {

        // Cmd+V → paste (ensure image paste works even if menu dispatch is intercepted)
        case VK.v where mods.contains(.command) && !mods.contains(.shift):
            paste(nil)

        // Return key: picker confirm when open; else Cmd+Enter/Shift+Enter/plain Enter
        case VK.returnKey:
            if isSlashPickerOpen {
                slashPickerConfirmHandler?()
            } else if isHistoryPickerOpen {
                historyPickerConfirmHandler?()
            } else {
                handleReturn(event: event, mods: mods)
            }

        // Ctrl+Shift+C → Stop all team agents (interrupt every agent panel)
        case VK.c where mods.contains(.control) && mods.contains(.shift):
            stopAllAgentsHandler?()

        // Ctrl+C → ETX interrupt (enables Claude double Ctrl+C exit)
        case VK.c where mods.contains(.control):
            ctrlCHandler?()

        // Ctrl+A → readline beginning-of-line
        case VK.a where mods.contains(.control):
            moveToBeginningOfLine(nil)

        // Ctrl+E → readline end-of-line
        case VK.e where mods.contains(.control):
            moveToEndOfLine(nil)

        // Ctrl+K → readline kill-to-end-of-paragraph
        case VK.k where mods.contains(.control):
            deleteToEndOfParagraph(nil)

        // Ctrl+U → readline kill-whole-line (clear all text, or forward to terminal if empty)
        case VK.u where mods.contains(.control):
            if string.isEmpty {
                sendKeyHandler?(VK.u, UInt32(GHOSTTY_MODS_CTRL.rawValue))
            } else {
                selectAll(nil)
                deleteBackward(nil)
            }

        // Ctrl+W → readline delete-word-backward
        case VK.w where mods.contains(.control):
            deleteWordBackward(nil)

        // Ctrl+J → alternative submit (same semantics as plain Enter, useful during IME)
        case VK.j where mods.contains(.control):
            commitAndSubmit(event: event, handler: submitHandler)

        // Ctrl+L → forward to terminal (Claude Code: clear conversation)
        case VK.l where mods.contains(.control):
            sendKeyHandler?(kc, UInt32(GHOSTTY_MODS_CTRL.rawValue))

        // Ctrl+R → open/close fuzzy history picker
        case VK.r where mods.contains(.control):
            historyPickerToggleHandler?()

        // Ctrl+Backspace → Ctrl+U (delete line) in terminal
        case VK.delete where mods.contains(.control):
            sendKeyHandler?(VK.u, UInt32(GHOSTTY_MODS_CTRL.rawValue))

        // Tab: ghost accept > Shift+Tab (accept suggestion) > Option+Tab (meta) > plain (terminal)
        case VK.tab:
            handleTab(event: event, mods: mods)

        // Cmd+Escape (close IME box), Esc (picker cancel or terminal forward)
        case VK.escape:
            handleEscape(mods: mods)

        // Option+Left → Alt+Left to terminal (word-level cursor movement)
        case VK.leftArrow where mods.contains(.option) && !hasMarkedText():
            sendKeyHandler?(kc, UInt32(GHOSTTY_MODS_ALT.rawValue))

        // Option+Right → Alt+Right to terminal (word-level cursor movement)
        case VK.rightArrow where mods.contains(.option) && !hasMarkedText():
            sendKeyHandler?(kc, UInt32(GHOSTTY_MODS_ALT.rawValue))

        // Up: picker nav when open; else Option+Up (terminal) or plain Up (history)
        case VK.upArrow:
            if isSlashPickerOpen {
                slashPickerMoveHandler?(-1)
            } else if isHistoryPickerOpen {
                historyPickerMoveHandler?(-1)
            } else {
                handleUpArrow(event: event, mods: mods)
            }

        // Down: picker nav when open; else Option+Down (terminal) or plain Down (history)
        case VK.downArrow:
            if isSlashPickerOpen {
                slashPickerMoveHandler?(1)
            } else if isHistoryPickerOpen {
                historyPickerMoveHandler?(1)
            } else {
                handleDownArrow(event: event, mods: mods)
            }

        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - Key sub-handlers

    /// Return/Enter: Cmd+Enter → submit+close, Shift+Enter → newline, plain Enter → submit.
    private func handleReturn(event: NSEvent, mods: NSEvent.ModifierFlags) {
        if mods.contains(.command) {
            commitAndSubmit(event: event, handler: submitAndCloseHandler)
        } else if mods.contains(.shift) {
            if hasMarkedText() {
                super.keyDown(with: event)
            } else {
                insertNewline(nil)
            }
        } else {
            commitAndSubmit(event: event, handler: submitHandler)
        }
    }

    /// If IME is composing, let it commit first (via super), then call handler.
    /// Strips the trailing newline that NSTextView.insertNewline may add.
    private func commitAndSubmit(event: NSEvent, handler: (() -> Void)?) {
        if hasMarkedText() {
            super.keyDown(with: event)
            if !hasMarkedText() {
                if string.hasSuffix("\n") { string = String(string.dropLast()) }
                handler?()
            }
        } else {
            handler?()
        }
    }

    /// Tab: Shift+Tab → accept suggestion, Option+Tab → meta-tab, plain Tab → ghost accept or terminal.
    /// Shift+Tab has no `!hasMarkedText()` guard — it always forwards.
    private func handleTab(event: NSEvent, mods: NSEvent.ModifierFlags) {
        if mods.contains(.shift) {
            // Shift+Tab → forward to terminal (Claude Code: accept suggestion)
            sendKeyHandler?(VK.tab, UInt32(GHOSTTY_MODS_SHIFT.rawValue))
        } else if mods.contains(.option) && !hasMarkedText() {
            // Option+Tab → Meta+Tab to terminal (Claude Code: toggle thinking)
            sendKeyHandler?(VK.tab, UInt32(GHOSTTY_MODS_ALT.rawValue))
        } else if !mods.contains(.command) && !hasMarkedText() {
            // Slash picker confirm > ghost suggestion accept > terminal tab
            if isSlashPickerOpen {
                slashPickerConfirmHandler?()
            } else if !ghostSuggestion.isEmpty {
                acceptGhostSuggestion()
            } else {
                sendKeyHandler?(VK.tab, 0)
            }
        } else {
            super.keyDown(with: event)
        }
    }

    /// Escape: Cmd+Escape closes the IME box; plain Escape closes picker (if open) or
    /// forwards to terminal with double-ESC → Ctrl+C detection.
    private func handleEscape(mods: NSEvent.ModifierFlags) {
        if mods.contains(.command) {
            cancelHandler?()
            return
        }
        if isSlashPickerOpen {
            slashPickerCancelHandler?()
            return
        }
        if isHistoryPickerOpen {
            historyPickerCancelHandler?()
            return
        }
        let now = CACurrentMediaTime()
        if (now - lastEscapeTime) < doubleEscapeThreshold {
            // Double-ESC: send Ctrl+C (keycode 'c' + ctrl mod) to cancel running command
            sendKeyHandler?(VK.c, UInt32(GHOSTTY_MODS_CTRL.rawValue))
            lastEscapeTime = 0  // reset to avoid triple-trigger
        } else {
            // Single ESC: forward to terminal
            sendKeyHandler?(VK.escape, 0)
            lastEscapeTime = now
        }
    }

    /// Up arrow: Option+Up → plain Up to terminal (Claude Code selection escape hatch);
    /// when IME is empty → plain Up to terminal; otherwise → history navigation.
    private func handleUpArrow(event: NSEvent, mods: NSEvent.ModifierFlags) {
        if mods.contains(.option) && !hasMarkedText() {
            sendKeyHandler?(VK.upArrow, 0)
        } else if !hasMarkedText() && string.isEmpty {
            // IME empty: forward plain Up to terminal for Claude Code picker navigation
            sendKeyHandler?(VK.upArrow, 0)
        } else if !hasMarkedText() && isCursorOnFirstLine() {
            historyUpHandler?()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Down arrow: Option+Down → plain Down to terminal (Claude Code selection escape hatch);
    /// when IME is empty → plain Down to terminal; otherwise → history navigation.
    private func handleDownArrow(event: NSEvent, mods: NSEvent.ModifierFlags) {
        if mods.contains(.option) && !hasMarkedText() {
            sendKeyHandler?(VK.downArrow, 0)
        } else if !hasMarkedText() && string.isEmpty {
            // IME empty: forward plain Down to terminal for Claude Code picker navigation
            sendKeyHandler?(VK.downArrow, 0)
        } else if !hasMarkedText() && isCursorOnLastLine() {
            historyDownHandler?()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Delete overrides

    override func deleteBackward(_ sender: Any?) {
        if string.isEmpty {
            // IME bar is empty → forward Backspace to terminal
            sendKeyHandler?(VK.delete, 0)
            return
        }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        if string.isEmpty {
            // IME bar is empty → forward Delete (Fn+Backspace) to terminal
            sendKeyHandler?(VK.forwardDelete, 0)
            return
        }
        super.deleteForward(sender)
    }

    // MARK: - Cursor position helpers

    private func isCursorOnFirstLine() -> Bool {
        let loc = selectedRange().location
        let str = string as NSString
        let firstNewline = str.range(of: "\n").location
        return firstNewline == NSNotFound || loc <= firstNewline
    }

    private func isCursorOnLastLine() -> Bool {
        let loc = selectedRange().location
        let str = string as NSString
        let lastNewline = str.range(of: "\n", options: .backwards).location
        return lastNewline == NSNotFound || loc > lastNewline
    }

    // MARK: - Paste (image → inline thumbnail)

    /// Pasted image attachments and their /tmp file paths.
    var imageAttachments: [(attachment: NSTextAttachment, path: String)] = []

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if pb.string(forType: .string) != nil || pb.string(forType: NSPasteboard.PasteboardType("public.utf8-plain-text")) != nil {
            pasteAsPlainText(sender)
            return
        }
        if let path = GhosttyPasteboardHelper.saveClipboardImageToTempFile(from: pb),
           let image = NSImage(contentsOfFile: path) {
            let attachment = NSTextAttachment()
            let maxHeight: CGFloat = 48
            let scale = min(maxHeight / image.size.height, 1.0)
            let thumbSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let cell = NSTextAttachmentCell(imageCell: image)
            cell.image?.size = thumbSize
            attachment.attachmentCell = cell

            let attrStr = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
            attrStr.append(NSAttributedString(string: " ",
                attributes: [.font: font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)]))

            textStorage?.insert(attrStr, at: selectedRange().location)
            setSelectedRange(NSRange(location: selectedRange().location + attrStr.length, length: 0))
            imageAttachments.append((attachment: attachment, path: path))
            delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: self))
            return
        }
        pasteAsPlainText(sender)
    }

    /// Returns text with image attachments replaced by their file paths.
    func submittableText() -> String {
        guard let storage = textStorage, !imageAttachments.isEmpty else { return string }
        var result = ""
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
            if let att = attrs[.attachment] as? NSTextAttachment,
               let entry = imageAttachments.first(where: { $0.attachment === att }) {
                result += entry.path
            } else {
                result += (storage.string as NSString).substring(with: range)
            }
        }
        return result
    }

    // MARK: - IME composition tracking

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        composingHandler?(hasMarkedText())
        clearGhost()  // hide ghost during IME composition
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        composingHandler?(false)
    }

    // MARK: - Rainbow keyword coloring

    private static let rainbowKeywords: [String] = [
        "ULTRATHINK", "MEGATHINK", "IMPORTANT", "CRITICAL", "RAINBOW",
    ]

    private static let rainbowColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .cyan, .systemBlue, .systemPurple,
    ]

    // MARK: - Shell syntax highlighting

    /// Regex patterns for shell token categories, in priority order (first match wins).
    /// All NSRegularExpression instances are compiled once and cached.
    private static let syntaxPatterns: [(NSRegularExpression, NSColor)] = {
        var patterns: [(NSRegularExpression, NSColor)] = []
        let defs: [(String, NSColor)] = [
            // Slash commands: /command-name (highest priority — before strings/comments)
            (#"(?:^|(?<=\s))/[A-Za-z][A-Za-z0-9_:-]*"#, NSColor.systemTeal),
            // Double-quoted strings (handles \" escapes)
            (#""(?:[^"\\]|\\.)*""#,             .systemYellow),
            // Single-quoted strings
            (#"'[^']*'"#,                        .systemYellow),
            // Backtick command substitution
            (#"`[^`]*`"#,                        .systemYellow),
            // Comments (# to end of line)
            (#"#[^\n]*"#,                        NSColor.secondaryLabelColor),
            // Variables: ${VAR} and $VAR
            (#"\$\{[^}]+\}"#,                   .cyan),
            (#"\$[A-Za-z_][A-Za-z0-9_]*"#,     .cyan),
            // Redirects: 2>&1, >>, >& before single > or <
            (#"2>&1|>>|>&|[><]"#,               .systemOrange),
            // Pipe: single | (not ||)
            (#"\|(?!\|)"#,                       .systemOrange),
            // Logical operators and double-semicolon
            (#"&&|\|\||;;"#,                     .systemOrange),
            // Semicolon separator (not ;; — already matched above)
            (#"(?<![;]);(?![;])"#,               .systemOrange),
            // Flags: --long-flag or -s (must start at word boundary)
            (#"(?:^|(?<=\s))--?[A-Za-z][A-Za-z0-9-]*"#, .systemGreen),
            // Standalone integers and decimals
            (#"(?:^|(?<=\s))\d+(?:\.\d+)?(?=\s|$|;|\||&)"#, .systemPurple),
        ]
        for (pattern, color) in defs {
            if let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) {
                patterns.append((re, color))
            }
        }
        return patterns
    }()

    /// Regex to find the command word at the start of each logical command segment.
    /// Matches an optional separator (;, |, &&, ||) followed by optional whitespace,
    /// then captures the first word (the command name).
    private static let commandRegex: NSRegularExpression? =
        try? NSRegularExpression(
            pattern: #"(?:[;]|&&|\|\||\|)\s*([A-Za-z/_][A-Za-z0-9_\-./]*)"#,
            options: [.anchorsMatchLines]
        )

    private var isApplyingRainbow = false

    override func didChangeText() {
        super.didChangeText()
        guard !isApplyingRainbow, !hasMarkedText() else { return }
        isApplyingRainbow = true
        applyRainbowKeywords()
        isApplyingRainbow = false
        updateGhostSuggestion()
    }

    /// Scans committed text for rainbow keywords and applies per-character gradient colors.
    /// Safe to call externally (e.g. after programmatic `string =` assignment).
    /// Skips any active IME composing (marked) range.
    func applyRainbowKeywords() {
        guard let storage = textStorage else { return }
        let len = storage.length
        guard len > 0 else { return }
        let markedRange = self.markedRange()
        let fullString = storage.string as NSString

        storage.beginEditing()

        // Reset foreground color to default outside the marked (composing) range
        if markedRange.location == NSNotFound || markedRange.length == 0 {
            storage.addAttribute(.foregroundColor, value: NSColor.textColor,
                                 range: NSRange(location: 0, length: len))
        } else {
            if markedRange.location > 0 {
                storage.addAttribute(.foregroundColor, value: NSColor.textColor,
                                     range: NSRange(location: 0, length: markedRange.location))
            }
            let afterLoc = markedRange.location + markedRange.length
            if afterLoc < len {
                storage.addAttribute(.foregroundColor, value: NSColor.textColor,
                                     range: NSRange(location: afterLoc, length: len - afterLoc))
            }
        }

        // Apply shell syntax highlighting (before rainbow so rainbow overrides)
        var colored = IndexSet()
        applySyntaxHighlighting(storage: storage, fullString: fullString, len: len,
                                markedRange: markedRange, colored: &colored)

        // Apply rainbow colors per character for each keyword match (overrides syntax colors)
        for keyword in IMETextView.rainbowKeywords {
            var searchRange = NSRange(location: 0, length: len)
            while searchRange.length > 0 {
                let found = fullString.range(of: keyword, options: .caseInsensitive, range: searchRange)
                guard found.location != NSNotFound else { break }
                let nextLoc = found.location + found.length
                searchRange = NSRange(location: nextLoc, length: len - nextLoc)

                // Skip if overlapping with active IME composing range
                if markedRange.location != NSNotFound && markedRange.length > 0,
                   NSIntersectionRange(found, markedRange).length > 0 { continue }

                for i in 0..<found.length {
                    let charRange = NSRange(location: found.location + i, length: 1)
                    let color = IMETextView.rainbowColors[i % IMETextView.rainbowColors.count]
                    storage.addAttribute(.foregroundColor, value: color, range: charRange)
                }
            }
        }

        storage.endEditing()
    }

    /// Applies shell syntax coloring to `storage` within a single beginEditing/endEditing batch.
    /// Uses a first-match-wins `IndexSet` so that higher-priority tokens (strings, comments)
    /// prevent lower-priority tokens from recoloring the same characters.
    private func applySyntaxHighlighting(
        storage: NSTextStorage,
        fullString: NSString,
        len: Int,
        markedRange: NSRange,
        colored: inout IndexSet
    ) {
        let nsStr = fullString as String
        let fullRange = NSRange(location: 0, length: len)

        // 1. Regex-based token patterns (string/comment/variable/operator/flag/number)
        for (regex, color) in IMETextView.syntaxPatterns {
            regex.enumerateMatches(in: nsStr, options: [], range: fullRange) { match, _, _ in
                guard let matchRange = match?.range, matchRange.length > 0 else { return }

                // Skip if overlaps with active IME composing range
                if markedRange.location != NSNotFound, markedRange.length > 0,
                   NSIntersectionRange(matchRange, markedRange).length > 0 { return }

                // First-match wins: skip if any index in this range is already colored
                let indices = matchRange.location ..< (matchRange.location + matchRange.length)
                if colored.intersects(integersIn: indices) { return }

                // Skip ranges that contain image attachments
                var hasAttachment = false
                storage.enumerateAttribute(
                    .attachment, in: matchRange,
                    options: .longestEffectiveRangeNotRequired
                ) { val, _, stop in
                    if val != nil { hasAttachment = true; stop.pointee = true }
                }
                if hasAttachment { return }

                storage.addAttribute(.foregroundColor, value: color, range: matchRange)
                colored.insert(integersIn: indices)
            }
        }

        // 2. Command highlighting: first word after line start or ;/|/&&/||
        guard let cmdRe = IMETextView.commandRegex else { return }
        cmdRe.enumerateMatches(in: nsStr, options: [], range: fullRange) { match, _, _ in
            guard let m = match, m.numberOfRanges > 1 else { return }
            let wordRange = m.range(at: 1)
            guard wordRange.location != NSNotFound, wordRange.length > 0 else { return }

            // Skip if overlaps with IME composing range
            if markedRange.location != NSNotFound, markedRange.length > 0,
               NSIntersectionRange(wordRange, markedRange).length > 0 { return }

            // Skip if already colored by a higher-priority token
            let indices = wordRange.location ..< (wordRange.location + wordRange.length)
            if colored.intersects(integersIn: indices) { return }

            // Skip attachment ranges
            var hasAttachment = false
            storage.enumerateAttribute(
                .attachment, in: wordRange,
                options: .longestEffectiveRangeNotRequired
            ) { val, _, stop in
                if val != nil { hasAttachment = true; stop.pointee = true }
            }
            if hasAttachment { return }

            storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: wordRange)
            colored.insert(integersIn: indices)
        }
    }

    // MARK: - Ghost suggestion logic

    private func updateGhostSuggestion() {
        guard !hasMarkedText() else { clearGhost(); return }
        let currentText = string
        // Only suggest on single-line text to avoid layout complexity
        guard !currentText.isEmpty, !currentText.contains("\n") else { clearGhost(); return }

        // Slash commands take priority when text starts with "/"
        if currentText.hasPrefix("/") {
            let lower = currentText.lowercased()
            if let match = slashCommands.first(where: {
                $0.lowercased().hasPrefix(lower) && $0.count > currentText.count
            }) {
                ghostSuggestion = String(match.dropFirst(currentText.count))
                return
            }
        }

        let lower = currentText.lowercased()
        if let match = historySource.first(where: {
            $0.lowercased().hasPrefix(lower) && $0.count > currentText.count
        }) {
            ghostSuggestion = String(match.dropFirst(currentText.count))
        } else {
            clearGhost()
        }
    }

    private func clearGhost() {
        if !ghostSuggestion.isEmpty { ghostSuggestion = "" }
    }

    /// Accepts the current ghost suggestion by inserting it into the text view.
    func acceptGhostSuggestion() {
        guard !ghostSuggestion.isEmpty else { return }
        let insertion = ghostSuggestion
        clearGhost()
        let loc = (string as NSString).length
        insertText(insertion, replacementRange: NSRange(location: loc, length: 0))
    }

    // MARK: - Ghost drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawGhostText()
    }

    private func drawGhostText() {
        guard !ghostSuggestion.isEmpty, !hasMarkedText() else { return }
        guard let lm = layoutManager, let tc = textContainer else { return }

        lm.ensureLayout(for: tc)
        let numGlyphs = lm.numberOfGlyphs
        guard numGlyphs > 0 else { return }

        // bounding rect of the last glyph in textContainer coordinates
        let lastGlyphIdx = numGlyphs - 1
        let glyphBound = lm.boundingRect(
            forGlyphRange: NSRange(location: lastGlyphIdx, length: 1),
            in: tc
        )

        // convert to view coordinates (NSTextView is flipped: y increases downward)
        let drawPoint = NSPoint(
            x: textContainerInset.width + glyphBound.maxX,
            y: textContainerInset.height + glyphBound.minY
        )

        let ghostFont = font ?? NSFont.monospacedSystemFont(
            ofSize: IMEInputBarSettings.fontSize, weight: .regular
        )
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.4),
            .font: ghostFont,
        ]

        // Only show the first line of the suggestion
        let displayGhost = ghostSuggestion.components(separatedBy: "\n").first ?? ghostSuggestion
        displayGhost.draw(at: drawPoint, withAttributes: attrs)
    }
}
