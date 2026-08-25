import AppKit
import Foundation
import Carbon.HIToolbox
import Bonsplit
import WebKit

extension TerminalController {
    @discardableResult
    func sendKeyEvent(
        surface: ghostty_surface_t,
        keycode: UInt32,
        mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE,
        text: String? = nil
    ) -> Bool {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = keycode
        keyEvent.mods = mods
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false
        var pressResult = true
        #if DEBUG
        let surfaceLabel = AppDelegate.shared?.locateGhosttySurface(surface)?.panelId.uuidString.prefix(8) ?? "unknown"
        dlog("keyEvent.attempt keycode=\(keycode) surface=\(surfaceLabel)")
        #endif
        if let text {
            text.withCString { ptr in
                keyEvent.text = ptr
                pressResult = ghostty_surface_key(surface, keyEvent)
            }
        } else {
            keyEvent.text = nil
            pressResult = ghostty_surface_key(surface, keyEvent)
        }
        // Send matching RELEASE event — TUI apps (Claude Code, kiro-cli) track
        // key state and may ignore subsequent PRESS events if the previous key
        // was never released.
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.text = nil
        let releaseResult = ghostty_surface_key(surface, keyEvent)
        #if DEBUG
        if pressResult {
            dlog("keyEvent.PRESS_ok keycode=\(keycode) surface=\(surfaceLabel)")
        } else {
            dlog("key.PRESS_ignored keycode=\(keycode) surface=\(surfaceLabel) mods=\(mods.rawValue)")
        }
        if !releaseResult {
            dlog("key.RELEASE_ignored keycode=\(keycode) surface=\(surfaceLabel) mods=\(mods.rawValue)")
        }
        #endif
        return pressResult
    }

    func sendTextEvent(surface: ghostty_surface_t, text: String) {
        sendKeyEvent(surface: surface, keycode: 0, text: text)
    }

    enum SocketTextChunk: Equatable {
        case text(String)
        case control(UnicodeScalar)
    }

    nonisolated static func socketTextChunks(_ text: String) -> [SocketTextChunk] {
        guard !text.isEmpty else { return [] }

        var chunks: [SocketTextChunk] = []
        chunks.reserveCapacity(8)
        var bufferedText = ""
        bufferedText.reserveCapacity(text.count)

        func flushBufferedText() {
            guard !bufferedText.isEmpty else { return }
            chunks.append(.text(bufferedText))
            bufferedText.removeAll(keepingCapacity: true)
        }

        for scalar in text.unicodeScalars {
            if isSocketControlScalar(scalar) {
                flushBufferedText()
                chunks.append(.control(scalar))
            } else {
                bufferedText.unicodeScalars.append(scalar)
            }
        }
        flushBufferedText()
        return chunks
    }

    private nonisolated static func isSocketControlScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0D, 0x09, 0x1B, 0x7F:
            return true
        default:
            return false
        }
    }

    func sendSocketText(_ text: String, surface: ghostty_surface_t) {
        let chunks = Self.socketTextChunks(text)
        #if DEBUG
        let startedAt = ProcessInfo.processInfo.systemUptime
        #endif
        for chunk in chunks {
            switch chunk {
            case .text(let value):
                sendTextEvent(surface: surface, text: value)
            case .control(let scalar):
                _ = handleControlScalar(scalar, surface: surface)
            }
        }
        #if DEBUG
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0
        if elapsedMs >= 8 || chunks.count > 1 {
            dlog(
                "socket.send_text.inject chars=\(text.count) chunks=\(chunks.count) ms=\(String(format: "%.2f", elapsedMs))"
            )
        }
        #endif
    }

    func handleControlScalar(_ scalar: UnicodeScalar, surface: ghostty_surface_t) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0D:
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_Return), text: "\r")
            return true
        case 0x09:
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_Tab), text: "\t")
            return true
        case 0x1B:
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_Escape), text: "\u{1b}")
            return true
        case 0x7F:
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_Delete), text: "\u{7f}")
            return true
        default:
            return false
        }
    }

    func keycodeForLetter(_ letter: Character) -> UInt32? {
        switch String(letter).lowercased() {
        case "a": return UInt32(kVK_ANSI_A)
        case "b": return UInt32(kVK_ANSI_B)
        case "c": return UInt32(kVK_ANSI_C)
        case "d": return UInt32(kVK_ANSI_D)
        case "e": return UInt32(kVK_ANSI_E)
        case "f": return UInt32(kVK_ANSI_F)
        case "g": return UInt32(kVK_ANSI_G)
        case "h": return UInt32(kVK_ANSI_H)
        case "i": return UInt32(kVK_ANSI_I)
        case "j": return UInt32(kVK_ANSI_J)
        case "k": return UInt32(kVK_ANSI_K)
        case "l": return UInt32(kVK_ANSI_L)
        case "m": return UInt32(kVK_ANSI_M)
        case "n": return UInt32(kVK_ANSI_N)
        case "o": return UInt32(kVK_ANSI_O)
        case "p": return UInt32(kVK_ANSI_P)
        case "q": return UInt32(kVK_ANSI_Q)
        case "r": return UInt32(kVK_ANSI_R)
        case "s": return UInt32(kVK_ANSI_S)
        case "t": return UInt32(kVK_ANSI_T)
        case "u": return UInt32(kVK_ANSI_U)
        case "v": return UInt32(kVK_ANSI_V)
        case "w": return UInt32(kVK_ANSI_W)
        case "x": return UInt32(kVK_ANSI_X)
        case "y": return UInt32(kVK_ANSI_Y)
        case "z": return UInt32(kVK_ANSI_Z)
        default: return nil
        }
    }

    nonisolated static func queuedTextForNamedKey(_ keyName: String) -> String? {
        let normalized = keyName.lowercased()
        switch normalized {
        case "ctrl-c", "ctrl+c", "sigint": return "\u{03}"
        case "ctrl-d", "ctrl+d", "eof": return "\u{04}"
        case "ctrl-u", "ctrl+u", "kill-line": return "\u{15}"
        case "ctrl-z", "ctrl+z", "sigtstp": return "\u{1a}"
        case "ctrl-\\", "ctrl+\\", "sigquit": return "\u{1c}"
        case "enter", "return": return "\r"
        case "tab": return "\t"
        case "escape", "esc": return "\u{1b}"
        case "backspace": return "\u{7f}"
        default:
            guard normalized.hasPrefix("ctrl-") || normalized.hasPrefix("ctrl+") else {
                return nil
            }
            let letter = normalized.dropFirst(5)
            guard letter.utf8.count == 1, let byte = letter.utf8.first,
                  byte >= Character("a").asciiValue!, byte <= Character("z").asciiValue!,
                  let scalar = UnicodeScalar(Int(byte - Character("a").asciiValue! + 1)) else {
                return nil
            }
            return String(scalar)
        }
    }

    func sendNamedKey(_ surface: ghostty_surface_t, keyName: String) -> Bool {
        switch keyName.lowercased() {
        case "ctrl-c", "ctrl+c", "sigint":
            return sendKeyEvent(surface: surface, keycode: UInt32(kVK_ANSI_C), mods: GHOSTTY_MODS_CTRL)
        case "ctrl-d", "ctrl+d", "eof":
            return sendKeyEvent(surface: surface, keycode: UInt32(kVK_ANSI_D), mods: GHOSTTY_MODS_CTRL)
        case "ctrl-u", "ctrl+u", "kill-line":
            return sendKeyEvent(surface: surface, keycode: UInt32(kVK_ANSI_U), mods: GHOSTTY_MODS_CTRL)
        case "ctrl-z", "ctrl+z", "sigtstp":
            return sendKeyEvent(surface: surface, keycode: UInt32(kVK_ANSI_Z), mods: GHOSTTY_MODS_CTRL)
        case "ctrl-\\", "ctrl+\\", "sigquit":
            return sendKeyEvent(surface: surface, keycode: UInt32(kVK_ANSI_Backslash), mods: GHOSTTY_MODS_CTRL)
        case "enter", "return":
            return sendKeyEvent(surface: surface, keycode: UInt32(kVK_Return), text: "\r")
        case "tab":
            return sendKeyEvent(surface: surface, keycode: UInt32(kVK_Tab), text: "\t")
        case "escape", "esc":
            return sendKeyEvent(surface: surface, keycode: UInt32(kVK_Escape), text: "\u{1b}")
        case "backspace":
            return sendKeyEvent(surface: surface, keycode: UInt32(kVK_Delete), text: "\u{7f}")
        // Arrow keys as real key events so Ghostty encodes them for whatever
        // keyboard protocol the pane negotiated (kitty in Claude Code). Raw
        // CSI bytes through surface.send_text would be encoded as an Escape
        // key press followed by text there.
        case "up", "arrow-up":
            return sendKeyEvent(surface: surface, keycode: UInt32(kVK_UpArrow))
        case "down", "arrow-down":
            return sendKeyEvent(surface: surface, keycode: UInt32(kVK_DownArrow))
        case "left", "arrow-left":
            return sendKeyEvent(surface: surface, keycode: UInt32(kVK_LeftArrow))
        case "right", "arrow-right":
            return sendKeyEvent(surface: surface, keycode: UInt32(kVK_RightArrow))
        default:
            if keyName.lowercased().hasPrefix("ctrl-") || keyName.lowercased().hasPrefix("ctrl+") {
                let letter = keyName.dropFirst(5)
                if letter.count == 1, let char = letter.first, let keycode = keycodeForLetter(char) {
                    return sendKeyEvent(surface: surface, keycode: keycode, mods: GHOSTTY_MODS_CTRL)
                }
            }
            return false
        }
    }

    func sendNamedKeyWithRetry(
        on terminalSurface: TerminalSurface,
        keyName: String,
        completion: @escaping (Bool, String) -> Void
    ) {
        let token = KeyDeliveryToken()
        let generation = terminalSurface.attachGeneration
        let panelLabel = terminalSurface.id.uuidString.prefix(8)
        let retryDelays: [Double] = [0.2, 0.5, 1.0, 2.0, 3.0]
        let totalAttempts = 2 + retryDelays.count
        var completed = false
        var lastFailureReason = "delivery_failed"

        func finish(_ delivered: Bool, reason: String) {
            guard !completed else { return }
            completed = true
            if delivered {
                token.delivered = true
            }
            completion(delivered, reason)
        }

        func attempt(_ ordinal: Int, label: String) -> Bool {
            guard terminalSurface.attachGeneration == generation else {
                lastFailureReason = "stale_generation"
                #if DEBUG
                dlog("key.retry.drop reason=stale_generation panel=\(panelLabel) key=\(keyName) gen=\(generation) currentGen=\(terminalSurface.attachGeneration) attempt=\(ordinal)/\(totalAttempts)")
                #endif
                return false
            }
            guard !terminalSurface.hasMarkedTextForInput else {
                lastFailureReason = "ime_composing"
                #if DEBUG
                dlog("key.retry.defer reason=ime_composing panel=\(panelLabel) key=\(keyName) gen=\(generation) attempt=\(ordinal)/\(totalAttempts)")
                #endif
                return false
            }
            guard let surface = terminalSurface.surface else {
                lastFailureReason = "surface_nil"
                #if DEBUG
                dlog("key.retry.drop reason=surface_nil panel=\(panelLabel) key=\(keyName) gen=\(generation) attempt=\(ordinal)/\(totalAttempts)")
                #endif
                return false
            }

            let ok = sendNamedKey(surface, keyName: keyName)
            lastFailureReason = ok ? "none" : "press_ignored"
            #if DEBUG
            if !ok {
                let isAttached = terminalSurface.isViewInWindow
                let hasMarkedText = terminalSurface.hasMarkedTextForInput
                let renderingPaused = terminalSurface.renderingPaused
                dlog("key.retry.R2_rejected panel=\(panelLabel) key=\(keyName) attempt=\(ordinal)/\(totalAttempts) label=\(label) attached=\(isAttached) ime=\(hasMarkedText) paused=\(renderingPaused)")
            } else {
                dlog("key.retry.attempt panel=\(panelLabel) key=\(keyName) gen=\(generation) attempt=\(ordinal)/\(totalAttempts) label=\(label) handled=\(ok)")
            }
            #endif
            return ok
        }

        if attempt(1, label: "initial") {
            finish(true, reason: "delivered")
            return
        }

        usleep(10_000)
        if attempt(2, label: "sync10ms") {
            finish(true, reason: "delivered")
            return
        }

        for (index, delay) in retryDelays.enumerated() {
            let ordinal = index + 3
            let isLast = index == retryDelays.count - 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [token] in
                guard !completed else { return }
                guard !token.delivered else {
                    #if DEBUG
                    dlog("key.retry.drop reason=token_delivered panel=\(panelLabel) key=\(keyName) gen=\(generation) attempt=\(ordinal)/\(totalAttempts)")
                    #endif
                    return
                }
                if attempt(ordinal, label: "async\(index + 1)") {
                    finish(true, reason: "delivered")
                } else if lastFailureReason == "stale_generation" {
                    finish(false, reason: lastFailureReason)
                } else if isLast {
                    finish(false, reason: lastFailureReason)
                }
            }
        }
    }

    func sendInput(_ text: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var success = false
        var error: String?
        _ = v2MainExec(timeout: 5) {
            guard let selectedId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == selectedId }),
                  let terminalPanel = tab.focusedTerminalPanel else {
                error = "ERROR: No focused terminal"
                return
            }

            // Unescape common escape sequences
            // Note: \n is converted to \r for terminal (Enter key sends \r)
            let unescaped = text
                .replacingOccurrences(of: "\\n", with: "\r")
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\t", with: "\t")

            if let surface = terminalPanel.surface.surface {
                self.sendSocketText(unescaped, surface: surface)
            } else {
                terminalPanel.sendText(unescaped)
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
            }
            success = true
        }
        if let error { return error }
        return success ? "OK" : "ERROR: Failed to send input"
    }

    func sendInputToSurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "ERROR: Usage: send_surface <id|idx> <text>" }

        let target = parts[0]
        let text = parts[1]

        var success = false
        _ = v2MainExec(timeout: 5) {
            guard let terminalPanel = self.resolveTerminalPanel(from: target, tabManager: tabManager) else { return }

            let unescaped = text
                .replacingOccurrences(of: "\\n", with: "\r")
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\t", with: "\t")

            if let surface = terminalPanel.surface.surface {
                self.sendSocketText(unescaped, surface: surface)
            } else {
                terminalPanel.sendText(unescaped)
                terminalPanel.surface.requestBackgroundSurfaceStartIfNeeded()
            }
            success = true
        }

        return success ? "OK" : "ERROR: Failed to send input"
    }

    func sendKey(_ keyName: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }

        var success = false
        var error: String?
        _ = v2MainExec(timeout: 5) {
            guard let selectedId = tabManager.selectedTabId,
                  let tab = tabManager.tabs.first(where: { $0.id == selectedId }),
                  let terminalPanel = tab.focusedTerminalPanel else {
                error = "ERROR: No focused terminal"
                return
            }

            guard let surface = terminalPanel.surface.surface else {
                error = "ERROR: Surface not ready"
                return
            }

            success = self.sendNamedKey(surface, keyName: keyName)
        }
        if let error { return error }
        return success ? "OK" : "ERROR: Unknown key '\(keyName)'"
    }

    func sendKeyToSurface(_ args: String) -> String {
        guard let tabManager = tabManager else { return "ERROR: TabManager not available" }
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "ERROR: Usage: send_key_surface <id|idx> <key>" }

        let target = parts[0]
        let keyName = parts[1]

        var success = false
        var error: String?
        _ = v2MainExec(timeout: 5) {
            guard let terminalPanel = self.resolveTerminalPanel(from: target, tabManager: tabManager) else {
                error = "ERROR: Surface not found"
                return
            }
            guard let surface = terminalPanel.surface.surface else {
                error = "ERROR: Surface not ready"
                return
            }
            success = self.sendNamedKey(surface, keyName: keyName)
        }

        if let error { return error }
        return success ? "OK" : "ERROR: Unknown key '\(keyName)'"
    }
}
