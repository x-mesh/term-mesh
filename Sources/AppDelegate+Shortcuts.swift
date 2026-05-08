import AppKit
import SwiftUI
import Bonsplit
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime

extension AppDelegate {
    func focusBrowserAddressBar(in panel: BrowserPanel) {
        _ = panel.requestAddressBarFocus()
        browserAddressBarFocusedPanelId = panel.id
        NotificationCenter.default.post(name: .browserFocusAddressBar, object: panel.id)
    }

    func shouldBypassAppShortcutForFocusedBrowserAddressBar(
        flags: NSEvent.ModifierFlags,
        chars: String
    ) -> Bool {
        guard browserAddressBarFocusedPanelId != nil else { return false }
        let normalizedFlags = browserOmnibarNormalizedModifierFlags(flags)
        let isCommandOrControlOnly = normalizedFlags == [.command] || normalizedFlags == [.control]
        guard isCommandOrControlOnly else { return false }
        return chars == "n" || chars == "p"
    }

    func commandOmnibarSelectionDelta(
        flags: NSEvent.ModifierFlags,
        chars: String
    ) -> Int? {
        browserOmnibarSelectionDeltaForCommandNavigation(
            hasFocusedAddressBar: browserAddressBarFocusedPanelId != nil,
            flags: flags,
            chars: chars
        )
    }

    func dispatchBrowserOmnibarSelectionMove(delta: Int) {
        guard delta != 0 else { return }
        guard let panelId = browserAddressBarFocusedPanelId else { return }
        NotificationCenter.default.post(
            name: .browserMoveOmnibarSelection,
            object: panelId,
            userInfo: ["delta": delta]
        )
    }

    func startBrowserOmnibarSelectionRepeatIfNeeded(keyCode: UInt16, delta: Int) {
        guard delta != 0 else { return }
        guard browserAddressBarFocusedPanelId != nil else { return }

        if browserOmnibarRepeatKeyCode == keyCode, browserOmnibarRepeatDelta == delta {
            return
        }

        stopBrowserOmnibarSelectionRepeat()
        browserOmnibarRepeatKeyCode = keyCode
        browserOmnibarRepeatDelta = delta

        let start = DispatchWorkItem { [weak self] in
            self?.scheduleBrowserOmnibarSelectionRepeatTick()
        }
        browserOmnibarRepeatStartWorkItem = start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: start)
    }

    func scheduleBrowserOmnibarSelectionRepeatTick() {
        browserOmnibarRepeatStartWorkItem = nil
        guard browserAddressBarFocusedPanelId != nil else {
            stopBrowserOmnibarSelectionRepeat()
            return
        }
        guard browserOmnibarRepeatKeyCode != nil else { return }

        dispatchBrowserOmnibarSelectionMove(delta: browserOmnibarRepeatDelta)

        let tick = DispatchWorkItem { [weak self] in
            self?.scheduleBrowserOmnibarSelectionRepeatTick()
        }
        browserOmnibarRepeatTickWorkItem = tick
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055, execute: tick)
    }

    func stopBrowserOmnibarSelectionRepeat() {
        browserOmnibarRepeatStartWorkItem?.cancel()
        browserOmnibarRepeatTickWorkItem?.cancel()
        browserOmnibarRepeatStartWorkItem = nil
        browserOmnibarRepeatTickWorkItem = nil
        browserOmnibarRepeatKeyCode = nil
        browserOmnibarRepeatDelta = 0
    }

    func handleBrowserOmnibarSelectionRepeatLifecycleEvent(_ event: NSEvent) {
        guard browserOmnibarRepeatKeyCode != nil else { return }

        switch event.type {
        case .keyUp:
            if event.keyCode == browserOmnibarRepeatKeyCode {
                stopBrowserOmnibarSelectionRepeat()
            }
        case .flagsChanged:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !flags.contains(.command) {
                stopBrowserOmnibarSelectionRepeat()
            }
        default:
            break
        }
    }

    func isLikelyWebInspectorResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        let responderType = String(describing: type(of: responder))
        if responderType.contains("WKInspector") {
            return true
        }
        guard let view = responder as? NSView else { return false }
        var node: NSView? = view
        var hops = 0
        while let current = node, hops < 64 {
            if String(describing: type(of: current)).contains("WKInspector") {
                return true
            }
            node = current.superview
            hops += 1
        }
        return false
    }

#if DEBUG
    func developerToolsShortcutProbeKind(event: NSEvent) -> String? {
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .toggleBrowserDeveloperTools)) {
            return "toggle.configured"
        }
        if matchShortcut(event: event, shortcut: KeyboardShortcutSettings.shortcut(for: .showBrowserJavaScriptConsole)) {
            return "console.configured"
        }

        let chars = (event.charactersIgnoringModifiers ?? "").lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .option] {
            if chars == "i" || event.keyCode == 34 {
                return "toggle.literal"
            }
            if chars == "c" || event.keyCode == 8 {
                return "console.literal"
            }
        }
        return nil
    }

    func logDeveloperToolsShortcutSnapshot(
        phase: String,
        event: NSEvent? = nil,
        didHandle: Bool? = nil
    ) {
        let keyWindow = NSApp.keyWindow
        let firstResponder = keyWindow?.firstResponder
        let firstResponderType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let firstResponderPtr = firstResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        let eventDescription = event.map(NSWindow.keyDescription) ?? "none"
        if let browser = tabManager?.focusedBrowserPanel {
            var line =
                "browser.devtools shortcut=\(phase) panel=\(browser.id.uuidString.prefix(5)) " +
                "\(browser.debugDeveloperToolsStateSummary()) \(browser.debugDeveloperToolsGeometrySummary()) " +
                "keyWin=\(keyWindow?.windowNumber ?? -1) fr=\(firstResponderType)@\(firstResponderPtr) event=\(eventDescription)"
            if let didHandle {
                line += " handled=\(didHandle ? 1 : 0)"
            }
            dlog(line)
            return
        }
        var line =
            "browser.devtools shortcut=\(phase) panel=nil keyWin=\(keyWindow?.windowNumber ?? -1) " +
            "fr=\(firstResponderType)@\(firstResponderPtr) event=\(eventDescription)"
        if let didHandle {
            line += " handled=\(didHandle ? 1 : 0)"
        }
        dlog(line)
    }
#endif

    func prepareFocusedBrowserDevToolsForSplit(directionLabel: String) {
        guard let browser = tabManager?.focusedBrowserPanel else { return }
        guard browser.shouldPreserveWebViewAttachmentDuringTransientHide() else { return }
        guard let keyWindow = NSApp.keyWindow else { return }
        guard isLikelyWebInspectorResponder(keyWindow.firstResponder) else { return }

        let beforeResponder = keyWindow.firstResponder
        let movedToWebView = keyWindow.makeFirstResponder(browser.webView)
        let movedToNil = movedToWebView ? false : keyWindow.makeFirstResponder(nil)

        #if DEBUG
        let beforeType = beforeResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let beforePtr = beforeResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        let afterResponder = keyWindow.firstResponder
        let afterType = afterResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let afterPtr = afterResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        dlog(
            "split.shortcut inspector.preflight dir=\(directionLabel) panel=\(browser.id.uuidString.prefix(5)) " +
            "before=\(beforeType)@\(beforePtr) after=\(afterType)@\(afterPtr) " +
            "moveWeb=\(movedToWebView ? 1 : 0) moveNil=\(movedToNil ? 1 : 0) \(browser.debugDeveloperToolsStateSummary())"
        )
        #endif
    }

    @discardableResult
    func performSplitShortcut(direction: SplitDirection) -> Bool {
        _ = synchronizeActiveMainWindowContext(preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow)

        let directionLabel: String
        switch direction {
        case .left: directionLabel = "left"
        case .right: directionLabel = "right"
        case .up: directionLabel = "up"
        case .down: directionLabel = "down"
        }

        #if DEBUG
        let keyWindow = NSApp.keyWindow
        let firstResponder = keyWindow?.firstResponder
        let firstResponderType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let firstResponderPtr = firstResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
        let firstResponderWindow: Int = {
            if let v = firstResponder as? NSView {
                return v.window?.windowNumber ?? -1
            }
            if let w = firstResponder as? NSWindow {
                return w.windowNumber
            }
            return -1
        }()
        let splitContext = "keyWin=\(keyWindow?.windowNumber ?? -1) mainWin=\(NSApp.mainWindow?.windowNumber ?? -1) fr=\(firstResponderType)@\(firstResponderPtr) frWin=\(firstResponderWindow)"
        if let browser = tabManager?.focusedBrowserPanel {
            let webWindow = browser.webView.window?.windowNumber ?? -1
            let webSuperview = browser.webView.superview.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
            dlog("split.shortcut dir=\(directionLabel) pre panel=\(browser.id.uuidString.prefix(5)) \(browser.debugDeveloperToolsStateSummary()) webWin=\(webWindow) webSuper=\(webSuperview) \(splitContext)")
        } else {
            dlog("split.shortcut dir=\(directionLabel) pre panel=nil \(splitContext)")
        }
        #endif

        prepareFocusedBrowserDevToolsForSplit(directionLabel: directionLabel)
        tabManager?.createSplit(direction: direction)
#if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            let keyWindow = NSApp.keyWindow
            let firstResponder = keyWindow?.firstResponder
            let firstResponderType = firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let firstResponderPtr = firstResponder.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
            let firstResponderWindow: Int = {
                if let v = firstResponder as? NSView {
                    return v.window?.windowNumber ?? -1
                }
                if let w = firstResponder as? NSWindow {
                    return w.windowNumber
                }
                return -1
            }()
            let splitContext = "keyWin=\(keyWindow?.windowNumber ?? -1) mainWin=\(NSApp.mainWindow?.windowNumber ?? -1) fr=\(firstResponderType)@\(firstResponderPtr) frWin=\(firstResponderWindow)"
            if let browser = self?.tabManager?.focusedBrowserPanel {
                let webWindow = browser.webView.window?.windowNumber ?? -1
                let webSuperview = browser.webView.superview.map { String(describing: Unmanaged.passUnretained($0).toOpaque()) } ?? "nil"
                dlog("split.shortcut dir=\(directionLabel) post panel=\(browser.id.uuidString.prefix(5)) \(browser.debugDeveloperToolsStateSummary()) webWin=\(webWindow) webSuper=\(webSuperview) \(splitContext)")
            } else {
                dlog("split.shortcut dir=\(directionLabel) post panel=nil \(splitContext)")
            }
        }
        recordGotoSplitSplitIfNeeded(direction: direction)
#endif
        return true
    }

    @discardableResult
    func performBrowserSplitShortcut(direction: SplitDirection) -> Bool {
        _ = synchronizeActiveMainWindowContext(preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow)

        guard let panelId = tabManager?.createBrowserSplit(direction: direction) else { return false }
        _ = focusBrowserAddressBar(panelId: panelId)
        return true
    }

    /// Allow AppKit-backed browser surfaces (WKWebView) to route non-menu shortcuts
    /// through the same app-level shortcut handler used by the local key monitor.
    @discardableResult
    func handleBrowserSurfaceKeyEquivalent(_ event: NSEvent) -> Bool {
        handleCustomShortcut(event: event)
    }

#if DEBUG
    // Debug/test hook: allow socket-driven shortcut simulation to reuse the same shortcut routing
    // logic as the local NSEvent monitor, without relying on AppKit event monitor behavior for
    // synthetic NSEvents.
    func debugHandleCustomShortcut(event: NSEvent) -> Bool {
        handleCustomShortcut(event: event)
    }
#endif

    func findButton(in view: NSView, titled title: String) -> NSButton? {
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let found = findButton(in: subview, titled: title) {
                return found
            }
        }
        return nil
    }

    func findStaticText(in view: NSView, equals text: String) -> Bool {
        if let field = view as? NSTextField, field.stringValue == text {
            return true
        }
        for subview in view.subviews {
            if findStaticText(in: subview, equals: text) {
                return true
            }
        }
        return false
    }

    /// Match a shortcut against an event, handling normal keys
    func matchShortcut(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        // Some keys can include extra flags (e.g. .function) depending on the responder chain.
        // Strip those for consistent matching across first responders (terminal, WebKit, etc).
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        guard flags == shortcut.modifierFlags else { return false }

        // NSEvent.charactersIgnoringModifiers preserves Shift for some symbol keys
        // (e.g. Shift+] can yield "}" instead of "]"), so match brackets by keyCode.
        let shortcutKey = shortcut.key.lowercased()
        if shortcutKey == "[" || shortcutKey == "]" {
            switch event.keyCode {
            case 33: // kVK_ANSI_LeftBracket
                return shortcutKey == "["
            case 30: // kVK_ANSI_RightBracket
                return shortcutKey == "]"
            default:
                return false
            }
        }

        // Control-key combos can produce control characters (e.g. Ctrl+H => backspace),
        // so fall back to keyCode matching for common printable keys.
        if let chars = event.charactersIgnoringModifiers?.lowercased(), chars == shortcutKey {
            return true
        }
        if let expectedKeyCode = keyCodeForShortcutKey(shortcutKey) {
            return event.keyCode == expectedKeyCode
        }
        return false
    }

    func keyCodeForShortcutKey(_ key: String) -> UInt16? {
        // Matches macOS ANSI key codes. This is intentionally limited to keys we
        // support in StoredShortcut/ghostty trigger translation.
        switch key {
        case "a": return 0   // kVK_ANSI_A
        case "s": return 1   // kVK_ANSI_S
        case "d": return 2   // kVK_ANSI_D
        case "f": return 3   // kVK_ANSI_F
        case "h": return 4   // kVK_ANSI_H
        case "g": return 5   // kVK_ANSI_G
        case "z": return 6   // kVK_ANSI_Z
        case "x": return 7   // kVK_ANSI_X
        case "c": return 8   // kVK_ANSI_C
        case "v": return 9   // kVK_ANSI_V
        case "b": return 11  // kVK_ANSI_B
        case "q": return 12  // kVK_ANSI_Q
        case "w": return 13  // kVK_ANSI_W
        case "e": return 14  // kVK_ANSI_E
        case "r": return 15  // kVK_ANSI_R
        case "y": return 16  // kVK_ANSI_Y
        case "t": return 17  // kVK_ANSI_T
        case "1": return 18  // kVK_ANSI_1
        case "2": return 19  // kVK_ANSI_2
        case "3": return 20  // kVK_ANSI_3
        case "4": return 21  // kVK_ANSI_4
        case "6": return 22  // kVK_ANSI_6
        case "5": return 23  // kVK_ANSI_5
        case "=": return 24  // kVK_ANSI_Equal
        case "9": return 25  // kVK_ANSI_9
        case "7": return 26  // kVK_ANSI_7
        case "-": return 27  // kVK_ANSI_Minus
        case "8": return 28  // kVK_ANSI_8
        case "0": return 29  // kVK_ANSI_0
        case "o": return 31  // kVK_ANSI_O
        case "u": return 32  // kVK_ANSI_U
        case "i": return 34  // kVK_ANSI_I
        case "p": return 35  // kVK_ANSI_P
        case "l": return 37  // kVK_ANSI_L
        case "j": return 38  // kVK_ANSI_J
        case "'": return 39  // kVK_ANSI_Quote
        case "k": return 40  // kVK_ANSI_K
        case ";": return 41  // kVK_ANSI_Semicolon
        case "\\": return 42 // kVK_ANSI_Backslash
        case ",": return 43  // kVK_ANSI_Comma
        case "/": return 44  // kVK_ANSI_Slash
        case "n": return 45  // kVK_ANSI_N
        case "m": return 46  // kVK_ANSI_M
        case ".": return 47  // kVK_ANSI_Period
        case "`": return 50  // kVK_ANSI_Grave
        case "↩": return 36  // kVK_Return
        default:
            return nil
        }
    }

    /// Match arrow key shortcuts using keyCode
    /// Arrow keys include .numericPad and .function in their modifierFlags, so strip those before comparing.
    func matchArrowShortcut(event: NSEvent, shortcut: StoredShortcut, keyCode: UInt16) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function])
        return event.keyCode == keyCode && flags == shortcut.modifierFlags
    }

    /// Match tab key shortcuts using keyCode 48
    func matchTabShortcut(event: NSEvent, shortcut: StoredShortcut) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == 48 && flags == shortcut.modifierFlags
    }

    /// Directional shortcuts default to arrow keys, but the shortcut recorder only supports letter/number keys.
    /// Support both so users can customize pane navigation (e.g. Cmd+Ctrl+H/J/K/L).
    func matchDirectionalShortcut(
        event: NSEvent,
        shortcut: StoredShortcut,
        arrowGlyph: String,
        arrowKeyCode: UInt16
    ) -> Bool {
        if shortcut.key == arrowGlyph {
            return matchArrowShortcut(event: event, shortcut: shortcut, keyCode: arrowKeyCode)
        }
        return matchShortcut(event: event, shortcut: shortcut)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        return true
    }

}
