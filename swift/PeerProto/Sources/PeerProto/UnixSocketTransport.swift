//  NWConnection-backed Unix-socket transport for `PeerSession`.
//  Wraps Apple's Network framework so callers get plain
//  `() async throws -> Data` / `(Data) async throws` semantics.
//
//  Phase C-3b-α: end-to-end verification that Swift can connect to a
//  real term-meshd peer socket. The daemon's wire format is
//  language-agnostic; this class is the glue.

import Foundation
import Network

public enum UnixSocketTransportError: Error, Equatable {
    case connectFailed(description: String)
    case connectTimedOut(seconds: TimeInterval)
    case readTimedOut(seconds: TimeInterval)
    case notReady
    case closed
    case underlying(description: String)
}

extension UnixSocketTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .connectFailed(let description):
            return "Unix socket connection failed: \(description)"
        case .connectTimedOut(let seconds):
            return "Unix socket connection timed out after \(String(format: "%.1f", seconds))s"
        case .readTimedOut(let seconds):
            return "Unix socket read timed out after \(String(format: "%.1f", seconds))s"
        case .notReady:
            return "Unix socket connection is not ready"
        case .closed:
            return "Unix socket connection is closed"
        case .underlying(let description):
            return "Unix socket error: \(description)"
        }
    }
}

public actor UnixSocketTransport {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var isClosed = false
    private var readTimeoutSeconds: TimeInterval?

    private init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Connect to `socketPath` and return once the Network framework
    /// reports `.ready`. Throws on connect failures with a descriptive
    /// message — the underlying `NWError` values are opaque.
    public static func connect(
        socketPath: String,
        timeoutSeconds: TimeInterval = 5
    ) async throws -> UnixSocketTransport {
        let endpoint = NWEndpoint.unix(path: socketPath)
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "term-mesh.peer.transport", qos: .userInitiated)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Guard: stateUpdateHandler fires on multiple transitions; resume only once.
            let resumed = ResumedFlag()
            let fail: @Sendable (Error) -> Void = { error in
                if resumed.setOnce() {
                    connection.cancel()
                    cont.resume(throwing: error)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.setOnce() {
                        cont.resume()
                    }
                case .failed(let err):
                    fail(UnixSocketTransportError.connectFailed(
                        description: String(describing: err)
                    ))
                case .waiting:
                    // Keep waiting until the explicit timeout fires. NWConnection
                    // can stay in `.waiting` for unreachable Unix endpoints, and
                    // callers need a deterministic upper bound for that state.
                    break
                case .cancelled:
                    fail(UnixSocketTransportError.closed)
                default:
                    break
                }
            }
            if timeoutSeconds > 0 {
                queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                    fail(UnixSocketTransportError.connectTimedOut(seconds: timeoutSeconds))
                }
            }
            connection.start(queue: queue)
        }

        connection.stateUpdateHandler = nil
        return UnixSocketTransport(connection: connection, queue: queue)
    }

    public func read() async throws -> Data {
        if isClosed {
            throw UnixSocketTransportError.closed
        }
        let connection = self.connection
        let queue = self.queue
        let readTimeoutSeconds = self.readTimeoutSeconds
        return try await withCheckedThrowingContinuation { cont in
            let resumed = ResumedFlag()
            if let readTimeoutSeconds, readTimeoutSeconds > 0 {
                queue.asyncAfter(deadline: .now() + readTimeoutSeconds) { [weak self] in
                    if resumed.setOnce() {
                        if let self {
                            Task { await self.close() }
                        } else {
                            connection.cancel()
                        }
                        cont.resume(throwing: UnixSocketTransportError.readTimedOut(
                            seconds: readTimeoutSeconds
                        ))
                    }
                }
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
                data, _, isComplete, error in
                if let error = error {
                    if resumed.setOnce() {
                        cont.resume(throwing: UnixSocketTransportError.underlying(
                            description: String(describing: error)
                        ))
                    }
                    return
                }
                // `isComplete` with empty data == peer closed their write half.
                let payload = data ?? Data()
                if payload.isEmpty && isComplete {
                    // Empty Data signals EOF to PeerSession.readFrame.
                    if resumed.setOnce() {
                        cont.resume(returning: Data())
                    }
                    return
                }
                if resumed.setOnce() {
                    cont.resume(returning: payload)
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
        if isClosed {
            throw UnixSocketTransportError.closed
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    cont.resume(throwing: UnixSocketTransportError.underlying(
                        description: String(describing: error)
                    ))
                } else {
                    cont.resume()
                }
            })
        }
    }

    public func close() {
        isClosed = true
        connection.cancel()
    }

    public func setReadTimeoutSeconds(_ seconds: TimeInterval?) {
        readTimeoutSeconds = seconds
    }
}

/// Tiny single-fire flag for guarding continuation resumes.
/// Not `Sendable` in a strict sense, but adequate here because it's used
/// only inside a single `stateUpdateHandler` callback chain serialized on
/// the connection's queue.
private final class ResumedFlag: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()

    func setOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
