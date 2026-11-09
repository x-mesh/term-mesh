import Foundation
import UniformTypeIdentifiers

/// A URL supplied by terminal output (an OSC 8 hyperlink or a link the
/// terminal detected in plain text). It must not reach Launch Services
/// directly: a program could print `file:///System/Applications/Calculator.app`
/// or hide a custom-scheme target behind OSC 8 link text.
///
/// Ported from ghostty-org macOS `UntrustedURL` (#14683). term-mesh differs in
/// one place: a script opens in the source-code editor instead of being
/// blocked, because agents print paths such as `./build.sh` that users open to
/// read. The file's own default handler is not used for scripts, since it can
/// be a terminal or launcher that runs them.
struct UntrustedURL: Equatable {
    enum DenialReason: Equatable {
        case malformedURL
        case unsafeCharacters
        case invalidWebURL
        case inaccessibleFile
        case unsafeFile

        var message: String {
            switch self {
            case .malformedURL:
                "The target is not an absolute URL with a scheme."
            case .unsafeCharacters:
                "The target contains invisible or line-breaking characters."
            case .invalidWebURL:
                "The web target does not contain a valid host."
            case .inaccessibleFile:
                "The local target does not exist or is not a regular file or directory."
            case .unsafeFile:
                "Opening this local target could execute code."
            }
        }
    }

    enum Decision: Equatable {
        /// Open schemes with non-executing, well-understood behavior directly.
        case allow(URL)

        /// Open a local script in a source-code editor, never its default handler.
        case openInEditor(URL)

        /// Ask before dispatching a custom scheme to its registered handler.
        case confirm(URL)

        /// Never dispatch malformed targets or executable local files.
        case deny(DenialReason)
    }

    let string: String

    init(_ string: String) {
        self.string = string
    }

    var decision: Decision {
        guard !string.isEmpty else { return .deny(.malformedURL) }

        // Foundation accepts many Unicode control and formatting characters in
        // a URL. UI frameworks can render those same characters as line breaks,
        // zero-width text, or bidirectional overrides, so reject them before
        // parsing changes their representation.
        guard !Self.containsUnsafeCharacters(string) else {
            return .deny(.unsafeCharacters)
        }

        // URL(string:) also accepts relative references. An untrusted target
        // must include an explicit scheme so it cannot be reinterpreted as a
        // local path by a later layer.
        guard
            let url = URL(string: string),
            let scheme = url.scheme?.lowercased(),
            !scheme.isEmpty
        else {
            return .deny(.malformedURL)
        }

        switch scheme {
        case "http", "https":
            // Reject values such as "https:relative". They have a scheme, but
            // no authority, and different consumers may resolve them against a
            // base URL differently.
            guard let host = url.host, !host.isEmpty else {
                return .deny(.invalidWebURL)
            }
            return .allow(url)

        case "mailto":
            // URLComponents places the address portion of a mailto URL in the
            // path. Require one so a bare "mailto:" cannot dispatch an empty
            // request to the user's mail application.
            guard
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                !components.path.isEmpty
            else {
                return .deny(.malformedURL)
            }
            return .allow(url)

        case "file":
            return fileDecision(for: url)

        default:
            // A custom scheme can invoke any application registered with
            // Launch Services. The caller must show the target and handler
            // before allowing that dispatch.
            return .confirm(url)
        }
    }

    /// Whether `value` contains control, invisible, or text-reversing
    /// characters. Use this to check a value before converting it to a URL,
    /// since conversion can percent-encode these characters.
    static func containsUnsafeCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains(where: isUnsafeCharacter)
    }

    /// A single-line representation of the effective target. Paths are
    /// standardized before display so traversal and repeated separators cannot
    /// cause the visible and opened targets to differ.
    var displayString: String {
        let normalized: String
        if let url = URL(string: string), url.scheme != nil {
            // File URLs are standardized exactly as they are before opening,
            // including symlink resolution. Keep non-file URLs byte-for-byte
            // equivalent because repeated separators can be meaningful to a
            // web or custom-scheme handler.
            normalized = url.isFileURL
                ? url.standardizedFileURL.resolvingSymlinksInPath().path
                : string
        } else {
            // Scheme-less values are never allowed to open, but they still
            // appear in the blocked-target UI. Standardizing them prevents
            // slash padding and dot traversal from hiding the effective path.
            normalized = URL(filePath: string).standardizedFileURL.path
        }

        // Escaping happens after normalization so any unsafe scalar that
        // remains is visible as text and cannot create a second display line.
        var result = String()
        result.reserveCapacity(normalized.count)
        for scalar in normalized.unicodeScalars {
            if Self.isUnsafeCharacter(scalar) {
                result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }

        return result
    }
}

private extension UntrustedURL {
    func fileDecision(for url: URL) -> Decision {
        // Only local file URLs are meaningful here. Queries and fragments do
        // not identify part of a filesystem object and may be interpreted
        // inconsistently by Launch Services handlers.
        guard url.isFileURL, url.query == nil, url.fragment == nil else {
            return .deny(.malformedURL)
        }

        // An empty host and localhost both refer to this machine. Do not allow
        // file URLs that name a remote host and could trigger network access.
        if let host = url.host,
           !host.isEmpty,
           host.caseInsensitiveCompare("localhost") != .orderedSame {
            return .deny(.malformedURL)
        }

        // The raw-text check above cannot see percent-encoded characters, and
        // Launch Services receives the decoded name, so check that name too.
        guard !Self.containsUnsafeCharacters(url.path) else {
            return .deny(.unsafeCharacters)
        }

        // Classify the effective object, not the spelling supplied by terminal
        // output. This collapses dot traversal and prevents a harmless-looking
        // symlink name from hiding an executable target.
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        // A symlink with a plain name can point at a name that hides
        // characters, and the target is what Launch Services opens.
        guard !Self.containsUnsafeCharacters(canonicalURL.path) else {
            return .deny(.unsafeCharacters)
        }
        let resourceValues: URLResourceValues
        do {
            // Reading all relevant resource keys together also proves that the
            // canonical target exists and is accessible.
            resourceValues = try canonicalURL.resourceValues(forKeys: [
                .contentTypeKey,
                .isDirectoryKey,
                .isExecutableKey,
                .isRegularFileKey,
            ])
        } catch {
            return .deny(.inaccessibleFile)
        }

        // Exclude devices, sockets, and other special filesystem objects. A
        // directory is safe to reveal in Finder unless its extension or UTI
        // identifies it as an application bundle.
        guard resourceValues.isDirectory == true || resourceValues.isRegularFile == true else {
            return .deny(.inaccessibleFile)
        }
        return Self.localFileDecision(canonicalURL, resourceValues: resourceValues)
    }

    static func localFileDecision(
        _ url: URL,
        resourceValues: URLResourceValues
    ) -> Decision {
        // Launch Services uses extensions when choosing a handler. Block known
        // executable containers even when their POSIX executable bit is clear.
        // `.command` and `.tool` are scripts that Terminal runs on open.
        if unsafePathExtensions.contains(url.pathExtension.lowercased()) {
            return .deny(.unsafeFile)
        }

        let contentType = resourceValues.contentType
        if let contentType, contentType.conforms(to: .application) {
            return .deny(.unsafeFile)
        }

        // A script is text; reading it is safe as long as the handler is an
        // editor. Its executable bit does not matter for that.
        if resourceValues.isDirectory != true, let contentType, contentType.conforms(to: .script) {
            return .openInEditor(url)
        }

        if let contentType, contentType.conforms(to: .executable) {
            return .deny(.unsafeFile)
        }

        // Reject any other regular file the filesystem marks executable,
        // regardless of its name or detected content type.
        if resourceValues.isDirectory != true, resourceValues.isExecutable == true {
            return .deny(.unsafeFile)
        }

        return .allow(url)
    }

    static func isUnsafeCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        // C0/C1 controls include CR, LF, NEL, and other non-printing bytes.
        case 0x00...0x1F, 0x7F...0x9F:
            return true

        // Directional marks and zero-width characters can reorder or conceal
        // portions of the target without changing what the handler receives.
        case 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true

        // Unicode line/paragraph separators create additional visual lines in
        // SwiftUI and AppKit text even though OSC accepts their UTF-8 bytes.
        case 0x2028...0x2029:
            return true

        // Word Joiner and BOM are invisible formatting characters that can be
        // used as padding or to disguise otherwise identical-looking targets.
        case 0x2060, 0xFEFF:
            return true

        default:
            return false
        }
    }

    static let unsafePathExtensions: Set<String> = [
        "action",
        "app",
        "applescript",
        "class",
        "command",
        "desktop",
        "inetloc",
        "jar",
        "mobileconfig",
        "mpkg",
        "pkg",
        "scpt",
        "terminal",
        "tool",
        "url",
        "webloc",
        "workflow",
    ]
}
