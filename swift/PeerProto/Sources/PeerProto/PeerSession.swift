//  Transport-agnostic client for the peer-federation handshake + control
//  plane. Callers provide read / write callbacks over whatever bytes-in /
//  bytes-out channel they have (Unix socket, pipe, in-memory stream); the
//  session handles framing, message sequencing, and the handshake state
//  machine.
//
//  Phase C-3a ships the minimum needed to list surfaces from a Rust
//  term-meshd host. Phase C-3b will add AttachSurface + streaming,
//  probably on top of the same type.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SwiftProtobuf

public enum PeerSessionError: Error, Equatable {
    case unexpectedEof
    case framing(PeerFramingError)
    case protocolVersionMismatch(host: String, client: String)
    case authRejected(reason: String)
    case attachRejected(reason: String)
    case unexpectedMessage(String)
}

/// Post-handshake result of a successful AttachSurface.
public struct PeerAttachOutcome: Sendable, Equatable {
    public let surfaceID: Data
    public let initialByteSeq: UInt64
    public let grantedMode: Termmesh_Peer_V1_AttachMode
}

/// Messages a post-attach session can deliver. `other` covers payloads
/// we don't model yet (WorkspaceUpdate.splitChanged, DataAck, Pong, etc.)
/// so callers don't have to handle every oneof variant.
public enum PeerIncomingMessage: Sendable {
    case ptyData(surfaceID: Data, byteSeq: UInt64, payload: Data)
    case workspaceMeta(cwd: String, branch: String, ports: [UInt32], latestNotification: String)
    case workspaceSurfaceAdded(Termmesh_Peer_V1_SurfaceInfo)
    case workspaceSurfaceRemoved(surfaceID: Data)
    case workspaceSurfaceRetitled(surfaceID: Data, title: String)
    case error(code: UInt32, message: String)
    case goodbye(reason: String)
    case other
}

public struct PeerSessionOptions: Sendable {
    public var displayName: String
    public var peerID: Data
    public var appVersion: String
    public var authMethod: String
    public var clientProtocolVersion: String

    public init(
        displayName: String = "term-mesh-swift",
        peerID: Data = Data(count: 16),
        appVersion: String = "0.0.1",
        authMethod: String = "ssh-passthrough",
        clientProtocolVersion: String = "1.0.0"
    ) {
        self.displayName = displayName
        self.peerID = peerID
        self.appVersion = appVersion
        self.authMethod = authMethod
        self.clientProtocolVersion = clientProtocolVersion
    }
}

public struct PeerSessionInfo: Sendable, Equatable {
    public let hostDisplayName: String
    public let hostAppVersion: String
    public let hostProtocolVersion: String
    public let sessionID: Data
}

public typealias PeerReadFn = @Sendable () async throws -> Data
public typealias PeerWriteFn = @Sendable (Data) async throws -> Void

public actor PeerSession {
    private let read: PeerReadFn
    private let write: PeerWriteFn
    private var seq: UInt64 = 0
    private var pendingInbound = Data()

    public init(read: @escaping PeerReadFn, write: @escaping PeerWriteFn) {
        self.read = read
        self.write = write
    }

    // MARK: - Handshake

    @discardableResult
    public func handshake(options: PeerSessionOptions = .init()) async throws -> PeerSessionInfo {
        try await sendHello(options: options)
        let host = try await expectHello()
        if majorComponent(of: host.protocolVersion) != majorComponent(of: options.clientProtocolVersion) {
            throw PeerSessionError.protocolVersionMismatch(
                host: host.protocolVersion,
                client: options.clientProtocolVersion
            )
        }
        _ = try await expectAuthChallenge()
        try await sendAuth(method: options.authMethod)
        let result = try await expectAuthResult()
        return PeerSessionInfo(
            hostDisplayName: host.displayName,
            hostAppVersion: host.appVersion,
            hostProtocolVersion: host.protocolVersion,
            sessionID: result.sessionID
        )
    }

    // MARK: - ListSurfaces

    public func listSurfaces() async throws -> [Termmesh_Peer_V1_SurfaceInfo] {
        try await sendEnvelope { env in
            env.listSurfaces = Termmesh_Peer_V1_ListSurfaces()
        }
        let reply = try await readFrame()
        guard case .surfaceList(let list) = reply.payload else {
            throw PeerSessionError.unexpectedMessage(String(describing: reply.payload))
        }
        return list.surfaces
    }

    // MARK: - AttachSurface

    public func attachSurface(
        id: Data,
        mode: Termmesh_Peer_V1_AttachMode = .coWrite,
        cols: UInt32 = 80,
        rows: UInt32 = 24,
        resumeFromSeq: UInt64 = 0
    ) async throws -> PeerAttachOutcome {
        try await sendEnvelope { env in
            var req = Termmesh_Peer_V1_AttachSurface()
            req.surfaceID = id
            req.mode = mode
            req.clientCols = cols
            req.clientRows = rows
            req.resumeFromSeq = resumeFromSeq
            env.attachSurface = req
        }
        let reply = try await readFrame()
        guard case .attachResult(let r) = reply.payload else {
            throw PeerSessionError.unexpectedMessage(
                "expected AttachResult, got \(String(describing: reply.payload))"
            )
        }
        if !r.accepted {
            throw PeerSessionError.attachRejected(reason: r.reason)
        }
        return PeerAttachOutcome(
            surfaceID: r.surfaceID,
            initialByteSeq: r.initialSeq,
            grantedMode: r.grantedMode
        )
    }

    // MARK: - Post-attach I/O

    /// Read the next envelope from the host and classify it. Callers
    /// typically loop on this in a Task and route by case. Unhandled
    /// payload types collapse into `.other` so this surface stays stable
    /// as the protocol grows (Phase 2.4b's WorkspaceUpdate.meta is
    /// already surfaced here).
    public func receiveNextMessage() async throws -> PeerIncomingMessage {
        let env = try await readFrame()
        switch env.payload {
        case .ptyData(let p):
            return .ptyData(surfaceID: p.surfaceID, byteSeq: p.byteSeq, payload: p.payload)
        case .workspaceUpdate(let wu):
            switch wu.kind {
            case .meta(let m):
                return .workspaceMeta(
                    cwd: m.cwd,
                    branch: m.branch,
                    ports: m.ports,
                    latestNotification: m.latestNotification
                )
            case .added(let a):
                return .workspaceSurfaceAdded(a.surface)
            case .removed(let r):
                return .workspaceSurfaceRemoved(surfaceID: r.surfaceID)
            case .retitled(let rt):
                return .workspaceSurfaceRetitled(surfaceID: rt.surfaceID, title: rt.title)
            default:
                return .other
            }
        case .error(let e):
            return .error(code: e.code, message: e.message)
        case .goodbye(let g):
            return .goodbye(reason: g.reason)
        default:
            return .other
        }
    }

    /// Send raw keystrokes to an attached surface. `keys` is the bytes the
    /// child would see on its stdin (the caller is responsible for any
    /// terminal escape encoding).
    public func sendInput(surfaceID: Data, keys: Data) async throws {
        try await sendEnvelope { env in
            var input = Termmesh_Peer_V1_Input()
            input.surfaceID = surfaceID
            input.kind = .keys(keys)
            env.input = input
        }
    }

    /// Paste a block of text as a single Input frame.
    public func sendPaste(surfaceID: Data, text: Data) async throws {
        try await sendEnvelope { env in
            var input = Termmesh_Peer_V1_Input()
            input.surfaceID = surfaceID
            var paste = Termmesh_Peer_V1_Paste()
            paste.text = text
            input.kind = .paste(paste)
            env.input = input
        }
    }

    public func sendResize(surfaceID: Data, cols: UInt32, rows: UInt32) async throws {
        try await sendEnvelope { env in
            var r = Termmesh_Peer_V1_Resize()
            r.surfaceID = surfaceID
            r.cols = cols
            r.rows = rows
            env.resize = r
        }
    }

    // MARK: - Goodbye

    public func sendGoodbye(reason: String) async throws {
        try await sendEnvelope { env in
            var gb = Termmesh_Peer_V1_Goodbye()
            gb.reason = reason
            env.goodbye = gb
        }
    }

    // MARK: - Private: envelope plumbing

    private func nextSeq() -> UInt64 {
        seq += 1
        return seq
    }

    private func sendEnvelope(configure: (inout Termmesh_Peer_V1_Envelope) -> Void) async throws {
        var env = Termmesh_Peer_V1_Envelope()
        env.seq = nextSeq()
        configure(&env)
        let frame: Data
        do {
            frame = try encodeFrame(env)
        } catch let err as PeerFramingError {
            throw PeerSessionError.framing(err)
        }
        try await write(frame)
    }

    private func sendHello(options: PeerSessionOptions) async throws {
        try await sendEnvelope { env in
            var hello = Termmesh_Peer_V1_Hello()
            hello.protocolVersion = options.clientProtocolVersion
            hello.peerID = options.peerID
            hello.displayName = options.displayName
            hello.appVersion = options.appVersion
            env.hello = hello
        }
    }

    private func sendAuth(method: String) async throws {
        try await sendEnvelope { env in
            var auth = Termmesh_Peer_V1_Auth()
            auth.method = method
            env.auth = auth
        }
    }

    private func expectHello() async throws -> Termmesh_Peer_V1_Hello {
        let env = try await readFrame()
        guard case .hello(let h) = env.payload else {
            throw PeerSessionError.unexpectedMessage("expected Hello, got \(String(describing: env.payload))")
        }
        return h
    }

    private func expectAuthChallenge() async throws -> Termmesh_Peer_V1_AuthChallenge {
        let env = try await readFrame()
        guard case .authChallenge(let c) = env.payload else {
            throw PeerSessionError.unexpectedMessage("expected AuthChallenge, got \(String(describing: env.payload))")
        }
        return c
    }

    private func expectAuthResult() async throws -> Termmesh_Peer_V1_AuthResult {
        let env = try await readFrame()
        guard case .authResult(let r) = env.payload else {
            throw PeerSessionError.unexpectedMessage("expected AuthResult, got \(String(describing: env.payload))")
        }
        if !r.accepted {
            throw PeerSessionError.authRejected(reason: r.reason)
        }
        return r
    }

    private func readFrame() async throws -> Termmesh_Peer_V1_Envelope {
        while true {
            do {
                if let env = try decodeFrame(from: &pendingInbound) {
                    return env
                }
            } catch let err as PeerFramingError {
                throw PeerSessionError.framing(err)
            }
            let chunk = try await read()
            if chunk.isEmpty {
                throw PeerSessionError.unexpectedEof
            }
            pendingInbound.append(chunk)
        }
    }
}

private func majorComponent(of semver: String) -> Substring {
    semver.split(separator: ".").first ?? Substring(semver)
}
