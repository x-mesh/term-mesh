//  Length-prefixed Protobuf framing for the peer-federation wire protocol,
//  Swift side. Mirrors the behavior of `daemon/term-meshd/src/peer/framing.rs`
//  and the sync variant in `daemon/term-mesh-cli/src/peer.rs`.
//
//  Each frame on the wire is a little-endian UInt32 byte length followed by
//  a Protobuf-encoded `Termmesh_Peer_V1_Envelope`. Frames larger than
//  `maxFrameBytes` must be rejected.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SwiftProtobuf

public enum PeerFramingError: Error, Equatable {
    case frameTooLarge(size: UInt32)
    case unexpectedEnd
    case decode(description: String)
}

public let maxFrameBytes: UInt32 = 16 * 1024 * 1024

/// Encode an `Envelope` with the length prefix ready to be written to a stream.
public func encodeFrame(_ envelope: Termmesh_Peer_V1_Envelope) throws -> Data {
    let payload = try envelope.serializedData()
    if payload.count > Int(maxFrameBytes) {
        throw PeerFramingError.frameTooLarge(size: UInt32(payload.count))
    }
    var frame = Data(capacity: 4 + payload.count)
    var len = UInt32(payload.count).littleEndian
    withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
    frame.append(payload)
    return frame
}

/// Decode the next framed envelope from `data`, consuming its bytes.
/// Returns `nil` when `data` does not yet contain a complete frame; the
/// caller should keep reading and retry.
public func decodeFrame(from data: inout Data) throws -> Termmesh_Peer_V1_Envelope? {
    guard data.count >= 4 else { return nil }
    let len: UInt32 = data.withUnsafeBytes { raw in
        raw.loadUnaligned(as: UInt32.self).littleEndian
    }
    if len > maxFrameBytes {
        throw PeerFramingError.frameTooLarge(size: len)
    }
    let total = 4 + Int(len)
    guard data.count >= total else { return nil }
    let payload = data.subdata(in: 4..<total)
    data.removeSubrange(0..<total)
    do {
        return try Termmesh_Peer_V1_Envelope(serializedBytes: payload)
    } catch {
        throw PeerFramingError.decode(description: String(describing: error))
    }
}
