import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class PeerHostHardeningTests: XCTestCase {
    func test_parse_loadedWithProtectSystemFull_isHardened() {
        let out = "LoadState=loaded\nPrivateTmp=yes\nNoNewPrivileges=no\nProtectSystem=full\n"
        XCTAssertEqual(PeerHostDoctor.parseHardeningStatus(out), .hardened)
    }

    func test_parse_loadedWithNoNewPrivilegesOnly_isHardened() {
        let out = "LoadState=loaded\nProtectSystem=no\nNoNewPrivileges=yes\n"
        XCTAssertEqual(PeerHostDoctor.parseHardeningStatus(out), .hardened)
    }

    func test_parse_loadedWithoutHardening_isNotHardened() {
        let out = "LoadState=loaded\nPrivateTmp=no\nNoNewPrivileges=no\nProtectSystem=no\n"
        XCTAssertEqual(PeerHostDoctor.parseHardeningStatus(out), .notHardened)
    }

    func test_parse_notFound_isUnknown() {
        let out = "LoadState=not-found\nProtectSystem=no\nNoNewPrivileges=no\n"
        XCTAssertEqual(PeerHostDoctor.parseHardeningStatus(out), .unknown)
    }

    func test_parse_emptyOutput_isUnknown() {
        XCTAssertEqual(PeerHostDoctor.parseHardeningStatus(""), .unknown)
        XCTAssertEqual(PeerHostDoctor.parseHardeningStatus("\n\n"), .unknown)
    }

    /// systemd 219 (CentOS 7) has no NoNewPrivileges property and may print
    /// unrelated lines; only the keys we know decide.
    func test_parse_systemd219Shape_ignoresUnknownLinesAndMissingKeys() {
        let out = "PrivateTmp=yes\nLoadState=loaded\nProtectSystem=strict\nSomethingNew=1\nnot a key value line\n"
        XCTAssertEqual(PeerHostDoctor.parseHardeningStatus(out), .hardened)
        let plain = "LoadState=loaded\nPrivateTmp=no\nProtectSystem=no\n"
        XCTAssertEqual(PeerHostDoctor.parseHardeningStatus(plain), .notHardened)
    }

    func test_probeCommand_hasNoSingleQuoteInsideBodyAndNoValueFlag() {
        let cmd = PeerHostDoctor.hardeningProbeCommand
        XCTAssertTrue(cmd.hasPrefix("sh -c '"))
        XCTAssertTrue(cmd.hasSuffix("'"))
        let body = String(cmd.dropFirst("sh -c '".count).dropLast(1))
        XCTAssertFalse(body.contains("'"))
        XCTAssertFalse(body.contains("--value"))
    }

    func test_installCommand_hardenTrueAndFalse_useEnvPrefix() {
        let url = PeerHostDoctor.installScriptURL
        XCTAssertEqual(
            PeerHostDoctor.installCommand(harden: true),
            "curl -fsSL \(url) | env TERMMESH_INSTALL_HARDEN=1 bash"
        )
        XCTAssertEqual(
            PeerHostDoctor.installCommand(harden: false),
            "curl -fsSL \(url) | env TERMMESH_INSTALL_HARDEN=0 bash"
        )
    }

    func test_installCommand_constantIsUnchanged() {
        XCTAssertEqual(
            PeerHostDoctor.installCommand,
            "curl -fsSL \(PeerHostDoctor.installScriptURL) | bash"
        )
    }
}
