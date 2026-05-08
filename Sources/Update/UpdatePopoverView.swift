import AppKit
import SwiftUI

/// Popover view that displays detailed update information and actions.
struct UpdatePopoverView: View {
    @ObservedObject var model: UpdateViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.effectiveState {
            case .idle:
                EmptyView()

            case .checking:
                CheckingView(dismiss: dismiss)

            case .upToDate(let dismissFn):
                UpToDateView(onDismiss: dismissFn, dismiss: dismiss)

            case .updateAvailable(let installed, let latest, let install, let dismissFn):
                UpdateAvailableView(
                    installed: installed,
                    latest: latest,
                    onInstall: install,
                    onDismiss: dismissFn,
                    dismiss: dismiss
                )

            case .downloading(let installed, let latest, let message):
                DownloadingView(installed: installed, latest: latest, message: message)

            case .readyToInstall(let installed, let latest, let install, let dismissFn):
                ReadyToInstallView(
                    installed: installed,
                    latest: latest,
                    onInstall: install,
                    onDismiss: dismissFn,
                    dismiss: dismiss
                )

            case .error(let message, let retry, let dismissFn):
                UpdateErrorView(
                    message: message,
                    onRetry: retry,
                    onDismiss: dismissFn,
                    dismiss: dismiss
                )
            }
        }
        .frame(width: 300)
    }
}

fileprivate struct CheckingView: View {
    let dismiss: DismissAction

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking for updates…")
                    .font(.system(size: 13))
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}

fileprivate struct UpToDateView: View {
    let onDismiss: () -> Void
    let dismiss: DismissAction

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("No Updates Found")
                    .font(.system(size: 13, weight: .semibold))

                Text("You're already running the latest version.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("OK") {
                    onDismiss()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}

fileprivate struct UpdateAvailableView: View {
    let installed: String
    let latest: String
    let onInstall: () -> Void
    let onDismiss: () -> Void
    let dismiss: DismissAction

    private let labelWidth: CGFloat = 70

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Update Available")
                        .font(.system(size: 13, weight: .semibold))

                    Text("term-mesh will quit, install via Homebrew, and relaunch automatically.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Current:")
                                .foregroundColor(.secondary)
                                .frame(width: labelWidth, alignment: .trailing)
                            Text(installed).monospaced()
                        }
                        HStack(spacing: 6) {
                            Text("Available:")
                                .foregroundColor(.secondary)
                                .frame(width: labelWidth, alignment: .trailing)
                            Text(latest).monospaced()
                        }
                    }
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Button("Later") {
                        onDismiss()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)

                    Spacer()

                    Button("Install and Restart") {
                        onInstall()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(16)

            if let notesURL = releaseNotesURL(for: latest) {
                Divider()
                releaseNotesLink(url: notesURL)
            }
        }
    }
}

fileprivate struct DownloadingView: View {
    let installed: String
    let latest: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Downloading Update")
                    .font(.system(size: 13, weight: .semibold))

                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(16)
    }
}

fileprivate struct ReadyToInstallView: View {
    let installed: String
    let latest: String
    let onInstall: () -> Void
    let onDismiss: () -> Void
    let dismiss: DismissAction

    private let labelWidth: CGFloat = 70

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Update Ready")
                        .font(.system(size: 13, weight: .semibold))

                    Text("term-mesh will quit, install via Homebrew, and relaunch automatically.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Current:")
                                .foregroundColor(.secondary)
                                .frame(width: labelWidth, alignment: .trailing)
                            Text(installed).monospaced()
                        }
                        HStack(spacing: 6) {
                            Text("Available:")
                                .foregroundColor(.secondary)
                                .frame(width: labelWidth, alignment: .trailing)
                            Text(latest).monospaced()
                        }
                    }
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Button("Later") {
                        onDismiss()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)

                    Spacer()

                    Button("Install and Restart") {
                        onInstall()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(16)

            if let notesURL = releaseNotesURL(for: latest) {
                Divider()
                releaseNotesLink(url: notesURL)
            }
        }
    }
}

fileprivate struct UpdateErrorView: View {
    let message: String
    let onRetry: () -> Void
    let onDismiss: () -> Void
    let dismiss: DismissAction

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 13))
                    Text("Update Failed")
                        .font(.system(size: 13, weight: .semibold))
                }

                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button("OK") {
                    onDismiss()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)

                Spacer()

                Button("Retry") {
                    onRetry()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}

private func releaseNotesURL(for version: String) -> URL? {
    let trimmed = version.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let tag = trimmed.hasPrefix("v") ? trimmed : "v\(trimmed)"
    return URL(string: "https://github.com/x-mesh/term-mesh/releases/tag/\(tag)")
}

@ViewBuilder
private func releaseNotesLink(url: URL) -> some View {
    Link(destination: url) {
        HStack {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
            Text("View Release Notes")
                .font(.system(size: 11, weight: .medium))
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10))
        }
        .foregroundColor(.primary)
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}
