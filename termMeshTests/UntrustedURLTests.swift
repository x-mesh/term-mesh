import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Ported from ghostty-org macOS `UntrustedURLTests` (#14683). Scripts are the
/// term-mesh difference: they open in an editor instead of being blocked.
final class UntrustedURLTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeFile(_ name: String, _ contents: String = "#!/bin/sh\n", mode: Int? = nil) throws -> URL {
        let file = directory.appending(path: name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        if let mode {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }
        return file
    }

    func testAllowsSafeSchemes() {
        for value in ["http://example.com", "https://example.com/path", "mailto:user@example.com"] {
            guard case .allow(let url) = UntrustedURL(value).decision else {
                XCTFail("expected \(value) to be allowed")
                continue
            }
            XCTAssertEqual(url.absoluteString, value)
        }
    }

    func testRejectsWebURLsWithoutHosts() {
        for value in ["https:relative", "http:///missing-host"] {
            XCTAssertEqual(UntrustedURL(value).decision, .deny(.invalidWebURL), value)
        }
    }

    func testRejectsSchemeLessTargets() {
        for value in ["/tmp/file.txt", "../file.txt", "payload.command"] {
            XCTAssertEqual(UntrustedURL(value).decision, .deny(.malformedURL), value)
        }
    }

    func testConfirmsCustomSchemes() {
        for value in ["vscode://file/tmp/example.swift", "ssh://example.com"] {
            guard case .confirm(let url) = UntrustedURL(value).decision else {
                XCTFail("expected \(value) to need confirmation")
                continue
            }
            XCTAssertEqual(url.absoluteString, value)
        }
    }

    func testRejectsInvisibleAndLineBreakingCharacters() {
        for scalar in ["\u{0085}", "\u{2028}", "\u{2029}", "\u{202E}", "\u{2066}"] {
            let value = "https://example.com/before\(scalar)after"
            XCTAssertEqual(UntrustedURL(value).decision, .deny(.unsafeCharacters))
            XCTAssertTrue(UntrustedURL.containsUnsafeCharacters(value))
        }
    }

    func testAllowsNonExecutableLocalFiles() throws {
        let file = try writeFile("document.txt", "safe")
        XCTAssertEqual(
            UntrustedURL(file.absoluteString).decision,
            .allow(file.standardizedFileURL.resolvingSymlinksInPath())
        )
    }

    func testAllowsDirectories() {
        guard case .allow = UntrustedURL(directory.absoluteString).decision else {
            return XCTFail("expected a directory to be allowed")
        }
    }

    func testRejectsDangerousLocalFileExtensions() throws {
        for name in ["payload.command", "payload.tool", "payload.app", "payload.workflow"] {
            let file = try writeFile(name)
            XCTAssertEqual(UntrustedURL(file.absoluteString).decision, .deny(.unsafeFile), name)
        }
    }

    func testRejectsApplicationBundles() throws {
        let bundle = directory.appending(path: "Payload.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        XCTAssertEqual(UntrustedURL(bundle.absoluteString).decision, .deny(.unsafeFile))
    }

    func testOpensScriptsInEditorEvenWhenExecutable() throws {
        for (name, mode) in [("build.sh", 0o755), ("tool.py", 0o644), ("task.rb", 0o755)] {
            let file = try writeFile(name, mode: mode)
            XCTAssertEqual(
                UntrustedURL(file.absoluteString).decision,
                .openInEditor(file.standardizedFileURL.resolvingSymlinksInPath()),
                name
            )
        }
    }

    func testRejectsExecutableFilesRegardlessOfExtension() throws {
        let file = try writeFile("payload.txt", mode: 0o755)
        XCTAssertEqual(UntrustedURL(file.absoluteString).decision, .deny(.unsafeFile))
    }

    func testRejectsExecutableBinaries() throws {
        let file = directory.appending(path: "payload")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: file)
        XCTAssertEqual(UntrustedURL(file.absoluteString).decision, .deny(.unsafeFile))
    }

    func testResolvesSymlinksBeforeClassifyingFiles() throws {
        let payload = try writeFile("payload.command")
        let link = directory.appending(path: "document.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: payload)
        XCTAssertEqual(UntrustedURL(link.absoluteString).decision, .deny(.unsafeFile))
    }

    func testRejectsPercentEncodedUnsafeCharactersInFileNames() throws {
        let file = try writeFile("report\u{202E}txt.sh", "safe")
        let encoded = "file://" + file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        XCTAssertFalse(UntrustedURL.containsUnsafeCharacters(encoded))
        XCTAssertEqual(UntrustedURL(encoded).decision, .deny(.unsafeCharacters))
    }

    func testRejectsSymlinksToNamesWithUnsafeCharacters() throws {
        let target = try writeFile("report\u{202E}txt.sh", "safe")
        let link = directory.appending(path: "notes.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(UntrustedURL(link.absoluteString).decision, .deny(.unsafeCharacters))
    }

    func testRejectsFileURLsWithQueryOrFragment() throws {
        let file = try writeFile("document.txt", "safe")
        for suffix in ["?open=1", "#section"] {
            XCTAssertEqual(UntrustedURL(file.absoluteString + suffix).decision, .deny(.malformedURL), suffix)
        }
    }

    func testRejectsFileURLsNamingRemoteHosts() {
        XCTAssertEqual(UntrustedURL("file://example.com/tmp/file.txt").decision, .deny(.malformedURL))
    }

    func testRejectsMissingFiles() {
        let missing = directory.appending(path: "missing.txt")
        XCTAssertEqual(UntrustedURL(missing.absoluteString).decision, .deny(.inaccessibleFile))
    }

    func testPreviewShowsTheEffectiveStandardizedPath() {
        for separator in ["\u{0085}", "\u{2028}", "\u{2029}"] {
            let value = "/tmp/preview\(separator)////../payload.command////"
            XCTAssertEqual(UntrustedURL(value).displayString, "/tmp/payload.command")
        }
    }

    func testPreviewEscapesBidirectionalControls() {
        let value = "https://example.com/a\u{202E}b"
        XCTAssertEqual(UntrustedURL(value).displayString, "https://example.com/a\\u{202E}b")
    }
}
