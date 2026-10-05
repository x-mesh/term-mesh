import Combine
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

enum PeerKeepAwakePolicy {
    enum Decision: Equatable {
        case hold
        case releaseAfterGrace
        case releaseNow
    }

    /// Rebuilding a host's tunnel takes it out of `.connected` for a few
    /// seconds, and a Mac already idle past its sleep timer would sleep in that
    /// gap — the very drop this exists to prevent.
    static let releaseGraceSeconds: TimeInterval = 60

    static func decision(mode: PeerKeepAwakeMode, onACPower: Bool, connections: Int) -> Decision {
        let allowed: Bool
        switch mode {
        case .never: allowed = false
        case .onPowerAdapter: allowed = onACPower
        case .always: allowed = true
        }
        guard allowed else { return .releaseNow }
        return connections > 0 ? .hold : .releaseAfterGrace
    }
}

/// Holds an idle-sleep assertion while remote sessions are connected, and for
/// `PeerKeepAwakePolicy.releaseGraceSeconds` after the last one ends.
///
/// A sleeping Mac stops answering its SSH tunnels; each dark wake then finds
/// them reset, and every viewer and mirror reconnects. The assertion is the
/// one `caffeinate -i` takes: the display still sleeps, and closing the lid or
/// choosing Sleep still sleeps the Mac.
@MainActor
final class PeerKeepAwakeController {
    static let shared = PeerKeepAwakeController()

    private var assertionID: IOPMAssertionID?
    private var latencyActivity: NSObjectProtocol?
    private var pendingRelease: DispatchWorkItem?
    private var connectedHosts = 0
    private var attachedPeers = 0
    private var onACPower = true
    private var cancellables: Set<AnyCancellable> = []
    private var modeObserver: DefaultsKeyObserver?
    private var powerSourceRunLoopSource: CFRunLoopSource?

    var isPreventingSleep: Bool { assertionID != nil }

    func start() {
        guard cancellables.isEmpty else { return }
        onACPower = Self.readOnACPower()
        RemoteHostStore.shared.$hosts
            .map { hosts in hosts.values.filter(\.isConnected).count }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                MainActor.assumeIsolated {
                    self?.connectedHosts = count
                    self?.evaluate()
                }
            }
            .store(in: &cancellables)
        modeObserver = DefaultsKeyObserver(key: PeerFederationSettings.keepAwakeKey) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.evaluate() }
            }
        }
        installPowerSourceObserver()
        evaluate()
    }

    func attachedPeerCountDidChange(_ count: Int) {
        attachedPeers = count
        updateLatencyActivity()
        evaluate()
    }

    /// An unattended Mac naps background apps: timers coalesce and the process
    /// drops to background priority. The host's output drain waits on a short
    /// timer, so a napping host sent each keystroke's echo 120–160ms late at
    /// the median. While another machine is attached, declare latency-critical
    /// work so the host answers promptly. Idle sleep stays with the keep-awake
    /// mode; this activity allows it.
    private func updateLatencyActivity() {
        if attachedPeers > 0, latencyActivity == nil {
            latencyActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Remote viewers are attached to this Mac's terminals"
            )
            RemoteWorkLog.infoOffMain("Keeping term-mesh responsive while \(attachedPeers) peer connection(s) are accepted")
        } else if attachedPeers == 0, let activity = latencyActivity {
            ProcessInfo.processInfo.endActivity(activity)
            latencyActivity = nil
            RemoteWorkLog.infoOffMain("Letting term-mesh nap again: no peer connection is accepted")
        }
    }

    private var decision: PeerKeepAwakePolicy.Decision {
        PeerKeepAwakePolicy.decision(
            mode: PeerFederationSettings.keepAwakeMode,
            onACPower: onACPower,
            connections: connectedHosts + attachedPeers
        )
    }

    private func evaluate() {
        switch decision {
        case .hold:
            cancelPendingRelease()
            acquire()
        case .releaseNow:
            cancelPendingRelease()
            release()
        case .releaseAfterGrace:
            guard assertionID != nil, pendingRelease == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.graceExpired() }
            }
            pendingRelease = work
            DispatchQueue.main.asyncAfter(deadline: .now() + PeerKeepAwakePolicy.releaseGraceSeconds, execute: work)
        }
    }

    private func graceExpired() {
        pendingRelease = nil
        if decision != .hold {
            release()
        }
    }

    private func cancelPendingRelease() {
        pendingRelease?.cancel()
        pendingRelease = nil
    }

    private func acquire() {
        guard assertionID == nil else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "term-mesh: remote sessions are connected" as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            RemoteWorkLog.infoOffMain("Could not keep this Mac awake for remote sessions: IOKit error \(result)")
            return
        }
        assertionID = id
        RemoteWorkLog.infoOffMain(
            "Keeping this Mac awake: \(connectedHosts) remote host(s) connected, \(attachedPeers) peer connection(s) accepted"
        )
    }

    private func release() {
        guard let id = assertionID else { return }
        IOPMAssertionRelease(id)
        assertionID = nil
        RemoteWorkLog.infoOffMain("Letting this Mac sleep again: no remote session needs it awake")
    }

    private func installPowerSourceObserver() {
        guard powerSourceRunLoopSource == nil,
              let source = IOPSNotificationCreateRunLoopSource({ _ in
                  MainActor.assumeIsolated {
                      PeerKeepAwakeController.shared.powerSourceDidChange()
                  }
              }, nil)?.takeRetainedValue()
        else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSourceRunLoopSource = source
    }

    private func powerSourceDidChange() {
        onACPower = Self.readOnACPower()
        evaluate()
    }

    /// A Mac with no battery reports AC power, so `onPowerAdapter` keeps a
    /// desktop awake exactly as `always` does.
    private static func readOnACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return true }
        return (type as String) == kIOPMACPowerKey
    }
}

/// `UserDefaults.didChangeNotification` only covers writes made in this
/// process; KVO on the key also sees `defaults write` and other processes.
private final class DefaultsKeyObserver: NSObject {
    private let key: String
    private let onChange: () -> Void

    init(key: String, onChange: @escaping () -> Void) {
        self.key = key
        self.onChange = onChange
        super.init()
        UserDefaults.standard.addObserver(self, forKeyPath: key, options: [], context: nil)
    }

    deinit {
        UserDefaults.standard.removeObserver(self, forKeyPath: key)
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        onChange()
    }
}
