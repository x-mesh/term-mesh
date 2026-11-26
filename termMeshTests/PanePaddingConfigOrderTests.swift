import XCTest
import GhosttyKit

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// term-mesh snaps each terminal to whole rows on the assumption that Ghostty
/// adds no vertical padding of its own. That held only while the user's Ghostty
/// config said nothing: `window-padding-y = 10,10` there took two rows back out
/// of every pane and left the remainder under the prompt, whatever Settings >
/// Pane Padding said.
final class PanePaddingConfigOrderTests: XCTestCase {
    private static let userConfig = """
    window-padding-y = 10,10
    window-padding-x = 10,10
    window-padding-balance = true
    """

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pane-padding-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func test_overrideLoadedAfterTheUserConfigOwnsPanePadding() throws {
        let padding = try loadedPadding(layers: [
            Self.userConfig,
            GhosttyApp.panePaddingOverrideContents(horizontal: 6),
        ])

        XCTAssertEqual(padding.y.top_left, 0)
        XCTAssertEqual(padding.y.bottom_right, 0)
        XCTAssertEqual(padding.x.top_left, 6)
        XCTAssertEqual(padding.x.bottom_right, 6)
        XCTAssertEqual(padding.balance, "false")
    }

    func test_overrideLoadedBeforeTheUserConfigLosesToIt() throws {
        let padding = try loadedPadding(layers: [
            GhosttyApp.panePaddingOverrideContents(horizontal: 6),
            Self.userConfig,
        ])

        XCTAssertEqual(padding.y.top_left, 10)
        XCTAssertEqual(padding.y.bottom_right, 10)
        XCTAssertEqual(padding.balance, "true")
    }

    private struct LoadedPadding {
        var x = ghostty_config_window_padding_s()
        var y = ghostty_config_window_padding_s()
        var balance = ""
    }

    private func loadedPadding(layers: [String]) throws -> LoadedPadding {
        let config = try XCTUnwrap(ghostty_config_new())
        defer { ghostty_config_free(config) }

        for (index, contents) in layers.enumerated() {
            let url = directory.appendingPathComponent("layer-\(index).ghostty")
            try contents.write(to: url, atomically: true, encoding: .utf8)
            url.path.withCString { ghostty_config_load_file(config, $0) }
        }
        ghostty_config_finalize(config)

        var loaded = LoadedPadding()
        XCTAssertTrue(get(config, "window-padding-x", into: &loaded.x))
        XCTAssertTrue(get(config, "window-padding-y", into: &loaded.y))
        var balance: UnsafePointer<CChar>?
        XCTAssertTrue(get(config, "window-padding-balance", into: &balance))
        loaded.balance = try String(cString: XCTUnwrap(balance))
        return loaded
    }

    private func get<Value>(_ config: ghostty_config_t, _ key: String, into value: inout Value) -> Bool {
        ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8)))
    }
}
