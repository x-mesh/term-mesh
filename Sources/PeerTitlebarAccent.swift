//  Peer titlebar accent: the gradient strip that marks a window as
//  "input goes to a remote host". Extracted from
//  PeerRelayWorkspaceWindowController (which used a fixed 3-stop
//  gradient on its own window) and parameterized by host color so the
//  MAIN window can show it too — Phase 1 remote pane primitive rule:
//  the titlebar tints when the FOCUSED pane is remote, keyed by that
//  pane's host, and reverts when a local pane takes focus.
//
//  Safety rationale: the strongest signal a user needs is "which host
//  receives my keystrokes right now" — that is the focused pane's host,
//  not the workspace's. Per-pane always-on signals (tab chip, pane
//  strip) complement this for non-focused panes.

import AppKit

// MARK: - Gradient view

final class PeerTitlebarGradientView: NSView {
    /// The classic relay-window gradient (pink → purple → blue); also
    /// the default when no per-host color applies.
    static let defaultColors: [NSColor] = [
        NSColor(srgbRed: 0.95, green: 0.45, blue: 0.55, alpha: 0.92),
        NSColor(srgbRed: 0.55, green: 0.45, blue: 0.95, alpha: 0.92),
        NSColor(srgbRed: 0.45, green: 0.55, blue: 0.95, alpha: 0.92),
    ]

    var colors: [NSColor] {
        didSet { needsDisplay = true }
    }

    init(frame: NSRect, colors: [NSColor] = PeerTitlebarGradientView.defaultColors) {
        self.colors = colors
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: colors)?.draw(in: bounds, angle: 0)
        NSColor.black.withAlphaComponent(0.14).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: 1)).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Per-host colors

enum PeerHostAccent {
    /// Curated gradient triples, all loud enough to read as "remote"
    /// at titlebar size. Index 0 is the classic purple family.
    private static let palette: [[NSColor]] = [
        PeerTitlebarGradientView.defaultColors,
        [   // teal family
            NSColor(srgbRed: 0.30, green: 0.80, blue: 0.70, alpha: 0.92),
            NSColor(srgbRed: 0.25, green: 0.60, blue: 0.85, alpha: 0.92),
            NSColor(srgbRed: 0.35, green: 0.45, blue: 0.90, alpha: 0.92),
        ],
        [   // amber family
            NSColor(srgbRed: 0.95, green: 0.70, blue: 0.30, alpha: 0.92),
            NSColor(srgbRed: 0.95, green: 0.50, blue: 0.35, alpha: 0.92),
            NSColor(srgbRed: 0.90, green: 0.35, blue: 0.50, alpha: 0.92),
        ],
        [   // green family
            NSColor(srgbRed: 0.45, green: 0.85, blue: 0.45, alpha: 0.92),
            NSColor(srgbRed: 0.30, green: 0.70, blue: 0.60, alpha: 0.92),
            NSColor(srgbRed: 0.25, green: 0.55, blue: 0.75, alpha: 0.92),
        ],
        [   // magenta family
            NSColor(srgbRed: 0.90, green: 0.40, blue: 0.85, alpha: 0.92),
            NSColor(srgbRed: 0.70, green: 0.35, blue: 0.95, alpha: 0.92),
            NSColor(srgbRed: 0.50, green: 0.40, blue: 0.95, alpha: 0.92),
        ],
    ]

    /// Deterministic host → gradient assignment (djb2 over the stable
    /// host key), so a host keeps its color across panes, reconnects,
    /// and app restarts without any persistence.
    ///
    /// palette[0] (the purple family) is RESERVED and never assigned to
    /// a host: it is both the relay window's identity gradient and the
    /// sidebar's local selected-row gradient, so a host hashing onto it
    /// would be indistinguishable from local UI. One palette feeds every
    /// per-host signal (sidebar row, pane host strip) so they always
    /// agree in hue.
    static func colors(for key: PeerPaneHostKey) -> [NSColor] {
        var hash: UInt64 = 5381
        for byte in key.description.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count - 1)) + 1]
    }

    static func primaryColor(for key: PeerPaneHostKey) -> NSColor {
        colors(for: key)[1]
    }
}

// MARK: - NSWindow install/remove

@MainActor
extension NSWindow {
    private static let accentIdentifier =
        NSUserInterfaceItemIdentifier("term-mesh.peer.titlebarGradientAccent")

    /// Install (or recolor) the peer gradient accent on this window's
    /// titlebar. Default colors preserve the relay windows' historical
    /// look; main-window callers pass a per-host palette.
    func installPeerTitlebarGradientAccent(
        colors: [NSColor] = PeerTitlebarGradientView.defaultColors
    ) {
        titlebarAppearsTransparent = true

        guard let titlebarView = standardWindowButton(.closeButton)?.superview else { return }

        if let existing = titlebarView.subviews.first(
            where: { $0.identifier == Self.accentIdentifier }
        ) as? PeerTitlebarGradientView {
            existing.frame = titlebarView.bounds
            existing.colors = colors
            return
        }

        let accent = PeerTitlebarGradientView(frame: titlebarView.bounds, colors: colors)
        accent.identifier = Self.accentIdentifier
        titlebarView.addSubview(accent, positioned: .below, relativeTo: nil)
    }

    func removePeerTitlebarGradientAccent() {
        guard let titlebarView = standardWindowButton(.closeButton)?.superview else { return }
        titlebarView.subviews
            .filter { $0.identifier == Self.accentIdentifier }
            .forEach { $0.removeFromSuperview() }
    }
}

// MARK: - Main-window refresh

/// Called from the focus funnels (bonsplit didFocusPane / didSelectTab,
/// workspace switch, remote pane open).
///
/// Decision (2026-07-15): the MAIN window titlebar stays at its default
/// look — no per-host gradient. The "keys go to a remote host" signal
/// lives in the per-pane 2pt host strip (always on) and the sidebar's
/// peer-accent row (see TabItemView.peerAccentNSColors). refresh() now
/// only REMOVES accents so anything installed by an older build or a
/// stale focus race is cleaned up on the next focus change. Standalone
/// relay WINDOWS keep their own gradient — there the whole window is
/// remote, installed directly by PeerRelayWorkspaceWindowController.
@MainActor
enum PeerTitlebarAccentController {
    static func refresh() {
        // NSApp.delegate is the SwiftUI adaptor shim, not our type —
        // AppDelegate.shared is the canonical accessor.
        guard let appDelegate = AppDelegate.shared else { return }
        for context in appDelegate.mainWindowContexts.values {
            context.window?.removePeerTitlebarGradientAccent()
        }
    }
}
