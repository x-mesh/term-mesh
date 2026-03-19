import Foundation
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import Darwin
import Sentry
import Bonsplit
import IOSurface
import os

struct GhosttyScrollbar {
    let total: UInt64
    let offset: UInt64
    let len: UInt64

    init(c: ghostty_action_scrollbar_s) {
        total = c.total
        offset = c.offset
        len = c.len
    }
}

enum GhosttyNotificationKey {
    static let scrollbar = "ghostty.scrollbar"
    static let cellSize = "ghostty.cellSize"
    static let tabId = "ghostty.tabId"
    static let surfaceId = "ghostty.surfaceId"
    static let title = "ghostty.title"
    static let backgroundColor = "ghostty.backgroundColor"
    static let backgroundOpacity = "ghostty.backgroundOpacity"
    static let backgroundEventId = "ghostty.backgroundEventId"
    static let backgroundSource = "ghostty.backgroundSource"
}

extension Notification.Name {
    static let ghosttyDidUpdateScrollbar = Notification.Name("ghosttyDidUpdateScrollbar")
    static let ghosttyDidUpdateCellSize = Notification.Name("ghosttyDidUpdateCellSize")
    static let ghosttySearchFocus = Notification.Name("ghosttySearchFocus")
    static let ghosttyConfigDidReload = Notification.Name("ghosttyConfigDidReload")
    static let ghosttyDefaultBackgroundDidChange = Notification.Name("ghosttyDefaultBackgroundDidChange")
    static let termMeshToggleIMEInputBar = Notification.Name("termMeshToggleIMEInputBar")
    static let termMeshBroadcastIMEText = Notification.Name("termMeshBroadcastIMEText")
}

// MARK: - IME Bar Drag Handle

/// Thin drag handle between terminal and IME bar for height resizing.
/// Positioned at the top edge of the IME bar; dragging upward increases bar height.
private final class IMEBarDragHandle: NSView {
    var onHeightChange: ((CGFloat) -> Void)?
    private var dragStartY: CGFloat = 0
    private var dragStartHeight: CGFloat = 0
    var currentHeight: CGFloat = IMEInputBarSettings.height

    static let handleHeight: CGFloat = 8

    override var acceptsFirstResponder: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartY = event.locationInWindow.y
        dragStartHeight = currentHeight
    }

    override func mouseDragged(with event: NSEvent) {
        let delta = event.locationInWindow.y - dragStartY
        let maxHeight = max(120, (superview?.bounds.height ?? 400) * 0.6)
        let newHeight = min(max(60, dragStartHeight + delta), maxHeight)
        currentHeight = newHeight
        onHeightChange?(newHeight)
    }

    override func mouseUp(with event: NSEvent) {
        // Persist the custom height to UserDefaults
        UserDefaults.standard.set(Double(currentHeight), forKey: "imeBarHeight")
    }

    override func draw(_ dirtyRect: NSRect) {
        // Draw grip indicator (small centered pill)
        NSColor.white.withAlphaComponent(0.3).setFill()
        let gripWidth: CGFloat = 36
        let gripHeight: CGFloat = 3
        let gripRect = NSRect(
            x: bounds.midX - gripWidth / 2,
            y: bounds.midY - gripHeight / 2,
            width: gripWidth,
            height: gripHeight
        )
        NSBezierPath(roundedRect: gripRect, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

// MARK: - Scroll View Wrapper (Ghostty-style scrollbar)

private final class GhosttyScrollView: NSScrollView {
    weak var surfaceView: GhosttyNSView?

    override func scrollWheel(with event: NSEvent) {
        guard let surfaceView else {
            super.scrollWheel(with: event)
            return
        }

        if let surface = surfaceView.terminalSurface?.surface,
           ghostty_surface_mouse_captured(surface) {
            GhosttyNSView.focusLog("GhosttyScrollView.scrollWheel: mouseCaptured -> surface scroll")
            if window?.firstResponder !== surfaceView {
                window?.makeFirstResponder(surfaceView)
            }
            surfaceView.scrollWheel(with: event)
        } else {
            GhosttyNSView.focusLog("GhosttyScrollView.scrollWheel: super scroll")
            super.scrollWheel(with: event)
        }
    }
}

private final class GhosttyFlashOverlayView: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class GhosttySurfaceScrollView: NSView {
    private let backgroundView: NSView
    private let scrollView: GhosttyScrollView
    private let documentView: NSView
    private let surfaceView: GhosttyNSView
    private let inactiveOverlayView: GhosttyFlashOverlayView
    private let dropZoneOverlayView: GhosttyFlashOverlayView
    private let notificationRingOverlayView: GhosttyFlashOverlayView
    private let notificationRingLayer: CAShapeLayer
    private let flashOverlayView: GhosttyFlashOverlayView
    private let flashLayer: CAShapeLayer
    private var searchOverlayHostingView: NSHostingView<SurfaceSearchOverlay>?
    private var imeInputBarHostingView: NSHostingView<IMEInputBar>?
    private var imeBarDragHandle: IMEBarDragHandle?
    private var imeBarCurrentHeight: CGFloat = IMEInputBarSettings.height
    private var observers: [NSObjectProtocol] = []
	    private var windowObservers: [NSObjectProtocol] = []
	    private var isLiveScrolling = false
    private var lastSentRow: Int?
    private var isActive = true
    private var activeDropZone: DropZone?
    private var pendingDropZone: DropZone?
    private var dropZoneOverlayAnimationGeneration: UInt64 = 0
    // Intentionally no focus retry loops: rely on AppKit first-responder and bonsplit selection.
#if DEBUG
    private var lastDropZoneOverlayLogSignature: String?
	    private static var flashCounts: [UUID: Int] = [:]
	    private static var drawCounts: [UUID: Int] = [:]
	    private static var lastDrawTimes: [UUID: CFTimeInterval] = [:]
	    private static var presentCounts: [UUID: Int] = [:]
    private static var dropOverlayShowCounts: [UUID: Int] = [:]
    private static var lastPresentTimes: [UUID: CFTimeInterval] = [:]
    private static var lastContentsKeys: [UUID: String] = [:]

    static func flashCount(for surfaceId: UUID) -> Int {
        flashCounts[surfaceId, default: 0]
    }

    static func resetFlashCounts() {
        flashCounts.removeAll()
    }

    private static func recordFlash(for surfaceId: UUID) {
        flashCounts[surfaceId, default: 0] += 1
    }

    static func drawStats(for surfaceId: UUID) -> (count: Int, last: CFTimeInterval) {
        (drawCounts[surfaceId, default: 0], lastDrawTimes[surfaceId, default: 0])
    }

    static func resetDrawStats() {
        drawCounts.removeAll()
        lastDrawTimes.removeAll()
    }

    static func recordSurfaceDraw(_ surfaceId: UUID) {
        drawCounts[surfaceId, default: 0] += 1
        lastDrawTimes[surfaceId] = CACurrentMediaTime()
    }

    private static func contentsKey(for layer: CALayer?) -> String {
        guard let modelLayer = layer else { return "nil" }
        // Prefer the presentation layer to better reflect what the user sees on screen.
        let layer = modelLayer.presentation() ?? modelLayer
        guard let contents = layer.contents else { return "nil" }
        // Prefer pointer identity for object/CFType contents.
        if let obj = contents as AnyObject? {
            let ptr = Unmanaged.passUnretained(obj).toOpaque()
            var key = "0x" + String(UInt(bitPattern: ptr), radix: 16)

            // For IOSurface-backed terminal layers, the IOSurface object can remain stable while
            // its contents change. Include the IOSurface seed so "new frame rendered" is visible
            // to debug/test tooling even when the pointer identity doesn't change.
            let cf = contents as CFTypeRef
            if CFGetTypeID(cf) == IOSurfaceGetTypeID() {
                let surfaceRef = (contents as! IOSurfaceRef)
                let seed = IOSurfaceGetSeed(surfaceRef)
                key += ":seed=\(seed)"
            }

            return key
        }
        return String(describing: contents)
    }

    private static func updatePresentStats(surfaceId: UUID, layer: CALayer?) -> (count: Int, last: CFTimeInterval, key: String) {
        let key = contentsKey(for: layer)
        if lastContentsKeys[surfaceId] != key {
            presentCounts[surfaceId, default: 0] += 1
            lastPresentTimes[surfaceId] = CACurrentMediaTime()
            lastContentsKeys[surfaceId] = key
        }
        return (presentCounts[surfaceId, default: 0], lastPresentTimes[surfaceId, default: 0], key)
    }

    private func recordDropOverlayShowAnimation() {
        guard let surfaceId = surfaceView.terminalSurface?.id else { return }
        Self.dropOverlayShowCounts[surfaceId, default: 0] += 1
    }

    func debugProbeDropOverlayAnimation(useDeferredPath: Bool) -> (before: Int, after: Int, bounds: CGSize) {
        guard let surfaceId = surfaceView.terminalSurface?.id else {
            return (0, 0, bounds.size)
        }

        let before = Self.dropOverlayShowCounts[surfaceId, default: 0]

        // Reset to a hidden baseline so each probe exercises an initial-show transition.
        dropZoneOverlayAnimationGeneration &+= 1
        activeDropZone = nil
        pendingDropZone = nil
        dropZoneOverlayView.layer?.removeAllAnimations()
        dropZoneOverlayView.isHidden = true
        dropZoneOverlayView.alphaValue = 1

        if useDeferredPath {
            pendingDropZone = .left
            synchronizeGeometryAndContent()
        } else {
            setDropZoneOverlay(zone: .left)
        }

        let after = Self.dropOverlayShowCounts[surfaceId, default: 0]
        setDropZoneOverlay(zone: nil)
        return (before, after, bounds.size)
    }

    var debugSurfaceId: UUID? {
        surfaceView.terminalSurface?.id
    }
#endif

    init(surfaceView: GhosttyNSView) {
        self.surfaceView = surfaceView
        backgroundView = NSView(frame: .zero)
        scrollView = GhosttyScrollView()
        inactiveOverlayView = GhosttyFlashOverlayView(frame: .zero)
        dropZoneOverlayView = GhosttyFlashOverlayView(frame: .zero)
        notificationRingOverlayView = GhosttyFlashOverlayView(frame: .zero)
        notificationRingLayer = CAShapeLayer()
        flashOverlayView = GhosttyFlashOverlayView(frame: .zero)
        flashLayer = CAShapeLayer()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.clipsToBounds = true
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        scrollView.surfaceView = surfaceView

        documentView = NSView(frame: .zero)
        scrollView.documentView = documentView
        documentView.addSubview(surfaceView)

        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = {
            let theme = GhosttyTheme.current
            return theme.backgroundColor.withAlphaComponent(theme.backgroundOpacity).cgColor
        }()
        addSubview(backgroundView)
        addSubview(scrollView)
        inactiveOverlayView.wantsLayer = true
        inactiveOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        inactiveOverlayView.isHidden = true
        addSubview(inactiveOverlayView)
        dropZoneOverlayView.wantsLayer = true
        dropZoneOverlayView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        dropZoneOverlayView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        dropZoneOverlayView.layer?.borderWidth = 2
        dropZoneOverlayView.layer?.cornerRadius = 8
        dropZoneOverlayView.isHidden = true
        addSubview(dropZoneOverlayView)
        notificationRingOverlayView.wantsLayer = true
        notificationRingOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        notificationRingOverlayView.layer?.masksToBounds = false
        notificationRingOverlayView.autoresizingMask = [.width, .height]
        notificationRingLayer.fillColor = NSColor.clear.cgColor
        notificationRingLayer.strokeColor = NSColor.systemBlue.cgColor
        notificationRingLayer.lineWidth = 2.5
        notificationRingLayer.lineJoin = .round
        notificationRingLayer.lineCap = .round
        notificationRingLayer.shadowColor = NSColor.systemBlue.cgColor
        notificationRingLayer.shadowOpacity = 0.35
        notificationRingLayer.shadowRadius = 3
        notificationRingLayer.shadowOffset = .zero
        notificationRingLayer.opacity = 0
        notificationRingOverlayView.layer?.addSublayer(notificationRingLayer)
        notificationRingOverlayView.isHidden = true
        addSubview(notificationRingOverlayView)
        flashOverlayView.wantsLayer = true
        flashOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        flashOverlayView.layer?.masksToBounds = false
        flashOverlayView.autoresizingMask = [.width, .height]
        flashLayer.fillColor = NSColor.clear.cgColor
        flashLayer.strokeColor = NSColor.systemBlue.cgColor
        flashLayer.lineWidth = 3
        flashLayer.lineJoin = .round
        flashLayer.lineCap = .round
        flashLayer.shadowColor = NSColor.systemBlue.cgColor
        flashLayer.shadowOpacity = 0.6
        flashLayer.shadowRadius = 6
        flashLayer.shadowOffset = .zero
        flashLayer.opacity = 0
        flashOverlayView.layer?.addSublayer(flashLayer)
        addSubview(flashOverlayView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.handleScrollChange()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = true
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = false
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.handleLiveScroll()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            queue: .main
        ) { [weak self] notification in
            self?.handleScrollbarUpdate(notification)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateCellSize,
            object: surfaceView,
            queue: .main
        ) { [weak self] _ in
            self?.synchronizeScrollView()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .termMeshToggleIMEInputBar,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let surface = notification.object as? TerminalSurface,
                  surface === self.surfaceView.terminalSurface else { return }
            self.toggleIMEInputBar()
        })
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        cancelFocusRequest()
    }

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

    // Avoid stealing focus on scroll; focus is managed explicitly by the surface view.
    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        synchronizeGeometryAndContent()
    }

    /// Reconcile AppKit geometry with ghostty surface geometry synchronously.
    /// Used after split topology mutations (close/split) to prevent a stale one-frame
    /// IOSurface size from being presented after pane expansion.
    func reconcileGeometryNow() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.reconcileGeometryNow()
            }
            return
        }

        synchronizeGeometryAndContent()
    }

    /// Request an immediate terminal redraw after geometry updates so stale IOSurface
    /// contents do not remain stretched during live resize churn.
    func refreshSurfaceNow() {
        surfaceView.terminalSurface?.forceRefresh()
    }

    private func synchronizeGeometryAndContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // If IME bar is visible, dock it at the bottom and shrink the terminal area.
        let imeBarHeight: CGFloat
        if let imeView = imeInputBarHostingView {
            imeBarHeight = imeBarCurrentHeight
            imeView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: imeBarHeight)
            // Position drag handle straddling the boundary between terminal and IME bar
            if let handle = imeBarDragHandle {
                let handleH = IMEBarDragHandle.handleHeight
                handle.frame = NSRect(x: 0, y: imeBarHeight - handleH / 2, width: bounds.width, height: handleH)
            }
        } else {
            imeBarHeight = 0
        }
        let terminalBounds = NSRect(
            x: bounds.origin.x,
            y: bounds.origin.y + imeBarHeight,
            width: bounds.width,
            height: bounds.height - imeBarHeight
        )
        backgroundView.frame = terminalBounds
        scrollView.frame = terminalBounds
        let targetSize = scrollView.bounds.size
        surfaceView.frame.size = targetSize
        documentView.frame.size.width = scrollView.bounds.width
        inactiveOverlayView.frame = terminalBounds
        if let zone = activeDropZone {
            dropZoneOverlayView.frame = dropZoneOverlayFrame(for: zone, in: bounds.size)
        }
        if let pending = pendingDropZone,
           bounds.width > 2,
           bounds.height > 2 {
            pendingDropZone = nil
#if DEBUG
            let frame = dropZoneOverlayFrame(for: pending, in: bounds.size)
            logDropZoneOverlay(event: "flushPending", zone: pending, frame: frame)
#endif
            // Reuse the normal show/update path so deferred overlays get the
            // same initial animation as direct drop-zone activation.
            setDropZoneOverlay(zone: pending)
        }
        notificationRingOverlayView.frame = bounds
        flashOverlayView.frame = bounds
        updateNotificationRingPath()
        updateFlashPath()
        synchronizeScrollView()
        synchronizeSurfaceView()
        synchronizeCoreSurface()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        guard let window else { return }
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.applyFirstResponderIfNeeded()
        })
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self, let window = self.window else { return }
            // Losing key window does not always trigger first-responder resignation, so force
            // the focused terminal view to yield responder to keep Ghostty cursor/focus state in sync.
            if let fr = window.firstResponder as? NSView,
               fr === self.surfaceView || fr.isDescendant(of: self.surfaceView) {
                window.makeFirstResponder(nil)
            }
        })
        if window.isKeyWindow { applyFirstResponderIfNeeded() }
    }

    func attachSurface(_ terminalSurface: TerminalSurface) {
        surfaceView.attachSurface(terminalSurface)
    }

    func setFocusHandler(_ handler: (() -> Void)?) {
        surfaceView.onFocus = handler
    }

    func setTriggerFlashHandler(_ handler: (() -> Void)?) {
        surfaceView.onTriggerFlash = handler
    }

    func setBackgroundColor(_ color: NSColor) {
        guard let layer = backgroundView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = color.cgColor
        CATransaction.commit()
    }

    func setInactiveOverlay(color: NSColor, opacity: CGFloat, visible: Bool) {
        let clampedOpacity = max(0, min(1, opacity))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inactiveOverlayView.layer?.backgroundColor = color.withAlphaComponent(clampedOpacity).cgColor
        inactiveOverlayView.isHidden = !(visible && clampedOpacity > 0.0001)
        CATransaction.commit()
    }

    func setNotificationRing(visible: Bool) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setNotificationRing(visible: visible)
            }
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        notificationRingOverlayView.isHidden = !visible
        notificationRingLayer.opacity = visible ? 1 : 0
        CATransaction.commit()
    }

    func setSearchOverlay(searchState: TerminalSurface.SearchState?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setSearchOverlay(searchState: searchState)
            }
            return
        }

        // Layering contract: keep terminal Cmd+F UI inside this portal-hosted AppKit view.
        // SwiftUI panel-level overlays can fall behind portal-hosted terminal surfaces.
        guard let terminalSurface = surfaceView.terminalSurface,
              let searchState else {
            searchOverlayHostingView?.removeFromSuperview()
            searchOverlayHostingView = nil
            return
        }

        let tabId = terminalSurface.tabId
        let surfaceId = terminalSurface.id
        let rootView = SurfaceSearchOverlay(
            tabId: tabId,
            surfaceId: surfaceId,
            searchState: searchState,
            onMoveFocusToTerminal: { [weak self] in
                self?.moveFocus()
            },
            onNavigateSearch: { [weak terminalSurface] action in
                _ = terminalSurface?.performBindingAction(action)
            },
            onClose: { [weak self, weak terminalSurface] in
                terminalSurface?.searchState = nil
                self?.moveFocus()
            }
        )

        if let overlay = searchOverlayHostingView {
            overlay.rootView = rootView
            if overlay.superview !== self {
                overlay.removeFromSuperview()
                addSubview(overlay)
                NSLayoutConstraint.activate([
                    overlay.topAnchor.constraint(equalTo: topAnchor),
                    overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
                    overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
                    overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
                ])
            }
            return
        }

        let overlay = NSHostingView(rootView: rootView)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        searchOverlayHostingView = overlay
    }

    // MARK: - IME Input Bar

    func toggleIMEInputBar() {
        if imeInputBarHostingView != nil {
            dismissIMEInputBar()
            return
        }

        let rootView = IMEInputBar(
            onSubmit: { [weak self] text -> Bool in
                guard let self = self else { return false }
                // Image paths (from IME paste) must go through bracketed paste
                // (ghostty_surface_text) so Claude Code recognizes them as images
                // ([Image #1]) instead of treating the path as typed text.
                if text.range(of: #"/tmp/clipboard-\d+\.png"#, options: .regularExpression) != nil,
                   let surface = self.surfaceView.terminalSurface {
                    surface.sendText(text)
                    surface.sendSurfaceKeyPress(keycode: 0x24, text: "\r")
                    return true
                } else if self.surfaceView.surface != nil {
                    return self.surfaceView.sendIMEText(text)
                } else {
                    // Surface temporarily nil (pane re-creation) — retry once after 50ms
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        guard let self, self.surfaceView.surface != nil else {
                            NSSound.beep()
                            return
                        }
                        if !self.surfaceView.sendIMEText(text) {
                            NSSound.beep()
                        }
                    }
                    // Return false since the actual send is deferred; caller should not clear text
                    return false
                }
            },
            onBroadcast: { text in
                NotificationCenter.default.post(
                    name: .termMeshBroadcastIMEText,
                    object: nil,
                    userInfo: ["text": text]
                )
            },
            onClose: { [weak self] in
                self?.dismissIMEInputBar()
            },
            onCtrlC: { [weak self] in
                guard let self, let surface = self.surfaceView.surface else { return }
                // Send Ctrl+C as key event (enables Claude double Ctrl+C exit detection)
                var keyEvent = ghostty_input_key_s()
                keyEvent.action = GHOSTTY_ACTION_PRESS
                keyEvent.keycode = 8  // 'c' key
                keyEvent.mods = GHOSTTY_MODS_CTRL
                keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                keyEvent.unshifted_codepoint = 0x63  // 'c'
                keyEvent.composing = false
                keyEvent.text = nil
                _ = ghostty_surface_key(surface, keyEvent)
                keyEvent.action = GHOSTTY_ACTION_RELEASE
                _ = ghostty_surface_key(surface, keyEvent)
            },
            onSendKey: { [weak self] keycode, mods in
                guard let self, let surface = self.surfaceView.surface else { return }
                var keyEvent = ghostty_input_key_s()
                keyEvent.action = GHOSTTY_ACTION_PRESS
                keyEvent.keycode = UInt32(keycode)
                keyEvent.mods = ghostty_input_mods_e(rawValue: mods)
                keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                keyEvent.unshifted_codepoint = 0
                keyEvent.composing = false
                keyEvent.text = nil
                _ = ghostty_surface_key(surface, keyEvent)
                keyEvent.action = GHOSTTY_ACTION_RELEASE
                _ = ghostty_surface_key(surface, keyEvent)
            }
        )

        let overlay = NSHostingView(rootView: rootView)
        addSubview(overlay)
        imeInputBarHostingView = overlay

        // Reset height to persisted value
        imeBarCurrentHeight = IMEInputBarSettings.height

        // Add drag handle for resizing
        let handle = IMEBarDragHandle()
        handle.currentHeight = imeBarCurrentHeight
        handle.onHeightChange = { [weak self] newHeight in
            guard let self else { return }
            self.imeBarCurrentHeight = newHeight
            handle.currentHeight = newHeight
            self.needsLayout = true
        }
        addSubview(handle, positioned: .above, relativeTo: overlay)
        imeBarDragHandle = handle

        // Trigger layout to position the bar at the bottom and shrink the terminal
        needsLayout = true
    }

    private func dismissIMEInputBar() {
        imeBarDragHandle?.removeFromSuperview()
        imeBarDragHandle = nil
        imeInputBarHostingView?.removeFromSuperview()
        imeInputBarHostingView = nil
        // Re-layout to restore terminal to full size
        needsLayout = true
        // Only restore focus if the surface view is still in a valid window hierarchy.
        // During window close or tab switch, moveFocus would target a detached view.
        guard window != nil, surfaceView.window != nil else { return }
        moveFocus()
    }

    /// Finds the IMETextView inside the IME input bar hosting view (if active).
    func findIMETextView() -> IMETextView? {
        guard let hostingView = imeInputBarHostingView else { return nil }
        return Self.findSubview(of: IMETextView.self, in: hostingView)
    }

    private static func findSubview<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        for sub in view.subviews {
            if let match = sub as? T { return match }
            if let match = findSubview(of: type, in: sub) { return match }
        }
        return nil
    }

    private func dropZoneOverlayFrame(for zone: DropZone, in size: CGSize) -> CGRect {
        let padding: CGFloat = 4
        switch zone {
        case .center:
            return CGRect(x: padding, y: padding, width: size.width - padding * 2, height: size.height - padding * 2)
        case .left:
            return CGRect(x: padding, y: padding, width: size.width / 2 - padding, height: size.height - padding * 2)
        case .right:
            return CGRect(x: size.width / 2, y: padding, width: size.width / 2 - padding, height: size.height - padding * 2)
        case .top:
            return CGRect(x: padding, y: size.height / 2, width: size.width - padding * 2, height: size.height / 2 - padding)
        case .bottom:
            return CGRect(x: padding, y: padding, width: size.width - padding * 2, height: size.height / 2 - padding)
        }
    }

    private static func rectApproximatelyEqual(_ lhs: CGRect, _ rhs: CGRect, epsilon: CGFloat = 0.5) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= epsilon &&
            abs(lhs.origin.y - rhs.origin.y) <= epsilon &&
            abs(lhs.size.width - rhs.size.width) <= epsilon &&
            abs(lhs.size.height - rhs.size.height) <= epsilon
    }

    func setDropZoneOverlay(zone: DropZone?) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.setDropZoneOverlay(zone: zone)
            }
            return
        }

        if let zone, (bounds.width <= 2 || bounds.height <= 2) {
            pendingDropZone = zone
#if DEBUG
            logDropZoneOverlay(event: "deferZeroBounds", zone: zone, frame: nil)
#endif
            return
        }

        let previousZone = activeDropZone
        activeDropZone = zone
        pendingDropZone = nil

        let previousFrame = dropZoneOverlayView.frame

        if let zone {
#if DEBUG
            if window == nil {
                logDropZoneOverlay(event: "showNoWindow", zone: zone, frame: nil)
            }
#endif
            let targetFrame = dropZoneOverlayFrame(for: zone, in: bounds.size)
            let isSameFrame = Self.rectApproximatelyEqual(previousFrame, targetFrame)
            let needsFrameUpdate = !isSameFrame
            let zoneChanged = previousZone != zone

            if !dropZoneOverlayView.isHidden && !needsFrameUpdate && !zoneChanged {
                return
            }

            dropZoneOverlayAnimationGeneration &+= 1
            dropZoneOverlayView.layer?.removeAllAnimations()

            if dropZoneOverlayView.isHidden {
                dropZoneOverlayView.frame = targetFrame
                dropZoneOverlayView.alphaValue = 0
                dropZoneOverlayView.isHidden = false
#if DEBUG
                recordDropOverlayShowAnimation()
#endif
#if DEBUG
                logDropZoneOverlay(event: "show", zone: zone, frame: targetFrame)
#endif

                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    dropZoneOverlayView.animator().alphaValue = 1
                } completionHandler: { [weak self] in
#if DEBUG
                    guard let self else { return }
                    guard self.activeDropZone == zone else { return }
                    self.logDropZoneOverlay(event: "showComplete", zone: zone, frame: targetFrame)
#endif
                }
                return
            }

#if DEBUG
            if needsFrameUpdate || zoneChanged {
                logDropZoneOverlay(event: "update", zone: zone, frame: targetFrame)
            }
#endif
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                if needsFrameUpdate {
                    dropZoneOverlayView.animator().frame = targetFrame
                }
                if dropZoneOverlayView.alphaValue < 1 {
                    dropZoneOverlayView.animator().alphaValue = 1
                }
            }
        } else {
            guard !dropZoneOverlayView.isHidden else { return }
            dropZoneOverlayAnimationGeneration &+= 1
            let animationGeneration = dropZoneOverlayAnimationGeneration
            dropZoneOverlayView.layer?.removeAllAnimations()
#if DEBUG
            logDropZoneOverlay(event: "hide", zone: nil, frame: nil)
#endif

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                dropZoneOverlayView.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self else { return }
                guard self.dropZoneOverlayAnimationGeneration == animationGeneration else { return }
                guard self.activeDropZone == nil else { return }
                self.dropZoneOverlayView.isHidden = true
                self.dropZoneOverlayView.alphaValue = 1
#if DEBUG
                self.logDropZoneOverlay(event: "hideComplete", zone: nil, frame: nil)
#endif
            }
        }
    }

#if DEBUG
    private func logDropZoneOverlay(event: String, zone: DropZone?, frame: CGRect?) {
        let surface = surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil"
        let zoneText = zone.map { String(describing: $0) } ?? "none"
        let boundsText = String(format: "%.1fx%.1f", bounds.width, bounds.height)
        let frameText: String
        if let frame {
            frameText = String(
                format: "%.1f,%.1f %.1fx%.1f",
                frame.origin.x, frame.origin.y, frame.width, frame.height
            )
        } else {
            frameText = "-"
        }
        let signature = "\(event)|\(surface)|\(zoneText)|\(boundsText)|\(frameText)|\(dropZoneOverlayView.isHidden ? 1 : 0)"
        guard lastDropZoneOverlayLogSignature != signature else { return }
        lastDropZoneOverlayLogSignature = signature
        dlog(
            "terminal.dropOverlay event=\(event) surface=\(surface) zone=\(zoneText) " +
            "hidden=\(dropZoneOverlayView.isHidden ? 1 : 0) bounds=\(boundsText) frame=\(frameText)"
        )
    }
#endif

    func triggerFlash() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
#if DEBUG
            if let surfaceId = self.surfaceView.terminalSurface?.id {
                Self.recordFlash(for: surfaceId)
            }
#endif
            self.updateFlashPath()
            self.flashLayer.removeAllAnimations()
            self.flashLayer.opacity = 0
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = FocusFlashPattern.values.map { NSNumber(value: $0) }
            animation.keyTimes = FocusFlashPattern.keyTimes.map { NSNumber(value: $0) }
            animation.duration = FocusFlashPattern.duration
            animation.timingFunctions = FocusFlashPattern.curves.map { curve in
                switch curve {
                case .easeIn:
                    return CAMediaTimingFunction(name: .easeIn)
                case .easeOut:
                    return CAMediaTimingFunction(name: .easeOut)
                }
            }
            self.flashLayer.add(animation, forKey: "term-mesh.flash")
        }
    }

    func setVisibleInUI(_ visible: Bool) {
        let wasVisible = surfaceView.isVisibleInUI
        surfaceView.setVisibleInUI(visible)
        isHidden = !visible
#if DEBUG
        if wasVisible != visible {
            debugLogWorkspaceSwitchTiming(
                event: "ws.term.visible",
                suffix: "surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") value=\(visible ? 1 : 0)"
            )
        }
#endif
        if !visible {
            // If we were focused, yield first responder.
            if let window, let fr = window.firstResponder as? NSView,
               fr === surfaceView || fr.isDescendant(of: surfaceView) {
                window.makeFirstResponder(nil)
            }
        } else {
            applyFirstResponderIfNeeded()
        }
    }

    /// Send a synthetic key press/release directly to the surface NSView.
    /// Bypasses ghostty_surface_text (and thus bracketed paste mode).
    func sendSyntheticKeyPress(keycode: UInt16, characters: String) {
        guard let window = surfaceView.window else { return }
        let ts = ProcessInfo.processInfo.systemUptime
        if let down = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ts, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keycode
        ) {
            surfaceView.keyDown(with: down)
        }
        if let up = NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [],
            timestamp: ts + 0.001, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keycode
        ) {
            surfaceView.keyUp(with: up)
        }
    }

    func setActive(_ active: Bool) {
        let wasActive = isActive
        isActive = active
#if DEBUG
        if wasActive != active {
            debugLogWorkspaceSwitchTiming(
                event: "ws.term.active",
                suffix: "surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") value=\(active ? 1 : 0)"
            )
        }
#endif
        if active {
            applyFirstResponderIfNeeded()
        } else if let window,
                  let fr = window.firstResponder as? NSView,
                  fr === surfaceView || fr.isDescendant(of: surfaceView) {
            window.makeFirstResponder(nil)
        }
    }

#if DEBUG
    private func debugLogWorkspaceSwitchTiming(event: String, suffix: String) {
        guard let snapshot = AppDelegate.shared?.tabManager?.debugCurrentWorkspaceSwitchSnapshot() else {
            dlog("\(event) id=none \(suffix)")
            return
        }
        let dtMs = (CACurrentMediaTime() - snapshot.startedAt) * 1000
        dlog("\(event) id=\(snapshot.id) dt=\(String(format: "%.2fms", dtMs)) \(suffix)")
    }
#endif

    func moveFocus(from previous: GhosttySurfaceScrollView? = nil, delay: TimeInterval? = nil) {
#if DEBUG
        dlog("focus.moveFocus to=\(self.surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil")")
#endif
        let work = { [weak self] in
            guard let self else { return }
            guard let window = self.window else { return }
            if let previous, previous !== self {
                _ = previous.surfaceView.resignFirstResponder()
            }
            // If IME bar is active in this pane, redirect focus to IMETextView
            if let imeTextView = self.findIMETextView() {
                window.makeFirstResponder(imeTextView)
            } else {
                window.makeFirstResponder(self.surfaceView)
            }
        }

        if let delay, delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work() }
        } else {
            if Thread.isMainThread {
                work()
            } else {
                DispatchQueue.main.async { work() }
            }
        }
    }

#if DEBUG
    @discardableResult
    func debugSimulateFileDrop(paths: [String]) -> Bool {
        surfaceView.debugSimulateFileDrop(paths: paths)
    }

    func debugRegisteredDropTypes() -> [String] {
        surfaceView.debugRegisteredDropTypes()
    }

    func debugInactiveOverlayState() -> (isHidden: Bool, alpha: CGFloat) {
        (
            inactiveOverlayView.isHidden,
            inactiveOverlayView.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.alphaComponent } ?? 0
        )
    }

    func debugNotificationRingState() -> (isHidden: Bool, opacity: Float) {
        (
            notificationRingOverlayView.isHidden,
            notificationRingLayer.opacity
        )
    }

    func debugHasSearchOverlay() -> Bool {
        guard let overlay = searchOverlayHostingView else { return false }
        return overlay.superview === self && !overlay.isHidden
    }

#endif

    /// Handle file/URL drops, forwarding to the terminal as shell-escaped paths.
    func handleDroppedURLs(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let content = urls
            .map { GhosttyNSView.escapeDropForShell($0.path) }
            .joined(separator: " ")
        #if DEBUG
        dlog("terminal.swiftUIDrop surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") urls=\(urls.map(\.lastPathComponent))")
        #endif
        surfaceView.terminalSurface?.sendText(content)
        return true
    }

    func terminalViewForDrop(at point: NSPoint) -> GhosttyNSView? {
        guard bounds.contains(point), !isHidden else { return nil }
        return surfaceView
    }

#if DEBUG
    /// Sends a synthetic Ctrl+D key press directly to the surface view.
    /// This exercises the same key path as real keyboard input (ghostty_surface_key),
    /// unlike `sendText`, which bypasses key translation.
    @discardableResult
    func sendSyntheticCtrlDForUITest(modifierFlags: NSEvent.ModifierFlags = [.control]) -> Bool {
        guard let window else { return false }
        window.makeFirstResponder(surfaceView)

        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let keyDown = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{04}",
            charactersIgnoringModifiers: "d",
            isARepeat: false,
            keyCode: 2
        ) else { return false }

        guard let keyUp = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: timestamp + 0.001,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{04}",
            charactersIgnoringModifiers: "d",
            isARepeat: false,
            keyCode: 2
        ) else { return false }

        surfaceView.keyDown(with: keyDown)
        surfaceView.keyUp(with: keyUp)
        return true
    }
    #endif

    func ensureFocus(for tabId: UUID, surfaceId: UUID, attemptsRemaining: Int = 3) {
        func retry() {
            guard attemptsRemaining > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.ensureFocus(for: tabId, surfaceId: surfaceId, attemptsRemaining: attemptsRemaining - 1)
            }
        }

        let hasUsablePortalGeometry: Bool = {
            let size = bounds.size
            return size.width > 1 && size.height > 1
        }()
        let isHiddenForFocus = isHiddenOrHasHiddenAncestor || surfaceView.isHiddenOrHasHiddenAncestor

        guard isActive else { return }
        guard surfaceView.terminalSurface?.searchState == nil else { return }
        // If IME bar is active, redirect focus there instead of the terminal surface.
        if let imeTextView = findIMETextView() {
            if let window { window.makeFirstResponder(imeTextView) }
            return
        }
        guard let window else { return }
        guard surfaceView.isVisibleInUI else {
            retry()
            return
        }
        guard !isHiddenForFocus, hasUsablePortalGeometry else {
#if DEBUG
            dlog(
                "focus.ensure.defer surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "reason=hidden_or_tiny hidden=\(isHiddenForFocus ? 1 : 0) " +
                "frame=\(String(format: "%.1fx%.1f", bounds.width, bounds.height)) attempts=\(attemptsRemaining)"
            )
#endif
            retry()
            return
        }

        guard let delegate = AppDelegate.shared,
              let tabManager = delegate.tabManagerFor(tabId: tabId) ?? delegate.tabManager,
              tabManager.selectedTabId == tabId else {
            retry()
            return
        }

        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              let tabIdForSurface = tab.surfaceIdFromPanelId(surfaceId),
              let paneId = tab.bonsplitController.allPaneIds.first(where: { paneId in
                  tab.bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabIdForSurface })
              }) else {
            retry()
            return
        }

        guard tab.bonsplitController.selectedTab(inPane: paneId)?.id == tabIdForSurface,
              tab.bonsplitController.focusedPaneId == paneId else {
            retry()
            return
        }

        if let fr = window.firstResponder as? NSView,
           fr === surfaceView || fr.isDescendant(of: surfaceView) {
            return
        }

        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        _ = window.makeFirstResponder(surfaceView)

        if !isSurfaceViewFirstResponder() {
            retry()
        }
    }

    /// Suppress the surface view's onFocus callback and ghostty_surface_set_focus during
    /// SwiftUI reparenting (programmatic splits). Call clearSuppressReparentFocus() after layout settles.
    func suppressReparentFocus() {
        surfaceView.suppressingReparentFocus = true
    }

    func clearSuppressReparentFocus() {
        surfaceView.suppressingReparentFocus = false
    }

    /// Returns true if the terminal's actual Ghostty surface view is (or contains) the window first responder.
    /// This is stricter than checking `hostedView` descendants, since the scroll view can sometimes become
    /// first responder transiently while focus is being applied.
    func isSurfaceViewFirstResponder() -> Bool {
        guard let window, let fr = window.firstResponder as? NSView else { return false }
        return fr === surfaceView || fr.isDescendant(of: surfaceView)
    }

    private func applyFirstResponderIfNeeded() {
        let hasUsablePortalGeometry: Bool = {
            let size = bounds.size
            return size.width > 1 && size.height > 1
        }()
        let isHiddenForFocus = isHiddenOrHasHiddenAncestor || surfaceView.isHiddenOrHasHiddenAncestor

        guard isActive else { return }
        guard surfaceView.isVisibleInUI else { return }
        guard !isHiddenForFocus, hasUsablePortalGeometry else {
#if DEBUG
            dlog(
                "focus.apply.skip surface=\(surfaceView.terminalSurface?.id.uuidString.prefix(5) ?? "nil") " +
                "reason=hidden_or_tiny hidden=\(isHiddenForFocus ? 1 : 0) frame=\(String(format: "%.1fx%.1f", bounds.width, bounds.height))"
            )
#endif
            return
        }
        guard surfaceView.terminalSurface?.searchState == nil else { return }
        guard findIMETextView() == nil else { return }
        guard let window, window.isKeyWindow else { return }
        if let fr = window.firstResponder as? NSView,
           fr === surfaceView || fr.isDescendant(of: surfaceView) {
            return
        }
        window.makeFirstResponder(surfaceView)
    }

#if DEBUG
    struct DebugRenderStats {
        let drawCount: Int
        let lastDrawTime: CFTimeInterval
        let metalDrawableCount: Int
        let metalLastDrawableTime: CFTimeInterval
        let presentCount: Int
        let lastPresentTime: CFTimeInterval
        let layerClass: String
        let layerContentsKey: String
        let inWindow: Bool
        let windowIsKey: Bool
        let windowOcclusionVisible: Bool
        let appIsActive: Bool
        let isActive: Bool
        let desiredFocus: Bool
        let isFirstResponder: Bool
    }

    func debugRenderStats() -> DebugRenderStats {
        let layerClass = surfaceView.layer.map { String(describing: type(of: $0)) } ?? "nil"
        let (metalCount, metalLast) = (surfaceView.layer as? GhosttyMetalLayer)?.debugStats() ?? (0, 0)
        let (drawCount, lastDraw): (Int, CFTimeInterval) = surfaceView.terminalSurface.map { terminalSurface in
            Self.drawStats(for: terminalSurface.id)
        } ?? (0, 0)
        let (presentCount, lastPresent, contentsKey): (Int, CFTimeInterval, String) = surfaceView.terminalSurface.map { terminalSurface in
            let stats = Self.updatePresentStats(surfaceId: terminalSurface.id, layer: surfaceView.layer)
            return (stats.count, stats.last, stats.key)
        } ?? (0, 0, Self.contentsKey(for: surfaceView.layer))
        let inWindow = (window != nil)
        let windowIsKey = window?.isKeyWindow ?? false
        let windowOcclusionVisible = (window?.occlusionState.contains(.visible) ?? false) || (window?.isKeyWindow ?? false)
        let appIsActive = NSApp.isActive
        let fr = window?.firstResponder as? NSView
        let isFirstResponder = fr == surfaceView || (fr?.isDescendant(of: surfaceView) ?? false)
        return DebugRenderStats(
            drawCount: drawCount,
            lastDrawTime: lastDraw,
            metalDrawableCount: metalCount,
            metalLastDrawableTime: metalLast,
            presentCount: presentCount,
            lastPresentTime: lastPresent,
            layerClass: layerClass,
            layerContentsKey: contentsKey,
            inWindow: inWindow,
            windowIsKey: windowIsKey,
            windowOcclusionVisible: windowOcclusionVisible,
            appIsActive: appIsActive,
            isActive: isActive,
            desiredFocus: surfaceView.desiredFocus,
            isFirstResponder: isFirstResponder
        )
    }
#endif

#if DEBUG
    struct DebugFrameSample {
        let sampleCount: Int
        let uniqueQuantized: Int
        let lumaStdDev: Double
        let modeFraction: Double
        let fingerprint: UInt64
        let iosurfaceWidthPx: Int
        let iosurfaceHeightPx: Int
        let expectedWidthPx: Int
        let expectedHeightPx: Int
        let layerClass: String
        let layerContentsGravity: String
        let layerContentsKey: String

        var isProbablyBlank: Bool {
            (lumaStdDev < 3.5 && modeFraction > 0.985) ||
            (uniqueQuantized <= 6 && modeFraction > 0.95)
        }
    }

    /// Create a CGImage from the terminal's IOSurface-backed layer contents.
    ///
    /// This avoids Screen Recording permissions (unlike CGWindowListCreateImage) and is therefore
    /// suitable for debug socket tests running in headless/VM contexts.
    func debugCopyIOSurfaceCGImage() -> CGImage? {
        guard let modelLayer = surfaceView.layer else { return nil }
        let layer = modelLayer.presentation() ?? modelLayer
        guard let contents = layer.contents else { return nil }

        let cf = contents as CFTypeRef
        guard CFGetTypeID(cf) == IOSurfaceGetTypeID() else { return nil }
        let surfaceRef = (contents as! IOSurfaceRef)

        let width = Int(IOSurfaceGetWidth(surfaceRef))
        let height = Int(IOSurfaceGetHeight(surfaceRef))
        let bytesPerRow = Int(IOSurfaceGetBytesPerRow(surfaceRef))
        guard width > 0, height > 0, bytesPerRow > 0 else { return nil }

        IOSurfaceLock(surfaceRef, [], nil)
        defer { IOSurfaceUnlock(surfaceRef, [], nil) }

        let base = IOSurfaceGetBaseAddress(surfaceRef)
        let size = bytesPerRow * height
        let data = Data(bytes: base, count: size)

        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Sample the IOSurface backing the terminal layer (if any) to detect a transient blank frame
    /// without using screenshots/screen recording permissions.
    func debugSampleIOSurface(normalizedCrop: CGRect) -> DebugFrameSample? {
        guard let modelLayer = surfaceView.layer else { return nil }
        // Prefer the presentation layer to better match what the user sees on screen.
        let layer = modelLayer.presentation() ?? modelLayer
        let layerClass = String(describing: type(of: layer))
        let layerContentsGravity = layer.contentsGravity.rawValue
        let contentsKey = Self.contentsKey(for: layer)
        let presentationScale = max(1.0, layer.contentsScale)
        let expectedWidthPx = Int((layer.bounds.width * presentationScale).rounded(.toNearestOrAwayFromZero))
        let expectedHeightPx = Int((layer.bounds.height * presentationScale).rounded(.toNearestOrAwayFromZero))

        // Ghostty uses a CoreAnimation layer whose `contents` is an IOSurface-backed object.
        // The concrete layer class is often `IOSurfaceLayer` (private), so avoid referencing it directly.
        guard let anySurface = layer.contents else {
            // Treat "no contents" as a blank frame: this is the visual regression we're guarding.
            return DebugFrameSample(
                sampleCount: 0,
                uniqueQuantized: 0,
                lumaStdDev: 0,
                modeFraction: 1,
                fingerprint: 0,
                iosurfaceWidthPx: 0,
                iosurfaceHeightPx: 0,
                expectedWidthPx: expectedWidthPx,
                expectedHeightPx: expectedHeightPx,
                layerClass: layerClass,
                layerContentsGravity: layerContentsGravity,
                layerContentsKey: contentsKey
            )
        }

        // IOSurfaceLayer.contents is usually an IOSurface, but during mitigation we may
        // temporarily replace contents with a CGImage snapshot to avoid blank flashes.
        // Treat non-IOSurface contents as "non-blank" and avoid unsafe casts.
        let cf = anySurface as CFTypeRef
        guard CFGetTypeID(cf) == IOSurfaceGetTypeID() else {
            var fnv: UInt64 = 1469598103934665603
            for b in contentsKey.utf8 {
                fnv ^= UInt64(b)
                fnv &*= 1099511628211
            }
            return DebugFrameSample(
                sampleCount: 1,
                uniqueQuantized: 1,
                lumaStdDev: 999,
                modeFraction: 0,
                fingerprint: fnv,
                iosurfaceWidthPx: 0,
                iosurfaceHeightPx: 0,
                expectedWidthPx: expectedWidthPx,
                expectedHeightPx: expectedHeightPx,
                layerClass: layerClass,
                layerContentsGravity: layerContentsGravity,
                layerContentsKey: contentsKey
            )
        }

        let surfaceRef = (anySurface as! IOSurfaceRef)

        let width = Int(IOSurfaceGetWidth(surfaceRef))
        let height = Int(IOSurfaceGetHeight(surfaceRef))
        if width <= 0 || height <= 0 { return nil }

        let cropPx = CGRect(
            x: max(0, min(CGFloat(width - 1), normalizedCrop.origin.x * CGFloat(width))),
            y: max(0, min(CGFloat(height - 1), normalizedCrop.origin.y * CGFloat(height))),
            width: max(1, min(CGFloat(width), normalizedCrop.width * CGFloat(width))),
            height: max(1, min(CGFloat(height), normalizedCrop.height * CGFloat(height)))
        ).integral

        let x0 = Int(cropPx.minX)
        let y0 = Int(cropPx.minY)
        let x1 = Int(min(CGFloat(width), cropPx.maxX))
        let y1 = Int(min(CGFloat(height), cropPx.maxY))
        if x1 <= x0 || y1 <= y0 { return nil }

        IOSurfaceLock(surfaceRef, [], nil)
        defer { IOSurfaceUnlock(surfaceRef, [], nil) }

        let base = IOSurfaceGetBaseAddress(surfaceRef)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surfaceRef)
        if bytesPerRow <= 0 { return nil }

        // Assume 4 bytes/pixel BGRA (common for IOSurfaceLayer contents).
        let bytesPerPixel = 4
        let step = 6

        var hist = [UInt16: Int]()
        hist.reserveCapacity(256)

        var lumas = [Double]()
        lumas.reserveCapacity(((x1 - x0) / step) * ((y1 - y0) / step))

        var count = 0
        var fnv: UInt64 = 1469598103934665603

        for y in stride(from: y0, to: y1, by: step) {
            let row = base.advanced(by: y * bytesPerRow)
            for x in stride(from: x0, to: x1, by: step) {
                let p = row.advanced(by: x * bytesPerPixel)
                let b = Double(p.load(fromByteOffset: 0, as: UInt8.self))
                let g = Double(p.load(fromByteOffset: 1, as: UInt8.self))
                let r = Double(p.load(fromByteOffset: 2, as: UInt8.self))
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                lumas.append(luma)

                let rq = UInt16(UInt8(r) >> 4)
                let gq = UInt16(UInt8(g) >> 4)
                let bq = UInt16(UInt8(b) >> 4)
                let key = (rq << 8) | (gq << 4) | bq
                hist[key, default: 0] += 1
                count += 1

                let lq = UInt8(max(0, min(63, Int(luma / 4.0))))
                fnv ^= UInt64(lq)
                fnv &*= 1099511628211
            }
        }

        guard count > 0 else { return nil }
        let mean = lumas.reduce(0.0, +) / Double(lumas.count)
        let variance = lumas.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(lumas.count)
        let stddev = sqrt(variance)

        let modeCount = hist.values.max() ?? 0
        let modeFrac = Double(modeCount) / Double(count)

        return DebugFrameSample(
            sampleCount: count,
            uniqueQuantized: hist.count,
            lumaStdDev: stddev,
            modeFraction: modeFrac,
            fingerprint: fnv,
            iosurfaceWidthPx: width,
            iosurfaceHeightPx: height,
            expectedWidthPx: expectedWidthPx,
            expectedHeightPx: expectedHeightPx,
            layerClass: layerClass,
            layerContentsGravity: layerContentsGravity,
            layerContentsKey: contentsKey
        )
    }
#endif

    func cancelFocusRequest() {
        // Intentionally no-op (no retry loops).
    }

    private func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        surfaceView.frame.origin = visibleRect.origin
    }

    /// Match upstream Ghostty behavior: use content area width (excluding non-content
    /// regions such as scrollbar space) when telling libghostty the terminal size.
    private func synchronizeCoreSurface() {
        let width = scrollView.contentSize.width
        let height = surfaceView.frame.height
        guard width > 0, height > 0 else { return }
        surfaceView.pushTargetSurfaceSize(CGSize(width: width, height: height))
    }

    private func updateNotificationRingPath() {
        updateOverlayRingPath(
            layer: notificationRingLayer,
            bounds: notificationRingOverlayView.bounds,
            inset: 2,
            radius: 6
        )
    }

    private func updateFlashPath() {
        updateOverlayRingPath(
            layer: flashLayer,
            bounds: flashOverlayView.bounds,
            inset: CGFloat(FocusFlashPattern.ringInset),
            radius: CGFloat(FocusFlashPattern.ringCornerRadius)
        )
    }

    private func updateOverlayRingPath(
        layer: CAShapeLayer,
        bounds: CGRect,
        inset: CGFloat,
        radius: CGFloat
    ) {
        layer.frame = bounds
        guard bounds.width > inset * 2, bounds.height > inset * 2 else {
            layer.path = nil
            return
        }
        let rect = bounds.insetBy(dx: inset, dy: inset)
        layer.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private func synchronizeScrollView() {
        documentView.frame.size.height = documentHeight()

        if !isLiveScrolling {
            let cellHeight = surfaceView.cellSize.height
            if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
                let offsetY =
                    CGFloat(scrollbar.total - scrollbar.offset - scrollbar.len) * cellHeight
                scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))
                lastSentRow = Int(scrollbar.offset)
            }
        }

        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func handleScrollChange() {
        synchronizeSurfaceView()
    }

    private func handleLiveScroll() {
        let cellHeight = surfaceView.cellSize.height
        guard cellHeight > 0 else { return }

        let visibleRect = scrollView.contentView.documentVisibleRect
        let documentHeight = documentView.frame.height
        let scrollOffset = documentHeight - visibleRect.origin.y - visibleRect.height
        let row = Int(scrollOffset / cellHeight)

        guard row != lastSentRow else { return }
        lastSentRow = row
        _ = surfaceView.performBindingAction("scroll_to_row:\(row)")
    }

    private func handleScrollbarUpdate(_ notification: Notification) {
        guard let scrollbar = notification.userInfo?[GhosttyNotificationKey.scrollbar] as? GhosttyScrollbar else {
            return
        }
        surfaceView.scrollbar = scrollbar
        synchronizeScrollView()
    }

    private func documentHeight() -> CGFloat {
        let contentHeight = scrollView.contentSize.height
        let cellHeight = surfaceView.cellSize.height
        if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
            let documentGridHeight = CGFloat(scrollbar.total) * cellHeight
            let padding = contentHeight - (CGFloat(scrollbar.len) * cellHeight)
            return documentGridHeight + padding
        }
        return contentHeight
    }
}
