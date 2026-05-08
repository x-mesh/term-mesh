import Foundation
import AppKit
import SwiftUI

class UpdateViewModel: ObservableObject {
    @Published var state: UpdateState = .idle
    #if DEBUG
    @Published var debugOverrideText: String?
    #endif

    var effectiveState: UpdateState { state }

    var text: String {
        #if DEBUG
        if let debugOverrideText { return debugOverrideText }
        #endif
        switch state {
        case .idle:
            return ""
        case .checking:
            return "Checking for Updates…"
        case .upToDate:
            return "No Updates Available"
        case .updateAvailable(_, let latest, _, _):
            return "Update Available: \(latest)"
        case .downloading(_, _, let message):
            return message
        case .readyToInstall(_, let latest, _, _):
            return "Update Available: \(latest)"
        case .error(let message, _, _):
            return message
        }
    }

    var maxWidthText: String { text }

    var iconName: String? {
        switch effectiveState {
        case .idle:
            return nil
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .upToDate:
            return "info.circle"
        case .updateAvailable, .readyToInstall:
            return "shippingbox.fill"
        case .downloading:
            return "arrow.down.circle"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    var description: String {
        switch effectiveState {
        case .idle:
            return ""
        case .checking:
            return "Please wait while we check for available updates"
        case .upToDate:
            return "You are running the latest version"
        case .updateAvailable(let installed, let latest, _, _):
            return "term-mesh \(installed) → \(latest) via Homebrew"
        case .downloading(_, _, let message):
            return message
        case .readyToInstall(let installed, let latest, _, _):
            return "term-mesh \(installed) → \(latest) via Homebrew"
        case .error(let message, _, _):
            return message
        }
    }

    var badge: String? {
        switch effectiveState {
        case .updateAvailable(_, let latest, _, _):
            return latest
        case .readyToInstall(_, let latest, _, _):
            return latest
        default:
            return nil
        }
    }

    var iconColor: Color {
        switch effectiveState {
        case .updateAvailable, .readyToInstall:
            return .accentColor
        case .error:
            return .orange
        default:
            return .secondary
        }
    }

    var backgroundColor: Color {
        switch effectiveState {
        case .updateAvailable, .readyToInstall:
            return .accentColor
        case .upToDate:
            return Color(nsColor: NSColor.systemBlue.blended(withFraction: 0.5, of: .black) ?? .systemBlue)
        case .error:
            return .orange.opacity(0.2)
        default:
            return Color(nsColor: .controlBackgroundColor)
        }
    }

    var foregroundColor: Color {
        switch effectiveState {
        case .updateAvailable, .readyToInstall, .upToDate:
            return .white
        case .error:
            return .orange
        default:
            return .primary
        }
    }
}

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate(dismiss: () -> Void)
    case updateAvailable(installed: String, latest: String, install: () -> Void, dismiss: () -> Void)
    case downloading(installed: String, latest: String, message: String)
    case readyToInstall(installed: String, latest: String, install: () -> Void, dismiss: () -> Void)
    case error(message: String, retry: () -> Void, dismiss: () -> Void)

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    var isInstallable: Bool {
        switch self {
        case .readyToInstall, .updateAvailable, .downloading:
            return true
        default:
            return false
        }
    }

    func cancel() {
        switch self {
        case .upToDate(let dismiss):
            dismiss()
        case .updateAvailable(_, _, _, let dismiss):
            dismiss()
        case .readyToInstall(_, _, _, let dismiss):
            dismiss()
        case .error(_, _, let dismiss):
            dismiss()
        default:
            break
        }
    }

    func confirm() {
        switch self {
        case .updateAvailable(_, _, let install, _):
            install()
        case .readyToInstall(_, _, let install, _):
            install()
        default:
            break
        }
    }

    static func == (lhs: UpdateState, rhs: UpdateState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.checking, .checking):
            return true
        case (.upToDate, .upToDate):
            return true
        case (.updateAvailable(let li, let ll, _, _), .updateAvailable(let ri, let rl, _, _)):
            return li == ri && ll == rl
        case (.downloading(let li, let ll, let lm), .downloading(let ri, let rl, let rm)):
            return li == ri && ll == rl && lm == rm
        case (.readyToInstall(let li, let ll, _, _), .readyToInstall(let ri, let rl, _, _)):
            return li == ri && ll == rl
        case (.error(let lm, _, _), .error(let rm, _, _)):
            return lm == rm
        default:
            return false
        }
    }
}
