import Foundation
import AppKit
import SwiftUI

/// Fetches GitHub release notes for the brew cask source repo and caches them
/// in memory for the lifetime of the app. Pre-fetched while the user is still
/// in `.readyToInstall` so the NSAlert can show notes immediately on click.
@MainActor
final class BrewReleaseNotesService {
    static let shared = BrewReleaseNotesService()

    /// Repo where DMGs and tagged releases live (matches the brew cask `url`).
    nonisolated static let defaultRepo = "x-mesh/term-mesh"

    private var cache: [String: String] = [:]
    private var inflight: [String: Task<String?, Never>] = [:]

    func cachedNotes(for version: String) -> String? {
        cache[normalize(version)]
    }

    @discardableResult
    func notes(for version: String, repo: String = BrewReleaseNotesService.defaultRepo) async -> String? {
        let key = normalize(version)
        if let cached = cache[key] { return cached }
        if let existing = inflight[key] { return await existing.value }

        let task = Task<String?, Never> { [weak self] in
            let result = await Self.fetch(tag: key, repo: repo)
            await MainActor.run {
                self?.inflight.removeValue(forKey: key)
                if let result = result, !result.isEmpty {
                    self?.cache[key] = result
                }
            }
            return result
        }
        inflight[key] = task
        return await task.value
    }

    private func normalize(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("v") ? trimmed : "v\(trimmed)"
    }

    private static func fetch(tag: String, repo: String) async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/tags/\(tag)") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("term-mesh-brew-update", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                UpdateLogStore.shared.append("brew release notes: http \( (response as? HTTPURLResponse)?.statusCode ?? -1) for \(tag)")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = json["body"] as? String else {
                UpdateLogStore.shared.append("brew release notes: missing body field for \(tag)")
                return nil
            }
            return body
        } catch {
            UpdateLogStore.shared.append("brew release notes: fetch error for \(tag) — \(error.localizedDescription)")
            return nil
        }
    }
}

/// SwiftUI view embedded into NSAlert's accessoryView. Renders the release
/// body line-by-line so newlines and headings stay visually distinct —
/// `AttributedString(markdown:)` with `.full` looked nice in source but
/// SwiftUI's Text collapsed blocks into one long inline run.
struct BrewReleaseNotesAccessoryView: View {
    let markdown: String
    let version: String
    let releaseURL: URL?

    private struct Line: Identifiable {
        let id: Int
        let kind: Kind

        enum Kind {
            case blank
            case heading(text: String, level: Int)
            case bullet(text: String, indent: Int)
            case body(text: String)
        }
    }

    private var parsedLines: [Line] {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .enumerated()
            .map { index, raw in
                Line(id: index, kind: classify(raw))
            }
    }

    private func classify(_ raw: String) -> Line.Kind {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .blank }
        if trimmed.hasPrefix("### ") { return .heading(text: String(trimmed.dropFirst(4)), level: 3) }
        if trimmed.hasPrefix("## ")  { return .heading(text: String(trimmed.dropFirst(3)), level: 2) }
        if trimmed.hasPrefix("# ")   { return .heading(text: String(trimmed.dropFirst(2)), level: 1) }
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            // Preserve indent (2 spaces per level).
            let leading = raw.prefix { $0 == " " }.count
            let indent = leading / 2
            return .bullet(text: String(trimmed.dropFirst(2)), indent: indent)
        }
        return .body(text: raw)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Release Notes")
                    .font(.system(size: 11, weight: .semibold))
                Text(version)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                if let releaseURL {
                    Link(destination: releaseURL) {
                        HStack(spacing: 4) {
                            Text("View on GitHub")
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(parsedLines) { line in
                        view(for: line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .textSelection(.enabled)
            }
            .frame(height: 220)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
        .frame(width: 420)
    }

    @ViewBuilder
    private func view(for line: Line) -> some View {
        switch line.kind {
        case .blank:
            Color.clear.frame(height: 6)
        case let .heading(text, level):
            Text(text)
                .font(.system(size: headingSize(for: level), weight: .semibold))
                .padding(.top, level == 1 ? 6 : 4)
                .padding(.bottom, 2)
        case let .bullet(text, indent):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                inlineMarkdownText(text)
            }
            .padding(.leading, CGFloat(indent) * 12)
        case let .body(text):
            inlineMarkdownText(text)
        }
    }

    private func headingSize(for level: Int) -> CGFloat {
        switch level {
        case 1: return 13
        case 2: return 12
        default: return 11
        }
    }

    @ViewBuilder
    private func inlineMarkdownText(_ raw: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            Text(attributed)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(raw)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension BrewReleaseNotesAccessoryView {
    /// Wrap in an NSHostingView sized for NSAlert.accessoryView.
    static func nsHostingView(markdown: String, version: String, releaseURL: URL?) -> NSView {
        let view = NSHostingView(rootView: BrewReleaseNotesAccessoryView(
            markdown: markdown,
            version: version,
            releaseURL: releaseURL
        ))
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 260)
        return view
    }
}
