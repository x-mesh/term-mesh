#if DEBUG
import Foundation

/// Unified ring-buffer event log for key, mouse, focus, and split events.
/// Writes entries to a debug log path so `tail -f` works in real time.
///
/// ## Safety guarantees
/// - Persistent FileHandle (no per-call open/close)
/// - 200ms coalesced flush (max 5 writes/sec to disk)
/// - Circuit breaker: >500 logs/sec → auto-drop, 5s cooldown
/// - Bounded write queue (max 2000 pending entries, ~200KB)
/// - 10MB file rotation
/// - O(1) circular ring buffer
public final class DebugEventLog: @unchecked Sendable {
    public static let shared = DebugEventLog()

    // MARK: - Ring buffer (O(1) circular)
    private let ringCapacity = 500
    private var ring: [String]
    private var ringHead = 0
    private var ringCount = 0

    // MARK: - Buffered write
    private var pendingWrites: [String] = []
    private let maxPendingWrites = 2000
    private var pendingDropCount = 0
    private let flushInterval: TimeInterval = 0.2
    private let maxFileSizeBytes: UInt64 = 10 * 1024 * 1024  // 10 MB

    private var fileHandle: FileHandle?
    private var flushTimer: DispatchSourceTimer?

    // MARK: - Circuit breaker
    private enum CircuitState { case closed, open }
    private var circuitState: CircuitState = .closed
    private let circuitThreshold = 500          // logs/sec
    private let circuitCooldown: TimeInterval = 5.0
    private var windowStart = Date()
    private var windowCount = 0
    private var circuitOpenedAt: Date?

    private let queue = DispatchQueue(label: "cmux.debug-event-log")
    public static let logPath = resolveLogPath()

    // Per-queue formatter instance (no thread-safety issue when used only on `queue`)
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // MARK: - Init

    private init() {
        ring = Array(repeating: "", count: ringCapacity)
        queue.async { [weak self] in
            self?.setupFileHandle()
            self?.setupFlushTimer()
        }
    }

    // MARK: - File setup

    private func setupFileHandle() {
        let path = Self.logPath
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            fileHandle = handle
        }
    }

    private func setupFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + flushInterval, repeating: flushInterval,
                       leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.flushToFile()
        }
        timer.resume()
        flushTimer = timer
    }

    // MARK: - Public API

    public func log(_ msg: String) {
        // Capture Date on caller thread (atomic), format on queue
        let now = Date()
        queue.async {
            self.logInternal(msg, date: now)
        }
    }

    /// Force-flush pending buffer then overwrite file with full ring-buffer contents.
    public func dump() {
        queue.async {
            self.flushToFile()
            let content = self.ringEntries().joined(separator: "\n") + "\n"
            try? content.write(toFile: Self.logPath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Internal (always on `queue`)

    private func logInternal(_ msg: String, date: Date) {
        // 1. Circuit breaker check
        if !checkCircuitBreaker(date: date) {
            return  // circuit open → drop
        }

        let ts = formatter.string(from: date)
        let entry = "\(ts) \(msg)"

        // 2. Ring buffer — O(1) circular insert
        ring[ringHead] = entry
        ringHead = (ringHead + 1) % ringCapacity
        if ringCount < ringCapacity { ringCount += 1 }

        // 3. Write queue (bounded — OOM prevention)
        if pendingWrites.count < maxPendingWrites {
            pendingWrites.append(entry)
        } else {
            pendingDropCount += 1
        }
    }

    /// Returns true if write is allowed.
    private func checkCircuitBreaker(date: Date) -> Bool {
        // Reset 1-second sliding window
        if date.timeIntervalSince(windowStart) >= 1.0 {
            windowStart = date
            windowCount = 0
        }
        windowCount += 1

        switch circuitState {
        case .closed:
            if windowCount > circuitThreshold {
                circuitState = .open
                circuitOpenedAt = date
                let warn = "\(formatter.string(from: date)) [DebugEventLog] CIRCUIT OPEN: \(windowCount) logs/sec > \(circuitThreshold). Dropping for \(Int(circuitCooldown))s."
                if pendingWrites.count < maxPendingWrites {
                    pendingWrites.append(warn)
                }
                return false
            }
            return true

        case .open:
            guard let openedAt = circuitOpenedAt,
                  date.timeIntervalSince(openedAt) >= circuitCooldown else {
                return false  // still cooling down
            }
            circuitState = .closed
            circuitOpenedAt = nil
            windowCount = 0
            let resume = "\(formatter.string(from: date)) [DebugEventLog] CIRCUIT CLOSED: resuming after \(Int(circuitCooldown))s cooldown."
            if pendingWrites.count < maxPendingWrites {
                pendingWrites.append(resume)
            }
            return true
        }
    }

    // MARK: - Flush (called by timer, always on `queue`)

    private func flushToFile() {
        // Append drop summary if any
        if pendingDropCount > 0 {
            let summary = "\(formatter.string(from: Date())) [DebugEventLog] \(pendingDropCount) entries dropped (write queue full)."
            pendingWrites.append(summary)
            pendingDropCount = 0
        }

        guard !pendingWrites.isEmpty else { return }

        let lines = pendingWrites
        pendingWrites.removeAll(keepingCapacity: true)

        let combined = lines.joined(separator: "\n") + "\n"
        guard let data = combined.data(using: .utf8), !data.isEmpty else { return }

        rotateIfNeeded()

        guard let handle = fileHandle else {
            setupFileHandle()
            fileHandle?.write(data)
            return
        }
        handle.write(data)
    }

    /// Rotate file when it exceeds `maxFileSizeBytes`. Must be called on `queue`.
    private func rotateIfNeeded() {
        guard let handle = fileHandle else {
            setupFileHandle()
            return
        }
        let currentSize = handle.seekToEndOfFile()
        guard currentSize > maxFileSizeBytes else { return }

        handle.closeFile()
        fileHandle = nil

        let path = Self.logPath
        let rotatePath = path + ".1"
        try? FileManager.default.removeItem(atPath: rotatePath)
        try? FileManager.default.moveItem(atPath: path, toPath: rotatePath)
        FileManager.default.createFile(atPath: path, contents: nil)
        if let newHandle = FileHandle(forWritingAtPath: path) {
            fileHandle = newHandle
        }
    }

    // MARK: - Ring buffer read (preserves order)

    private func ringEntries() -> [String] {
        guard ringCount > 0 else { return [] }
        if ringCount < ringCapacity {
            return Array(ring[0..<ringCount])
        }
        return Array(ring[ringHead..<ringCapacity]) + Array(ring[0..<ringHead])
    }

    // MARK: - Path resolution

    private static func sanitizePathToken(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let unicode = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let sanitized = String(unicode).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return sanitized.isEmpty ? "debug" : sanitized
    }

    private static func resolveLogPath() -> String {
        let env = ProcessInfo.processInfo.environment

        if let explicit = (env["TERMMESH_DEBUG_LOG"] ?? env["CMUX_DEBUG_LOG"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return explicit
        }

        if let tag = (env["TERMMESH_TAG"] ?? env["CMUX_TAG"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tag.isEmpty {
            return "/tmp/cmux-debug-\(sanitizePathToken(tag)).log"
        }

        if let socketPath = (env["TERMMESH_SOCKET_PATH"] ?? env["CMUX_SOCKET_PATH"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !socketPath.isEmpty {
            let socketBase = URL(fileURLWithPath: socketPath).deletingPathExtension().lastPathComponent
            if socketBase.hasPrefix("cmux-debug-") || socketBase.hasPrefix("term-mesh-debug-") {
                return "/tmp/\(socketBase).log"
            }
        }

        if let bundleId = Bundle.main.bundleIdentifier,
           bundleId != "com.cmuxterm.app.debug" {
            return "/tmp/cmux-debug-\(sanitizePathToken(bundleId)).log"
        }

        return "/tmp/cmux-debug.log"
    }
}

/// Convenience free function. Logs the message and appends to the configured debug log path.
public func dlog(_ msg: String) {
    DebugEventLog.shared.log(msg)
}
#endif
