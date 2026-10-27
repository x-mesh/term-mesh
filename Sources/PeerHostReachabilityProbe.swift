import Foundation
import Network

/// The first hop ssh dials for a peer host.
struct PeerHostProbeTarget: Equatable, Sendable {
    let host: String
    let port: UInt16
}

/// A TCP connect to a peer host's ssh port, answering "is it worth starting
/// ssh again?" without starting ssh. A failed tunnel can stay failed for
/// hours (a closed laptop lid on the other end, a VPN left off); probing it
/// with ssh would spawn a process every interval for that whole time, while
/// this costs a few packets and no process at all.
enum PeerHostReachabilityProbe {
    enum ConfigHop: Equatable {
        case direct(PeerHostProbeTarget)
        /// `ProxyJump`: the first jump host is what this Mac actually dials.
        case jump(String)
        /// `ProxyCommand` hides the hop behind an arbitrary command.
        case unprobeable
    }

    /// Reads `ssh -G` output, so aliases, `Port` and `ProxyJump` resolve the
    /// way the tunnel's own ssh resolves them.
    nonisolated static func hop(fromSSHConfig output: String) -> ConfigHop {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[parts[0].lowercased()] = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        if let command = values["proxycommand"], command != "none" { return .unprobeable }
        if let jump = values["proxyjump"], jump != "none",
           let first = jump.split(separator: ",").first {
            return .jump(String(first))
        }
        guard let host = values["hostname"], !host.isEmpty,
              let port = UInt16(values["port"] ?? "22")
        else { return .unprobeable }
        return .direct(PeerHostProbeTarget(host: host, port: port))
    }

    /// `[user@]host[:port]` from a `ProxyJump` entry, split into what `ssh -G`
    /// takes as a destination and an explicit port.
    nonisolated static func jumpDestination(_ hop: String) -> (destination: String, port: Int?) {
        guard let colon = hop.lastIndex(of: ":"), !hop.hasSuffix("]"),
              let port = Int(hop[hop.index(after: colon)...])
        else { return (hop, nil) }
        return (String(hop[..<colon]), port)
    }

    /// One level of `ProxyJump` is followed; a jump host that itself jumps
    /// or uses `ProxyCommand` is left to the event triggers.
    static func resolveTarget(sshTarget: String, port: Int?) async -> PeerHostProbeTarget? {
        switch await sshConfigHop(destination: sshTarget, port: port) {
        case let .direct(target):
            return target
        case let .jump(hop):
            let jump = jumpDestination(hop)
            if case let .direct(target) = await sshConfigHop(destination: jump.destination, port: jump.port) {
                return target
            }
            return nil
        case .unprobeable, nil:
            return nil
        }
    }

    private static func sshConfigHop(destination: String, port: Int?) async -> ConfigHop? {
        var arguments = ["-G"]
        if let port { arguments += ["-p", String(port)] }
        arguments += ["--", destination]
        guard let output = await runSSH(arguments) else { return nil }
        return hop(fromSSHConfig: output)
    }

    private static func runSSH(_ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                // Read after exit: `ssh -G` prints a few KB, well under the
                // pipe buffer, so ssh never blocks on a full pipe first.
                let data = output.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(
                    returning: finished.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
                )
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: nil)
            }
        }
    }

    static func isReachable(_ target: PeerHostProbeTarget, timeout: TimeInterval = 3) async -> Bool {
        guard let port = NWEndpoint.Port(rawValue: target.port) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: .tcp)
        let queue = DispatchQueue(label: "term-mesh.peer.reachability-probe")
        return await withCheckedContinuation { continuation in
            let settle = ProbeSettlement(connection: connection, continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: settle.finish(true)
                // `.waiting` is how Network reports a refused or unroutable
                // connect it would otherwise keep retrying on its own.
                case .waiting, .failed: settle.finish(false)
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { settle.finish(false) }
            connection.start(queue: queue)
        }
    }
}

/// Resumes the probe exactly once, whichever of the state handler and the
/// timeout gets there first, and closes the connection either way.
private final class ProbeSettlement: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private let connection: NWConnection

    init(connection: NWConnection, continuation: CheckedContinuation<Bool, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ reachable: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        connection.cancel()
        pending.resume(returning: reachable)
    }
}
