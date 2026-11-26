import XCTest
import GhosttyKit

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Shell integration's `cursor` feature sets a bar at every prompt, which
/// Ghostty keeps over `cursor-style`. A Settings cursor style must turn that
/// feature off without resetting the other features the user configured.
final class CursorShellIntegrationOverrideTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-shell-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func test_overrideTurnsOffCursorAndKeepsTheUserFeatures() throws {
        let userConfig = "shell-integration-features = ssh-env,ssh-terminfo,sudo,no-title"
        let before = try loadedFeatures(layers: [userConfig])
        XCTAssertEqual(before & 1, 1, "cursor is on by Ghostty default")

        let after = try loadedFeatures(layers: [userConfig], applyingOverride: true)

        XCTAssertEqual(after, before & ~1)
    }

    func test_overrideKeepsGhosttyDefaultsWhenTheUserSetsNothing() throws {
        let before = try loadedFeatures(layers: [])
        let after = try loadedFeatures(layers: [], applyingOverride: true)

        XCTAssertEqual(after, before & ~1)
    }

    func test_contentsNameEveryFeatureExplicitly() {
        let contents = GhosttyApp.cursorShellIntegrationOverrideContents(features: 0b101001)

        XCTAssertTrue(contents.contains(
            "shell-integration-features = no-cursor,no-sudo,no-title,ssh-env,no-ssh-terminfo,path"
        ))
    }

    private func loadedFeatures(layers: [String], applyingOverride: Bool = false) throws -> UInt32 {
        let config = try XCTUnwrap(ghostty_config_new())
        defer { ghostty_config_free(config) }

        var all = layers
        for (index, contents) in all.enumerated() {
            try load(contents, index: index, into: config)
        }
        if applyingOverride {
            let override = try XCTUnwrap(GhosttyApp.cursorShellIntegrationOverrideContents(config: config))
            all.append(override)
            try load(override, index: all.count - 1, into: config)
        }
        ghostty_config_finalize(config)
        XCTAssertEqual(ghostty_config_diagnostics_count(config), 0)

        var bits: UInt32 = 0
        let key = "shell-integration-features"
        XCTAssertTrue(ghostty_config_get(config, &bits, key, UInt(key.lengthOfBytes(using: .utf8))))
        return bits
    }

    private func load(_ contents: String, index: Int, into config: ghostty_config_t) throws {
        let url = directory.appendingPathComponent("layer-\(index).ghostty")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        url.path.withCString { ghostty_config_load_file(config, $0) }
    }
}
