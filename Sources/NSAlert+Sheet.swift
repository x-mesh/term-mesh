import AppKit

extension NSAlert {
    /// Present as sheet on the key/main window if available, otherwise defer presentation
    /// until a window becomes key. Never falls back to `runModal()` — that would spin a
    /// nested modal event loop on the main thread and trip macOS's App Hanging watchdog
    /// (see Sentry TERM-MESH-18).
    ///
    /// For Type A alerts (OK-only), call without completion.
    /// For Type B/C alerts, use the completion handler to process the response.
    /// If the target window already has an attached sheet, this call is a no-op to prevent
    /// duplicate/stacked sheets (e.g. repeated Cmd+Q warnings).
    func presentAsSheet(for window: NSWindow? = nil, completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        let targetWindow = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        if let targetWindow {
            guard targetWindow.attachedSheet == nil else { return }
            beginSheetModal(for: targetWindow) { response in
                completion?(response)
            }
            return
        }

        // No window available — wait for one to become key, then present the sheet.
        // Strong `self` capture keeps this NSAlert alive until the observer fires;
        // the observer removes itself on first delivery to break the retain.
        //
        // The token is stored in a reference-typed box so the sendable closure can
        // read it without the "mutated after capture" warning on the var itself.
        final class ObserverBox { var token: NSObjectProtocol? }
        let box = ObserverBox()
        box.token = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [self] note in
            guard let win = note.object as? NSWindow, win.attachedSheet == nil else { return }
            if let token = box.token { NotificationCenter.default.removeObserver(token) }
            self.beginSheetModal(for: win) { response in
                completion?(response)
            }
        }
    }
}

extension NSOpenPanel {
    /// Present as sheet on the key/main window if available, otherwise fall back to runModal.
    func presentAsSheet(for window: NSWindow? = nil, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        let targetWindow = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        if let targetWindow {
            beginSheetModal(for: targetWindow, completionHandler: completion)
        } else {
            let response = runModal()
            completion(response)
        }
    }
}
