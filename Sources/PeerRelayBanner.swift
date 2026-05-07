// Phase E-2: in-window status / error banner for the peer relay window.
//
// Replaces ad-hoc title-suffix and silent-NSLog feedback with a small
// NSStackView pinned to the top of the relay window. The controller
// shows it on tunnel state changes (disconnect / reconnecting) and on
// reconnect failures, with an optional action button (e.g. "Retry").

import AppKit

enum PeerRelayBannerKind {
    case info
    case warning
    case error
    case success

    var background: NSColor {
        switch self {
        case .info:    return NSColor.systemBlue.withAlphaComponent(0.18)
        case .warning: return NSColor.systemYellow.withAlphaComponent(0.22)
        case .error:   return NSColor.systemRed.withAlphaComponent(0.22)
        case .success: return NSColor.systemGreen.withAlphaComponent(0.22)
        }
    }

    var symbol: String {
        switch self {
        case .info:    return "ⓘ"
        case .warning: return "⚠"
        case .error:   return "✕"
        case .success: return "✓"
        }
    }

    var symbolColor: NSColor {
        switch self {
        case .info:    return .systemBlue
        case .warning: return .systemYellow
        case .error:   return .systemRed
        case .success: return .systemGreen
        }
    }
}

final class PeerRelayBanner: NSView {
    private let symbolLabel = NSTextField(labelWithString: "")
    private let textLabel   = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let dismissButton = NSButton(title: "✕", target: nil, action: nil)
    private var actionHandler: (() -> Void)?
    /// Drives the banner's height directly: 0 when hidden so the
    /// neighbouring split-tree container takes the full window height,
    /// 28 when shown.
    private var heightConstraint: NSLayoutConstraint!
    /// When true, `actionTapped` hides the banner before invoking the
    /// callback. Defaults to true so the common "transient action,
    /// then dismiss" case is implicit; pass `dismissOnAction: false`
    /// from `show(...)` for actions that intend to re-show a different
    /// banner kind themselves (e.g. Retry → "Reconnecting…").
    private var dismissOnAction: Bool = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 0
        translatesAutoresizingMaskIntoConstraints = false

        symbolLabel.font = .systemFont(ofSize: 13, weight: .bold)
        symbolLabel.translatesAutoresizingMaskIntoConstraints = false

        textLabel.font = .systemFont(ofSize: 12)
        textLabel.maximumNumberOfLines = 2
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.font = .systemFont(ofSize: 11)
        actionButton.target = self
        actionButton.action = #selector(actionTapped)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.isHidden = true

        dismissButton.bezelStyle = .accessoryBarAction
        dismissButton.isBordered = false
        dismissButton.font = .systemFont(ofSize: 11, weight: .bold)
        dismissButton.target = self
        dismissButton.action = #selector(dismissTapped)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(symbolLabel)
        addSubview(textLabel)
        addSubview(actionButton)
        addSubview(dismissButton)

        NSLayoutConstraint.activate([
            symbolLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            symbolLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            textLabel.leadingAnchor.constraint(equalTo: symbolLabel.trailingAnchor, constant: 8),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            textLabel.trailingAnchor.constraint(lessThanOrEqualTo: actionButton.leadingAnchor, constant: -8),

            actionButton.trailingAnchor.constraint(equalTo: dismissButton.leadingAnchor, constant: -6),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dismissButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        heightConstraint.isActive = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Show or update the banner. Pass `actionTitle: nil` for no
    /// inline button. `dismissable` keeps the trailing × button.
    /// `dismissOnAction` controls whether tapping the inline action
    /// button auto-hides the banner before running the callback;
    /// keep the default (`true`) unless the action explicitly intends
    /// to swap the banner to a different state itself.
    func show(
        kind: PeerRelayBannerKind,
        message: String,
        actionTitle: String? = nil,
        dismissable: Bool = true,
        dismissOnAction: Bool = true,
        action: (() -> Void)? = nil
    ) {
        layer?.backgroundColor = kind.background.cgColor
        symbolLabel.stringValue = kind.symbol
        symbolLabel.textColor = kind.symbolColor
        textLabel.stringValue = message
        textLabel.toolTip = message

        if let actionTitle, !actionTitle.isEmpty {
            actionButton.title = actionTitle
            actionButton.isHidden = false
            actionHandler = action
        } else {
            actionButton.isHidden = true
            actionHandler = nil
        }
        self.dismissOnAction = dismissOnAction
        dismissButton.isHidden = !dismissable
        isHidden = false
        heightConstraint.constant = 28
    }

    func hide() {
        isHidden = true
        heightConstraint.constant = 0
        actionHandler = nil
    }

    @objc private func actionTapped() {
        let h = actionHandler
        // Hide before invoking the callback so a callback that
        // immediately calls `show(...)` can land on a clean state
        // (and queued repeat-clicks while the action is in flight
        // can't stack the same banner copy multiple times).
        if dismissOnAction {
            hide()
        }
        h?()
    }

    @objc private func dismissTapped() {
        hide()
    }
}
