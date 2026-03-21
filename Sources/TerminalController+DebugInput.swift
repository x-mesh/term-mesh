import AppKit
import Foundation
import Carbon.HIToolbox
import Bonsplit
import WebKit

extension TerminalController {
    func sendKeyEvent(
        surface: ghostty_surface_t,
        keycode: UInt32,
        mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE,
        text: String? = nil
    ) {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = keycode
        keyEvent.mods = mods
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false
        if let text {
            text.withCString { ptr in
                keyEvent.text = ptr
                _ = ghostty_surface_key(surface, keyEvent)
            }
        } else {
            keyEvent.text = nil
            _ = ghostty_surface_key(surface, keyEvent)
        }
        // Send matching RELEASE event — TUI apps (Claude Code, kiro-cli) track
        // key state and may ignore subsequent PRESS events if the previous key
        // was never released.
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.text = nil
        _ = ghostty_surface_key(surface, keyEvent)
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

    func sendNamedKey(_ surface: ghostty_surface_t, keyName: String) -> Bool {
        switch keyName.lowercased() {
        case "ctrl-c", "ctrl+c", "sigint":
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_ANSI_C), mods: GHOSTTY_MODS_CTRL)
            return true
        case "ctrl-d", "ctrl+d", "eof":
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_ANSI_D), mods: GHOSTTY_MODS_CTRL)
            return true
        case "ctrl-z", "ctrl+z", "sigtstp":
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_ANSI_Z), mods: GHOSTTY_MODS_CTRL)
            return true
        case "ctrl-\\", "ctrl+\\", "sigquit":
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_ANSI_Backslash), mods: GHOSTTY_MODS_CTRL)
            return true
        case "enter", "return":
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_Return), text: "\r")
            return true
        case "tab":
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_Tab), text: "\t")
            return true
        case "escape", "esc":
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_Escape), text: "\u{1b}")
            return true
        case "backspace":
            sendKeyEvent(surface: surface, keycode: UInt32(kVK_Delete), text: "\u{7f}")
            return true
        default:
            if keyName.lowercased().hasPrefix("ctrl-") || keyName.lowercased().hasPrefix("ctrl+") {
                let letter = keyName.dropFirst(5)
                if letter.count == 1, let char = letter.first, let keycode = keycodeForLetter(char) {
                    sendKeyEvent(surface: surface, keycode: keycode, mods: GHOSTTY_MODS_CTRL)
                    return true
                }
            }
            return false
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
