import SwiftUI

struct WelcomeView: View {
    @AppStorage("hideWelcomeScreen") private var hideWelcomeScreen: Bool = false
    let onGetStarted: () -> Void

    private let shortcuts: [(key: String, description: String)] = [
        ("⌘T", "New Tab"),
        ("⌘D", "Split Right"),
        ("⌘⇧D", "Split Down"),
        ("⌘⇧I", "IME Input Bar"),
        ("⌘⇧T", "New Team"),
        ("⌘W", "Close Tab"),
    ]

    var body: some View {
        VStack(spacing: 24) {
            // App icon
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .renderingMode(.original)
                .frame(width: 80, height: 80)
                .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 2)

            // Branding
            VStack(spacing: 6) {
                Text("term-mesh")
                    .font(.system(size: 32, weight: .semibold, design: .default))
                    .foregroundColor(.black)
                Text("Terminal Multiplexer for macOS")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.gray)
            }

            Divider()
                .frame(maxWidth: 400)

            // Shortcuts grid
            VStack(alignment: .leading, spacing: 8) {
                Text("Keyboard Shortcuts")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.gray)
                    .textCase(.uppercase)
                    .tracking(0.5)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(shortcuts, id: \.key) { shortcut in
                        ShortcutRow(key: shortcut.key, description: shortcut.description)
                    }
                }
            }
            .frame(maxWidth: 400)

            // Get Started button
            Button(action: onGetStarted) {
                Text("Get Started")
                    .font(.system(size: 13, weight: .medium))
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: [])

            // Don't show again
            Toggle(isOn: $hideWelcomeScreen) {
                Text("Don't show again")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }
            .toggleStyle(.checkbox)
        }
        .padding(40)
        .background(Color.white)
    }
}

private struct ShortcutRow: View {
    let key: String
    let description: String

    var body: some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.15))
                )
            Text(description)
                .font(.system(size: 12))
                .foregroundColor(.gray)
            Spacer()
        }
    }
}
