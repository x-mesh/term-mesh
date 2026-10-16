import Foundation
import PeerProto

/// Owner-side long-poll behind `team.events.wait`: a remote leader's
/// `tm-agent wait` cannot subscribe to this machine's daemon bus, so it holds
/// a request here and wakes when the team's task events move.
///
/// `bump` is called from `teamDataQueue`, so this is a lock, not an actor, and
/// continuations are resumed only after the lock is released.
final class TeamEventWakeSignal: @unchecked Sendable {
    static let shared = TeamEventWakeSignal()
    static let method = "team.events.wait"
    static let maxWaiters = 64
    /// Below the shortest hop that carries the reply: the Swift-host proxy's
    /// 10 s `callTeamLeader` and the daemon's 15 s pending window.
    static let timeoutRangeMs: ClosedRange<Int> = 1...7000

    struct Cursor: Equatable, Sendable {
        let epoch: String
        let revision: UInt64
    }

    struct Outcome: Equatable, Sendable {
        let cursor: Cursor
        let changed: Bool
    }

    struct Request: Equatable, Sendable {
        let team: String
        let since: Cursor?
        let timeoutMs: Int
    }

    private struct Waiter {
        let team: String
        let continuation: CheckedContinuation<Outcome, Never>
    }

    let epoch: String
    private let lock = NSLock()
    private var revisions: [String: UInt64] = [:]
    private var waiters: [UUID: Waiter] = [:]

    init(epoch: String = UUID().uuidString) {
        self.epoch = epoch
    }

    var waiterCount: Int {
        lock.withLock { waiters.count }
    }

    func bump(team: String) {
        let woken: [CheckedContinuation<Outcome, Never>]
        let outcome: Outcome
        lock.lock()
        let revision = (revisions[team] ?? 0) &+ 1
        revisions[team] = revision
        outcome = Outcome(cursor: Cursor(epoch: epoch, revision: revision), changed: true)
        let ids = waiters.compactMap { $0.value.team == team ? $0.key : nil }
        woken = ids.compactMap { waiters.removeValue(forKey: $0)?.continuation }
        lock.unlock()
        for continuation in woken {
            continuation.resume(returning: outcome)
        }
    }

    func interruptAll() {
        lock.lock()
        let woken = waiters.values.map { ($0.continuation, unchanged(team: $0.team)) }
        waiters.removeAll()
        lock.unlock()
        for (continuation, outcome) in woken {
            continuation.resume(returning: outcome)
        }
    }

    func wait(team: String, since: Cursor?, timeoutMs: Int) async -> Outcome {
        let clamped = min(max(timeoutMs, Self.timeoutRangeMs.lowerBound), Self.timeoutRangeMs.upperBound)
        let id = UUID()
        var timer: Task<Void, Never>?
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                lock.lock()
                let current = Cursor(epoch: epoch, revision: revisions[team] ?? 0)
                let immediate: Outcome?
                if let since {
                    if since != current {
                        immediate = Outcome(cursor: current, changed: true)
                    } else if waiters.count >= Self.maxWaiters {
                        immediate = Outcome(cursor: current, changed: false)
                    } else {
                        waiters[id] = Waiter(team: team, continuation: continuation)
                        immediate = nil
                    }
                } else {
                    immediate = Outcome(cursor: current, changed: false)
                }
                lock.unlock()
                if let immediate {
                    continuation.resume(returning: immediate)
                    return
                }
                if Task.isCancelled {
                    resolve(id)
                    return
                }
                timer = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(clamped) * 1_000_000)
                    self?.resolve(id)
                }
            }
        } onCancel: {
            resolve(id)
        }
        timer?.cancel()
        return outcome
    }

    private func resolve(_ id: UUID) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        let outcome = waiter.map { unchanged(team: $0.team) }
        lock.unlock()
        if let waiter, let outcome {
            waiter.continuation.resume(returning: outcome)
        }
    }

    private func unchanged(team: String) -> Outcome {
        Outcome(cursor: Cursor(epoch: epoch, revision: revisions[team] ?? 0), changed: false)
    }

    static func parse(_ params: [String: Any]) -> Result<Request, PeerTeamCallFailure> {
        func invalid(_ message: String) -> Result<Request, PeerTeamCallFailure> {
            .failure(PeerTeamCallFailure(code: PeerTeamCall.ErrorCode.invalidParams, message: message))
        }
        guard let team = params["team_name"] as? String, !team.isEmpty else {
            return invalid("team_name is required")
        }
        var since: Cursor?
        if let raw = params["since"], !(raw is NSNull) {
            guard let object = raw as? [String: Any],
                  let epoch = object["epoch"] as? String,
                  let revision = Self.unsignedInteger(object["revision"]) else {
                return invalid("since must be {epoch: string, revision: unsigned integer}")
            }
            since = Cursor(epoch: epoch, revision: revision)
        }
        var timeoutMs = timeoutRangeMs.upperBound
        if let raw = params["timeout_ms"], !(raw is NSNull) {
            guard let value = Self.unsignedInteger(raw), value <= UInt64(Int.max) else {
                return invalid("timeout_ms must be an unsigned integer")
            }
            timeoutMs = Int(value)
        }
        return .success(Request(team: team, since: since, timeoutMs: timeoutMs))
    }

    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number),
              number.compare(NSNumber(value: 0)) != .orderedAscending else {
            return nil
        }
        return number.uint64Value
    }

    func respond(params: [String: Any]) async -> Result<String, PeerTeamCallFailure> {
        let request: Request
        switch Self.parse(params) {
        case .success(let parsed): request = parsed
        case .failure(let failure): return .failure(failure)
        }
        let outcome = await wait(team: request.team, since: request.since, timeoutMs: request.timeoutMs)
        let result: [String: Any] = [
            "epoch": outcome.cursor.epoch,
            "revision": NSNumber(value: outcome.cursor.revision),
            "changed": outcome.changed,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let json = String(data: data, encoding: .utf8) else {
            return .failure(PeerTeamCallFailure(
                code: PeerTeamCall.ErrorCode.hostError,
                message: "team.events.wait result was not serializable"
            ))
        }
        return .success(json)
    }
}
