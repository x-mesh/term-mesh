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
    case notReady
    case closed
    case underlying(description: String)
}

public actor UnixSocketTransport {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var isClosed = false

    private init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Connect to `socketPath` and return once the Network framework
    /// reports `.ready`. Throws on connect failures with a descriptive
    /// message — the underlying `NWError` values are opaque.
    public static func connect(socketPath: String) async throws -> UnixSocketTransport {
        let endpoint = NWEndpoint.unix(path: socketPath)
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "term-mesh.peer.transport", qos: .userInitiated)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // Guard: stateUpdateHandler fires on multiple transitions; resume only once.
            let resumed = ResumedFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.setOnce() {
                        cont.resume()
                    }
                case .failed(let err):
                    if resumed.setOnce() {
                        cont.resume(throwing: UnixSocketTransportError.connectFailed(
                            description: String(describing: err)
                        ))
                    }
                case .waiting(let err):
                    // .waiting means the OS can't yet reach the endpoint (e.g. path
                    // doesn't exist). Treat as fatal here; callers poll for the
                    // socket to appear before connecting.
                    if resumed.setOnce() {
                        cont.resume(throwing: UnixSocketTransportError.connectFailed(
                            description: "waiting: \(err)"
                        ))
                    }
                case .cancelled:
                    if resumed.setOnce() {
                        cont.resume(throwing: UnixSocketTransportError.closed)
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        return UnixSocketTransport(connection: connection, queue: queue)
    }

    public func read() async throws -> Data {
        if isClosed {
            throw UnixSocketTransportError.closed
        }
        return try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
                data, _, isComplete, error in
                if let error = error {
                    cont.resume(throwing: UnixSocketTransportError.underlying(
                        description: String(describing: error)
                    ))
                    return
                }
                // `isComplete` with empty data == peer closed their write half.
                let payload = data ?? Data()
                if payload.isEmpty && isComplete {
                    // Empty Data signals EOF to PeerSession.readFrame.
                    cont.resume(returning: Data())
                    return
                }
                cont.resume(returning: payload)
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
