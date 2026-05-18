import Foundation

// Swift port of `daemon/term-meshd/src/auto_reply.rs` (Phase B3).
//
// Spec is identical to the Rust detector: strict 5/5 line-start header in
// fixed order (STATUS/FILES/VERIFY/NEXT/FULL_REPORT), ANSI-stripped lines,
// debounce-based commit. See the Rust module for full design notes; this
// file deliberately mirrors structure so fixture-driven regressions can
// catch drift between the two implementations.
//
// Used by `AutoReplyPoller` to monitor GUI agent pane scrollback and emit
// the equivalent of `tm-agent reply` when the agent printed the header
// text in their response but skipped invoking the shell command.

struct AutoReplyEvent: Equatable {
    let status: String
    let files: String
    let verify: String
    let next: String
    let fullReport: String
    let body: String
    let raw: String

    /// Stable hash for caller-side dedup. Matches the Rust impl semantics
    /// (FxHash differs but Swift only needs intra-process stability).
    func contentHash() -> UInt64 {
        var hasher = Hasher()
        hasher.combine(status)
        hasher.combine(files)
        hasher.combine(verify)
        hasher.combine(next)
        hasher.combine(fullReport)
        hasher.combine(body)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}

struct AutoReplyDetectorConfig {
    var idleDebounce: TimeInterval = 0.5
    var hardCap: TimeInterval = 5.0
}

final class AutoReplyDetector {
    private enum State {
        case idle, sawStatus, sawFiles, sawVerify, sawNext, body
    }

    private enum HeaderKey {
        case status, files, verify, next, fullReport
    }

    private let config: AutoReplyDetectorConfig
    private var state: State = .idle
    private var lineBuf: String = ""
    private var headerStatus = ""
    private var headerFiles = ""
    private var headerVerify = ""
    private var headerNext = ""
    private var headerFullReport = ""
    private var bodyLines: [String] = []
    private var rawLines: [String] = []
    private var headerStartedAt: Date?
    private var lastBodyInputAt: Date?

    init(config: AutoReplyDetectorConfig = .init()) {
        self.config = config
    }

    /// Feed raw bytes from the agent's terminal output. Returns an event when
    /// a body-phase new STATUS line forces commit of the previous capture.
    /// Time-based commits arrive via `tick(at:)`.
    @discardableResult
    func pushBytes(_ bytes: Data, at now: Date) -> AutoReplyEvent? {
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
        var emitted: AutoReplyEvent?
        for ch in text {
            if ch == "\n" {
                let line = lineBuf
                lineBuf.removeAll(keepingCapacity: true)
                if let ev = processLine(line, at: now) {
                    emitted = ev
                }
            } else if ch != "\r" {
                lineBuf.append(ch)
            }
        }
        return emitted
    }

    /// Time-based commit check. Call periodically.
    func tick(at now: Date) -> AutoReplyEvent? {
        guard state == .body else { return nil }
        let last = lastBodyInputAt ?? now
        let started = headerStartedAt ?? now
        let idleElapsed = now.timeIntervalSince(last)
        let totalElapsed = now.timeIntervalSince(started)
        if idleElapsed >= config.idleDebounce || totalElapsed >= config.hardCap {
            return commit()
        }
        return nil
    }

    /// Force commit any pending body (e.g., on agent removal).
    func flush() -> AutoReplyEvent? {
        guard state == .body else { return nil }
        return commit()
    }

    private func processLine(_ rawLine: String, at now: Date) -> AutoReplyEvent? {
        let stripped = Self.stripAnsi(rawLine)
        let line = stripped.trimmingCharactersAtEnd(in: .whitespaces)
        let header = Self.parseHeaderLine(line)

        switch (state, header) {
        case (.idle, .some((.status, let val))):
            resetCapture()
            headerStatus = val
            rawLines.append(line)
            state = .sawStatus
            headerStartedAt = now
            return nil
        case (.sawStatus, .some((.files, let val))):
            headerFiles = val
            rawLines.append(line)
            state = .sawFiles
            return nil
        case (.sawFiles, .some((.verify, let val))):
            headerVerify = val
            rawLines.append(line)
            state = .sawVerify
            return nil
        case (.sawVerify, .some((.next, let val))):
            headerNext = val
            rawLines.append(line)
            state = .sawNext
            return nil
        case (.sawNext, .some((.fullReport, let val))):
            headerFullReport = val
            rawLines.append(line)
            state = .body
            lastBodyInputAt = now
            return nil
        case (.body, .some((.status, let val))):
            // New reply began before debounce fired — commit previous, start fresh
            let prev = commit()
            headerStatus = val
            rawLines.append(line)
            state = .sawStatus
            headerStartedAt = now
            return prev
        case (.body, _):
            if !(bodyLines.isEmpty && line.isEmpty) {
                bodyLines.append(line)
            }
            rawLines.append(line)
            lastBodyInputAt = now
            return nil
        default:
            // Out-of-order header or non-header in header phase: strict 5/5 reset
            resetCapture()
            return nil
        }
    }

    private func commit() -> AutoReplyEvent? {
        guard state == .body else { return nil }
        while bodyLines.last?.isEmpty == true {
            bodyLines.removeLast()
        }
        let event = AutoReplyEvent(
            status: headerStatus,
            files: headerFiles,
            verify: headerVerify,
            next: headerNext,
            fullReport: headerFullReport,
            body: bodyLines.joined(separator: "\n"),
            raw: rawLines.joined(separator: "\n")
        )
        resetCapture()
        return event
    }

    private func resetCapture() {
        headerStatus = ""
        headerFiles = ""
        headerVerify = ""
        headerNext = ""
        headerFullReport = ""
        bodyLines.removeAll(keepingCapacity: true)
        rawLines.removeAll(keepingCapacity: true)
        headerStartedAt = nil
        lastBodyInputAt = nil
        state = .idle
    }

    // MARK: - Static helpers

    private static func parseHeaderLine(_ line: String) -> (HeaderKey, String)? {
        guard let colonRange = line.range(of: ":") else { return nil }
        let key = String(line[..<colonRange.lowerBound])
        let rest = String(line[colonRange.upperBound...])
        let headerKey: HeaderKey
        switch key {
        case "STATUS": headerKey = .status
        case "FILES": headerKey = .files
        case "VERIFY": headerKey = .verify
        case "NEXT": headerKey = .next
        case "FULL_REPORT": headerKey = .fullReport
        default: return nil
        }
        let value = rest.hasPrefix(" ") ? String(rest.dropFirst()) : rest
        return (headerKey, value)
    }

    /// Strip ANSI CSI (`ESC [ ... letter`) and OSC (`ESC ] ... BEL | ESC \`) sequences.
    /// UTF-8 safe (operates on Characters). Lone ESCs are dropped.
    static func stripAnsi(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var iter = s.makeIterator()
        var pending: Character? = nil

        func nextChar() -> Character? {
            if let p = pending { pending = nil; return p }
            return iter.next()
        }

        while let c = nextChar() {
            if c == "\u{001b}" {
                guard let peek = iter.next() else { continue }
                if peek == "[" {
                    // CSI: read until 0x40..0x7e
                    while let cc = iter.next() {
                        if let scalar = cc.unicodeScalars.first {
                            let v = scalar.value
                            if v >= 0x40 && v <= 0x7e { break }
                        }
                    }
                } else if peek == "]" {
                    // OSC: read until BEL or ESC \\
                    while let cc = iter.next() {
                        if cc == "\u{0007}" { break }
                        if cc == "\u{001b}" {
                            if let nn = iter.next() {
                                pending = nn == "\\" ? nil : nn
                            }
                            break
                        }
                    }
                } else {
                    // Lone ESC — keep peek as next
                    pending = peek
                }
                continue
            }
            out.append(c)
        }
        return out
    }
}

private extension String {
    /// Trim trailing characters in a given set. (Foundation's
    /// `trimmingCharacters(in:)` trims both ends; we want trailing only.)
    func trimmingCharactersAtEnd(in set: CharacterSet) -> String {
        var end = endIndex
        while end > startIndex {
            let prev = index(before: end)
            let scalars = self[prev].unicodeScalars
            let isInSet = scalars.allSatisfy { set.contains($0) }
            if !isInSet { break }
            end = prev
        }
        return String(self[startIndex..<end])
    }
}
