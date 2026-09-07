import XCTest
import Foundation

final class SidebarProjectCleanupUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testHostRestartMenuStaysEnglishInKoreanLocale() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(ko)",
            "-AppleLocale", "ko_KR",
        ]
        app.launch()
        app.activate()

        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalog = project.appendingPathComponent("Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: catalog),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = json["strings"] as? [String: Any],
              let entry = strings["Restart Host Daemon…"] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any],
              let korean = localizations["ko"] as? [String: Any],
              let unit = korean["stringUnit"] as? [String: Any]
        else { return XCTFail("Expected the Restart Host Daemon catalog entry") }
        XCTAssertEqual(unit["value"] as? String, "Restart Host Daemon…")
    }
}
