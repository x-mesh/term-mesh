// Compile-time smoke check that `PeerProto` (the generated Protobuf
// bindings + framing helpers from swift/PeerProto) links into the
// term-mesh app target. Phase C-3 replaces this with the real
// peer-federation server / proxy code.
//
// Leaving it here rather than immediately removing the import gives
// the build system a concrete reason to link PeerProto, so any
// future regression (e.g. the XCLocalSwiftPackageReference being
// accidentally removed from project.pbxproj) surfaces as a build
// failure instead of silent dead-strip.

import PeerProto

enum PeerProtoBridge {
    /// Returns the protocol version string. Exists solely so the
    /// Swift linker retains the PeerProto types across optimization
    /// passes.
    static func probeProtocolVersion() -> String {
        var hello = Termmesh_Peer_V1_Hello()
        hello.protocolVersion = "1.0.0"
        return hello.protocolVersion
    }
}
