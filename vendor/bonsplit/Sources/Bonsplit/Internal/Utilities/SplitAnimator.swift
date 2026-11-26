import Foundation
import AppKit
import QuartzCore
import CoreVideo

/// Animates split view divider positions with display-synced updates and pixel-perfect positioning
@MainActor
final class SplitAnimator {

    // MARK: - Types

    private struct Animation {
        weak var splitView: NSSplitView?
        let startPosition: CGFloat
        let endPosition: CGFloat
        let startTime: CFTimeInterval
        let duration: CFTimeInterval
        var onComplete: (() -> Void)?
    }

    private struct ProgressAnimation {
        let startTime: CFTimeInterval
        let duration: CFTimeInterval
        let step: (CGFloat) -> Void
        let onComplete: () -> Void
    }

    // MARK: - Properties

    private var displayLink: CVDisplayLink?
    private var animations: [UUID: Animation] = [:]
    private var progressAnimations: [UUID: ProgressAnimation] = [:]

    /// Shared animator instance
    static let shared = SplitAnimator()

    /// Default animation duration in seconds
    nonisolated static let defaultAnimationDuration: CFTimeInterval = 0.16
    // MARK: - Initialization

    private init() {
        setupDisplayLink()
    }

    deinit {
        if let displayLink, CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStop(displayLink)
        }
    }

    // MARK: - Display Link

    private func setupDisplayLink() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context in
            let animator = Unmanaged<SplitAnimator>.fromOpaque(context!).takeUnretainedValue()
            DispatchQueue.main.async {
                Task { @MainActor in
                    animator.tick()
                }
            }
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        displayLink = link
    }

    // MARK: - Animation Control

    @discardableResult
    func animate(
        splitView: NSSplitView,
        from startPosition: CGFloat,
        to endPosition: CGFloat,
        duration: CFTimeInterval = SplitAnimator.defaultAnimationDuration,
        onComplete: (() -> Void)? = nil
    ) -> UUID {
        let id = UUID()

        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(round(startPosition), ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()

        animations[id] = Animation(
            splitView: splitView,
            startPosition: startPosition,
            endPosition: endPosition,
            startTime: CACurrentMediaTime(),
            duration: duration,
            onComplete: onComplete
        )

        if let displayLink, !CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStart(displayLink)
        }

        return id
    }

    /// Calls `step` once per display frame with the eased progress (0...1),
    /// then `onComplete` after the final step. The first step runs at once.
    @discardableResult
    func animateProgress(
        duration: CFTimeInterval,
        step: @escaping (CGFloat) -> Void,
        onComplete: @escaping () -> Void
    ) -> UUID {
        let id = UUID()
        step(0)
        progressAnimations[id] = ProgressAnimation(
            startTime: CACurrentMediaTime(),
            duration: duration,
            step: step,
            onComplete: onComplete
        )
        if let displayLink, !CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStart(displayLink)
        }
        return id
    }

    func cancel(_ id: UUID) {
        animations.removeValue(forKey: id)
        progressAnimations.removeValue(forKey: id)
        stopIfNeeded()
    }

    private static func eased(_ progress: Double) -> Double {
        progress >= 1.0 ? 1.0 : 1.0 - pow(2.0, -10.0 * progress)
    }

    // MARK: - Frame Update

    private func tick() {
        let currentTime = CACurrentMediaTime()
        var completedIds: [UUID] = []

        for (id, animation) in animations {
            guard let splitView = animation.splitView else {
                completedIds.append(id)
                continue
            }

            let elapsed = currentTime - animation.startTime
            let progress = min(elapsed / animation.duration, 1.0)
            let eased = progress == 1.0 ? 1.0 : 1.0 - pow(2.0, -10.0 * progress)

            let position = animation.startPosition + (animation.endPosition - animation.startPosition) * eased

            // Round to whole pixels to prevent artifacts
            splitView.setPosition(round(position), ofDividerAt: 0)

            if progress >= 1.0 {
                completedIds.append(id)
                animation.onComplete?()
            }
        }

        for id in completedIds {
            animations.removeValue(forKey: id)
        }

        var finished: [() -> Void] = []
        for (id, animation) in progressAnimations {
            let progress = min((currentTime - animation.startTime) / animation.duration, 1.0)
            animation.step(CGFloat(Self.eased(progress)))
            if progress >= 1.0 {
                progressAnimations.removeValue(forKey: id)
                finished.append(animation.onComplete)
            }
        }
        // Completions run after removal so one can start the next animation.
        finished.forEach { $0() }

        stopIfNeeded()
    }

    private func stopIfNeeded() {
        if animations.isEmpty, progressAnimations.isEmpty, let displayLink, CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStop(displayLink)
        }
    }
}
