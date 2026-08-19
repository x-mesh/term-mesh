import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Prefilling a GitHub issue form fails silently: a value GitHub cannot match
/// to a dropdown option is dropped, and the field simply renders empty. There
/// is no error to notice, so the checks that matter are the ones that compare
/// against the template itself.
final class GitHubIssueDraftTests: XCTestCase {
    private func draft(diagnostics: String = "diag") -> GitHubIssueDraft {
        GitHubIssueDraft(
            appVersion: "0.196.0",
            buildNumber: "264",
            macOSVersion: "Version 15.3 (Build 24D60)",
            chip: .appleSilicon,
            installMethod: .homebrew,
            shellInfo: "SHELL=/bin/zsh",
            diagnostics: diagnostics
        )
    }

    private func queryItems(_ url: URL) -> [String: String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var found: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            found[item.name] = item.value
        }
        return found
    }

    /// The repository's issue template, read from the source tree. A literal
    /// copy of the option strings in this test would pass forever while the
    /// template drifted underneath it.
    private func templateSource() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()  // termMeshTests
        url.deleteLastPathComponent()  // repo root
        url.appendPathComponent(".github/ISSUE_TEMPLATE/bug_report.yml")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func test_dropdownValuesMatchTheIssueTemplate() throws {
        let template = try templateSource()
        for chip in [GitHubIssueDraft.Chip.appleSilicon, .intel] {
            XCTAssertTrue(
                template.contains(chip.rawValue),
                "chip option \(chip.rawValue) is not in bug_report.yml — GitHub will drop it silently"
            )
        }
        for method in [
            GitHubIssueDraft.InstallMethod.homebrew,
            .directDownload,
            .builtFromSource,
        ] {
            XCTAssertTrue(
                template.contains(method.rawValue),
                "install option \(method.rawValue) is not in bug_report.yml"
            )
        }
    }

    /// Every field the draft prefills must exist in the template, or the value
    /// goes nowhere.
    func test_prefilledFieldIdsExistInTheTemplate() throws {
        let template = try templateSource()
        let url = try XCTUnwrap(draft().url())
        for name in queryItems(url).keys where name != "template" {
            XCTAssertTrue(
                template.contains("id: \(name)"),
                "\(name) is prefilled but has no matching field id in bug_report.yml"
            )
        }
    }

    // MARK: - The human half stays human

    /// These three are what a bug report is always missing and what no probe
    /// can answer. Prefilling them with a guess would be worse than leaving
    /// them blank.
    func test_theQuestionsOnlyAPersonCanAnswerAreLeftBlank() throws {
        let url = try XCTUnwrap(draft().url())
        let items = queryItems(url)
        XCTAssertNil(items["description"])
        XCTAssertNil(items["expected"])
        XCTAssertNil(items["steps"])
    }

    /// Pixels cannot be redacted. The app never fills this field, and this
    /// test is here so that stays a decision rather than an oversight.
    func test_screenshotsFieldIsNeverPrefilled() throws {
        let url = try XCTUnwrap(draft(diagnostics: String(repeating: "x", count: 50)).url())
        XCTAssertNil(queryItems(url)["screenshots"])
    }

    // MARK: - Budget

    func test_urlStaysWithinBudgetWithAHugeBundle() throws {
        let huge = String(repeating: "diagnostic line\n", count: 5000)
        let url = try XCTUnwrap(draft(diagnostics: huge).url())
        XCTAssertLessThanOrEqual(url.absoluteString.utf8.count, GitHubIssueDraft.maxURLBytes)
    }

    /// A truncated bundle has to say so, and say where the rest is — otherwise
    /// the reader treats a partial report as a complete one.
    func test_truncatedBundleCarriesAPointerToTheRest() throws {
        let huge = String(repeating: "diagnostic line\n", count: 5000)
        let url = try XCTUnwrap(draft(diagnostics: huge).url())
        let logs = try XCTUnwrap(queryItems(url)["logs"])
        XCTAssertTrue(logs.contains("truncated"))
        XCTAssertTrue(logs.contains("clipboard"))
    }

    func test_shortBundleIsCarriedWhole() throws {
        let url = try XCTUnwrap(draft(diagnostics: "short bundle").url())
        XCTAssertEqual(queryItems(url)["logs"], "short bundle")
    }

    /// Non-ASCII is where a naive "cut the encoded string" implementation
    /// breaks: a cut inside a `%E1%84` escape produces a malformed URL.
    func test_multibyteBundleStillProducesAValidURL() throws {
        let korean = String(repeating: "진단 정보 한 줄\n", count: 3000)
        let url = try XCTUnwrap(draft(diagnostics: korean).url())
        XCTAssertLessThanOrEqual(url.absoluteString.utf8.count, GitHubIssueDraft.maxURLBytes)
        XCTAssertNotNil(URL(string: url.absoluteString))
    }

    func test_fittedLeavesTextThatAlreadyFits() {
        XCTAssertEqual(GitHubIssueDraft.fitted("abc", encodedBudget: 100), "abc")
    }

    // MARK: - Environment detection

    func test_buildDirectoryIsReportedAsBuiltFromSource() {
        XCTAssertEqual(
            GitHubIssueDraft.detectedInstallMethod(
                bundlePath: "/Users/x/Library/Developer/Xcode/DerivedData/GhosttyTabs-abc/Build/Products/Debug/term-mesh DEV.app"
            ),
            .builtFromSource
        )
    }

    func test_applicationsWithoutACaskroomIsADirectDownload() {
        XCTAssertEqual(
            GitHubIssueDraft.detectedInstallMethod(
                bundlePath: "/Applications/term-mesh.app",
                caskroomPaths: ["/nonexistent/Caskroom/term-mesh"]
            ),
            .directDownload
        )
    }

    func test_applicationsWithACaskroomIsHomebrew() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("caskroom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(
            GitHubIssueDraft.detectedInstallMethod(
                bundlePath: "/Applications/term-mesh.app",
                caskroomPaths: [dir.path]
            ),
            .homebrew
        )
    }

    func test_shellInfoNamesTheShellAndAnyMultiplexer() {
        let info = GitHubIssueDraft.detectedShellInfo(
            environment: ["SHELL": "/bin/zsh", "TMUX": "/tmp/tmux-501/default,1,0", "TERM": "xterm-256color"]
        )
        XCTAssertTrue(info.contains("/bin/zsh"))
        XCTAssertTrue(info.contains("tmux"))
        XCTAssertTrue(info.contains("xterm-256color"))
    }

    func test_shellInfoSaysUnknownRatherThanGoingEmpty() {
        XCTAssertTrue(GitHubIssueDraft.detectedShellInfo(environment: [:]).contains("unknown"))
    }
}
