import Foundation

// Swift port of `daemon/term-meshd/src/auto_reply.rs` (Phase B1, Fix D).
//
// Sliding window approach: keeps the last `bufferCap` ANSI-stripped lines.
// On tick(), scans for STATUS (mandatory) + FILES/VERIFY/NEXT/FULL_REPORT
// (optional, default "n/a"). Commits when:
//   - all 5 present + idleDebounce elapsed, or
//   - STATUS + ≥2 others + hardCap elapsed (partial commit), or
//   - flush() called (agent removal) with STATUS + ≥1 other.
//
// Order of lines and interleaved noise no longer matter (Fix D replaces
// strict state machine from Fix C).

struct AutoReplyEvent: Equatable {
    let status: String
    let files: String
    let verify: String
    let next: String
    let fullReport: String
    let body: String
    let raw: String

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
    // Wide enough to hold a whole terminal screen. 30 lines was sized for an
    // append-only delta — a handful of freshly printed lines — but an agent TUI
    // redraws in place, so the poller now feeds the full screen whenever the
    // diff comes back empty. At 30 the five header lines were pushed straight
    // back out by everything rendered below them, and the detector went looking
    // for a STATUS line it had just been handed.
    private static let bufferCap = 300
    private static let headerPrefixes = ["STATUS:", "FILES:", "VERIFY:", "NEXT:", "FULL_REPORT:"]
    /// Glyphs agent CLIs use to bullet a reply. Claude uses ●; the rest are
    /// here because the next CLI will pick a different one.
    private static let listMarkers: Set<Character> = [
        "●", "•", "◦", "○", "⏺", "▪", "▸", "▶", "·", "*", "-", "+", ">", "│", "┃", "|",
    ]

    private let config: AutoReplyDetectorConfig
    private var lineBuffer: [String] = []
    private var lineBuf: String = ""
    private var statusSeenAt: Date?
    private var lastInputAt: Date?
    private var committed = false

    init(config: AutoReplyDetectorConfig = .init()) {
        self.config = config
    }

    /// Accept only protocol verdicts, exactly as written. Deliberately does no
    /// trimming or case folding: placeholders, comma-separated choices, partial
    /// matches, and values with extra whitespace are not agent verdicts.
    static func validatedStatus(_ value: String) -> String? {
        switch value {
        case "DONE", "BLOCKED", "NEEDS_REVIEW":
            return value
        default:
            return nil
        }
    }

    /// Feed raw bytes. Returns nil always; commits via tick(at:) or flush().
    @discardableResult
    func pushBytes(_ bytes: Data, at now: Date) -> AutoReplyEvent? {
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
        for ch in text {
            if ch == "\n" {
                let line = lineBuf
                lineBuf.removeAll(keepingCapacity: true)
                pushLine(line, at: now)
            } else if ch != "\r" {
                lineBuf.append(ch)
            }
        }
        return nil
    }

    private func pushLine(_ rawLine: String, at now: Date) {
        // Agent TUIs indent their output, so remove indentation and a possible
        // bullet. Preserve trailing whitespace on STATUS specifically: the
        // protocol value must be exact, and trimming it would turn an invalid
        // `DONE ` into `DONE`. Other lines retain their historical normalization.
        let unmarked = Self.unmarked(
            Self.stripAnsi(rawLine).trimmingCharactersAtStart(in: .whitespaces)
        )
        let line = unmarked.hasPrefix("STATUS:")
            ? unmarked
            : unmarked.trimmingCharactersAtEnd(in: .whitespaces)
        if lineBuffer.count >= Self.bufferCap {
            lineBuffer.removeFirst()
        }
        lineBuffer.append(line)
        lastInputAt = now
        if Self.validatedStatusValue(in: line) != nil {
            statusSeenAt = now
            committed = false
        }
    }

    /// Drop the list marker an agent TUI puts in front of the first line of a
    /// reply. Claude renders the header as `● STATUS: DONE` and leaves the
    /// four lines under it merely indented, so trimming whitespace rescued
    /// FILES/VERIFY/NEXT/FULL_REPORT while STATUS — the one field the detector
    /// requires — stayed hidden behind a bullet.
    ///
    /// The marker comes off only when a header follows it, so a line of prose
    /// that opens with a dash keeps its dash.
    private static func unmarked(_ line: String) -> String {
        guard let first = line.first, Self.listMarkers.contains(first) else { return line }
        let rest = String(line.dropFirst()).trimmingCharactersAtStart(in: .whitespaces)
        guard Self.headerPrefixes.contains(where: { rest.hasPrefix($0) }) else { return line }
        return rest
    }

    func tick(at now: Date) -> AutoReplyEvent? {
        if committed { return nil }
        guard let anchor = statusBlockStart() else { statusSeenAt = nil; return nil }
        guard let rawStatus = scanField("STATUS", from: anchor),
              let status = Self.validatedStatus(rawStatus) else {
            statusSeenAt = nil
            return nil
        }
        guard let statusAt = statusSeenAt else { return nil }

        let files = scanField("FILES", from: anchor)
        let verify = scanField("VERIFY", from: anchor)
        let next = scanField("NEXT", from: anchor)
        let fullReport = scanField("FULL_REPORT", from: anchor)
        let others = [files, verify, next, fullReport].filter { $0 != nil }.count

        let last = lastInputAt ?? now
        let idle = now.timeIntervalSince(last)
        let cap = now.timeIntervalSince(statusAt)

        let allPresent = others == 4
        if (allPresent && idle >= config.idleDebounce) || (others >= 2 && cap >= config.hardCap) {
            return emit(
                status: status,
                files: files ?? "n/a",
                verify: verify ?? "n/a",
                next: next ?? "n/a",
                fullReport: fullReport ?? "n/a"
            )
        }
        return nil
    }

    func flush() -> AutoReplyEvent? {
        if committed { return nil }
        guard let anchor = statusBlockStart() else { return nil }
        guard let rawStatus = scanField("STATUS", from: anchor),
              let status = Self.validatedStatus(rawStatus) else { return nil }
        let files = scanField("FILES", from: anchor)
        let verify = scanField("VERIFY", from: anchor)
        let next = scanField("NEXT", from: anchor)
        let fullReport = scanField("FULL_REPORT", from: anchor)
        let others = [files, verify, next, fullReport].filter { $0 != nil }.count
        if others == 0 { return nil }
        return emit(
            status: status,
            files: files ?? "n/a",
            verify: verify ?? "n/a",
            next: next ?? "n/a",
            fullReport: fullReport ?? "n/a"
        )
    }

    private func emit(status: String, files: String, verify: String, next: String, fullReport: String) -> AutoReplyEvent? {
        // Body starts after the LAST header line so noise between headers is excluded.
        let lastHeaderIdx = lineBuffer.indices.last { i in
            Self.headerPrefixes.contains { lineBuffer[i].hasPrefix($0) }
        }
        let statusIdx = lineBuffer.indices.last { lineBuffer[$0].hasPrefix("STATUS:") } ?? 0

        let bodySlice: [String]
        if let lh = lastHeaderIdx {
            bodySlice = Array(lineBuffer.dropFirst(lh + 1))
        } else {
            bodySlice = []
        }

        let bodyStart = bodySlice.firstIndex(where: { !$0.isEmpty }) ?? 0
        let bodyEnd = bodySlice.indices.last(where: { !bodySlice[$0].isEmpty }).map { $0 + 1 } ?? 0
        let body = bodyStart < bodyEnd ? bodySlice[bodyStart..<bodyEnd].joined(separator: "\n") : ""

        let raw = lineBuffer.dropFirst(statusIdx).joined(separator: "\n")

        committed = true
        lineBuffer.removeAll(keepingCapacity: true)
        statusSeenAt = nil
        lastInputAt = nil

        return AutoReplyEvent(status: status, files: files, verify: verify, next: next,
                              fullReport: fullReport, body: body, raw: raw)
    }

    /// Returns the buffer index from which field scans should start.
    ///
    /// When multiple STATUS headers exist in the window, anchors to the latest
    /// STATUS position so stale fields from a prior block are not picked up.
    /// When only one STATUS exists, returns 0 to preserve out-of-order scanning.
    private func statusBlockStart() -> Int? {
        var latest: Int? = nil
        var prev: Int? = nil
        for (i, line) in lineBuffer.enumerated() {
            if Self.validatedStatusValue(in: line) != nil {
                prev = latest
                latest = i
            }
        }
        guard latest != nil else { return nil }
        return prev != nil ? latest : 0
    }

    private static func validatedStatusValue(in line: String) -> String? {
        let prefix = "STATUS:"
        guard line.hasPrefix(prefix) else { return nil }
        let rest = String(line.dropFirst(prefix.count))
        let value = rest.hasPrefix(" ") ? String(rest.dropFirst()) : rest
        return validatedStatus(value)
    }

    private func scanField(_ name: String, from fromIdx: Int = 0) -> String? {
        let prefix = "\(name):"
        guard !lineBuffer.isEmpty else { return nil }
        let maxIdx = lineBuffer.count - 1
        guard fromIdx <= maxIdx else { return nil }
        for i in stride(from: maxIdx, through: fromIdx, by: -1) {
            let line = lineBuffer[i]
            if line.hasPrefix(prefix) {
                let rest = String(line.dropFirst(prefix.count))
                let val = rest.hasPrefix(" ") ? String(rest.dropFirst()) : rest
                if !val.isEmpty { return val }
            }
        }
        return nil
    }

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
                    while let cc = iter.next() {
                        if let scalar = cc.unicodeScalars.first {
                            let v = scalar.value
                            if v >= 0x40 && v <= 0x7e { break }
                        }
                    }
                } else if peek == "]" {
                    while let cc = iter.next() {
                        if cc == "\u{0007}" { break }
                        if cc == "\u{001b}" {
                            if let nn = iter.next() { pending = nn == "\\" ? nil : nn }
                            break
                        }
                    }
                } else {
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
    func trimmingCharactersAtStart(in set: CharacterSet) -> String {
        var start = startIndex
        while start < endIndex {
            let scalars = self[start].unicodeScalars
            if !scalars.allSatisfy({ set.contains($0) }) { break }
            start = index(after: start)
        }
        return String(self[start..<endIndex])
    }

    func trimmingCharactersAtEnd(in set: CharacterSet) -> String {
        var end = endIndex
        while end > startIndex {
            let prev = index(before: end)
            let scalars = self[prev].unicodeScalars
            if !scalars.allSatisfy({ set.contains($0) }) { break }
            end = prev
        }
        return String(self[startIndex..<end])
    }
}
