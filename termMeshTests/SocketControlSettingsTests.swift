import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class SocketControlSettingsTests: XCTestCase {

    // MARK: - Tagged debug bundle id → isolated socket path

    func test_tagged_debug_returns_tagged_sock() {
        let path = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: "com.termmesh.app.debug.foo",
            isDebugBuild: false
        )
        XCTAssertEqual(path, "/tmp/term-mesh-debug-foo.sock")
    }

    func test_tagged_debug_hyphenated_tag() {
        let path = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: "com.termmesh.app.debug.fix-blur-effect",
            isDebugBuild: false
        )
        XCTAssertEqual(path, "/tmp/term-mesh-debug-fix-blur-effect.sock")
    }

    func test_untagged_debug_regression() {
        // com.termmesh.app.debug (no suffix) must still return the untagged path.
        let path = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: "com.termmesh.app.debug",
            isDebugBuild: false
        )
        XCTAssertEqual(path, "/tmp/term-mesh-debug.sock")
    }

    func test_production_unaffected() {
        let path = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: "com.termmesh.app",
            isDebugBuild: false
        )
        XCTAssertEqual(path, "/tmp/term-mesh.sock")
    }

    func test_tagged_staging_returns_tagged_sock() {
        let path = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: "com.termmesh.app.staging.my-feature",
            isDebugBuild: false
        )
        XCTAssertEqual(path, "/tmp/term-mesh-staging-my-feature.sock")
    }
}
