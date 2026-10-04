import Foundation

/// The synchronous half of the registry shell for one host key.
///
/// It owns the event queue, commits each reduced state before running that
/// transition's effects, samples the liveness verdict when an acquire is
/// dequeued, and routes `retain` / `release` by whether the lease is pooled at
/// dequeue. Effects may call back into the core; those calls are queued behind
/// the current effect list instead of being reduced in the middle of it.
public final class PeerHostShellCore<Spec: Hashable & Sendable, Token: Hashable & Sendable> {
    public typealias Machine = PeerHostMachine<Spec, Token>

    public struct EffectContext {
        public let cause: Machine.Event
        public let before: Machine.State
    }

    private enum Input {
        case acquire(Machine.AcquireRequest)
        case retain(PeerHostLeaseID)
        case release(PeerHostLeaseID)
        case event(Machine.Event)
    }

    public private(set) var state: Machine.State
    private let sampleVerdict: (PeerHostLeaseID) -> Machine.Verdict
    private let perform: (Machine.Effect, EffectContext) -> Void
    private let shellOnlyReference: (PeerHostLeaseID, Int) -> Void
    private var queue: [Input] = []
    private var draining = false

    public init(
        state: Machine.State = Machine.State(),
        sampleVerdict: @escaping (PeerHostLeaseID) -> Machine.Verdict,
        perform: @escaping (Machine.Effect, EffectContext) -> Void,
        shellOnlyReference: @escaping (PeerHostLeaseID, Int) -> Void
    ) {
        self.state = state
        self.sampleVerdict = sampleVerdict
        self.perform = perform
        self.shellOnlyReference = shellOnlyReference
    }

    public func acquire(_ request: Machine.AcquireRequest) {
        enqueue(.acquire(request))
    }

    public func retain(_ lease: PeerHostLeaseID) {
        enqueue(.retain(lease))
    }

    public func release(_ lease: PeerHostLeaseID) {
        enqueue(.release(lease))
    }

    public func deliver(_ event: Machine.Event) {
        enqueue(.event(event))
    }

    private func enqueue(_ input: Input) {
        queue.append(input)
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !queue.isEmpty {
            step(queue.removeFirst())
        }
    }

    private func step(_ input: Input) {
        let event: Machine.Event
        switch input {
        case let .acquire(request):
            event = .acquire(request, state.pooledLease.map(sampleVerdict) ?? .usable)
        case let .retain(lease):
            guard state.pooledLease == lease else { return shellOnlyReference(lease, 1) }
            event = .retain(lease)
        case let .release(lease):
            guard state.pooledLease == lease else { return shellOnlyReference(lease, -1) }
            event = .release(lease)
        case let .event(machineEvent):
            event = machineEvent
        }
        let before = state
        let (after, effects) = Machine.reduce(before, event)
        state = after
        let context = EffectContext(cause: event, before: before)
        for effect in effects {
            if case let .queueUnusedCheck(lease) = effect {
                queue.append(.event(.unusedCheck(lease)))
            } else {
                perform(effect, context)
            }
        }
    }
}
