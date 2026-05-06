// Phase D-3a: Bonjour LAN discovery for peer-federation hosts.
//
// The peer server itself stays on a Unix socket; Bonjour just
// advertises "this machine is offering its term-mesh workspace via
// SSH" so a client on the same LAN can pick the host out of a list
// instead of typing an SSH alias by hand. The TXT record carries
// the socket path; the client side combines that with the
// resolved Bonjour hostname to drive the existing SSH-tunnel flow.
//
// We deliberately do NOT add a TCP listener — securing a raw TCP
// peer transport is out of scope here. SSH stays the actual transport.

import Foundation

private let kPeerBonjourServiceType = "_termmesh-peer._tcp."

// MARK: - Publisher

final class PeerBonjourPublisher: NSObject, NetServiceDelegate {
    private let service: NetService

    init(serviceName: String, socketPath: String) {
        self.service = NetService(
            domain: "local.",
            type: kPeerBonjourServiceType,
            name: serviceName,
            port: 22  // SSH endpoint hint; publishing does not bind.
        )
        super.init()
        let txt = NetService.data(fromTXTRecord: [
            "sock": Data(socketPath.utf8),
            "v":    Data("1".utf8),
        ])
        service.setTXTRecord(txt)
        service.delegate = self
    }

    func start() {
        service.publish()
    }

    func stop() {
        service.stop()
    }

    func netServiceDidPublish(_ sender: NetService) {
        NSLog("[peer-bonjour] published as %@.%@", sender.name, sender.type)
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        NSLog("[peer-bonjour] publish failed: %@", String(describing: errorDict))
    }
}

// MARK: - Browser

struct DiscoveredPeer: Equatable, Sendable {
    let serviceName: String   // user-facing "Mac mini"
    let hostname: String      // e.g. "mac-mini.local"
    let socketPath: String?   // remote peer socket from TXT record
}

@MainActor
final class PeerBonjourBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var pending: [NetService] = []
    private var resolved: [DiscoveredPeer] = []
    private var onChange: (([DiscoveredPeer]) -> Void)?

    func start(onChange: @escaping ([DiscoveredPeer]) -> Void) {
        self.onChange = onChange
        browser.delegate = self
        browser.searchForServices(ofType: kPeerBonjourServiceType, inDomain: "local.")
    }

    func stop() {
        browser.stop()
        for s in pending { s.stop() }
        pending.removeAll()
        resolved.removeAll()
        onChange = nil
    }

    // MARK: NetServiceBrowserDelegate

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            service.delegate = self
            self.pending.append(service)
            service.resolve(withTimeout: 3)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resolved.removeAll { $0.serviceName == service.name }
            self.onChange?(self.resolved)
        }
    }

    // MARK: NetServiceDelegate

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let host = sender.hostName else { return }
            let txt = sender.txtRecordData().map { NetService.dictionary(fromTXTRecord: $0) } ?? [:]
            let sock = txt["sock"].flatMap { String(data: $0, encoding: .utf8) }
            let peer = DiscoveredPeer(
                serviceName: sender.name,
                hostname: host,
                socketPath: sock
            )
            // Replace any prior entry with the same name so re-publishes
            // (e.g. host restart) update in place rather than stack.
            self.resolved.removeAll { $0.serviceName == peer.serviceName }
            self.resolved.append(peer)
            self.onChange?(self.resolved)
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending.removeAll { $0 === sender }
        }
    }
}
