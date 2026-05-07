// Phase E review (M12): factored presentation logic out of
// PeerRelayWorkspaceWindowController so the controller only forwards
// connection-state events and the banner's kind / copy / auto-dismiss
// timing live in one place. Also fixes the Low-priority leak where
// each `.up → .down → .up` flap spawned an auto-dismiss Task that
// could later hide a banner the new state had legitimately re-shown.

import AppKit

@MainActor
final class PeerRelayBannerPresenter {
    private weak var banner: PeerRelayBanner?
    /// Held so a follow-up state transition can cancel a still-pending
    /// 3s auto-dismiss timer before it hides a banner the new state
    /// has just re-shown for a different reason.
    private var dismissTask: Task<Void, Never>?

    init(banner: PeerRelayBanner) {
        self.banner = banner
    }

    // MARK: - Tunnel transitions

    func showDisconnected(reason: String) {
        cancelDismiss()
        banner?.show(
            kind: .error,
            message: "Disconnected: \(reason)",
            actionTitle: nil,
            dismissable: false
        )
    }

    func showReconnecting(attempt: Int) {
        cancelDismiss()
        banner?.show(
            kind: .warning,
            message: "Reconnecting to host (try \(attempt))…",
            actionTitle: nil,
            dismissable: false
        )
    }

    func showReattaching() {
        cancelDismiss()
        banner?.show(
            kind: .info,
            message: "Re-attaching panes…",
            actionTitle: nil,
            dismissable: false
        )
    }

    func showReconnected(autoDismissAfter seconds: Double = 3) {
        cancelDismiss()
        banner?.show(
            kind: .success,
            message: "Reconnected",
            actionTitle: nil,
            dismissable: true
        )
        let ns = UInt64(seconds * 1_000_000_000)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            if Task.isCancelled { return }
            await MainActor.run { self?.banner?.hide() }
        }
    }

    // MARK: - Failures with explicit user actions

    func showAttachFailed(detail: String, onClose: @escaping () -> Void) {
        cancelDismiss()
        banner?.show(
            kind: .error,
            message: "Failed to attach: \(detail)",
            actionTitle: "Close",
            dismissable: false,
            action: onClose
        )
    }

    func showReconnectFailed(detail: String, onRetry: @escaping () -> Void) {
        cancelDismiss()
        banner?.show(
            kind: .error,
            message: "Reconnect failed: \(detail)",
            actionTitle: "Retry",
            dismissable: false,
            // Don't auto-hide on click — handleTunnelStateChange will
            // immediately replace the banner with a Reconnecting / Up
            // variant via the callback.
            dismissOnAction: false,
            action: onRetry
        )
    }

    func showFailedTerminal(reason: String, onRetry: @escaping () -> Void) {
        cancelDismiss()
        banner?.show(
            kind: .error,
            message: "Reconnect failed: \(reason)",
            actionTitle: "Retry",
            dismissable: false,
            dismissOnAction: false,
            action: onRetry
        )
    }

    // MARK: - Internals

    private func cancelDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
    }
}
