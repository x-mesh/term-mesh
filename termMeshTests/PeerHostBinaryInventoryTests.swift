import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// The inventory probe exists because a host can look current and launch a
/// binary three versions old. Every assertion here is a shape that actually
/// occurred on the fleet.
final class PeerHostBinaryInventoryTests: XCTestCase {
    /// The probe rides inside `sh -c '…'`, like every other fixed command in
    /// PeerHostDoctor. A single quote in the body ends the quoting early and
    /// breaks the probe on every host.
    func test_command_hasNoSingleQuoteInsideBody() {
        let cmd = PeerHostDoctor.binaryInventoryCommand
        XCTAssertTrue(cmd.hasPrefix("sh -c '"), "expected sh -c '…' wrapper")
        XCTAssertTrue(cmd.hasSuffix("'"), "expected closing single quote")
        let body = String(cmd.dropFirst("sh -c '".count).dropLast(1))
        XCTAssertFalse(body.contains("'"), "probe body must not contain single quotes")
    }

    /// The probe has to search the same PATH the launcher does. Asking the
    /// login shell instead is what let a host answer "0.170.1" while every
    /// agent on it ran 0.167.0 out of $HOME/.local/bin.
    func test_command_searchesTheLaunchPathInOrder() {
        let cmd = PeerHostDoctor.binaryInventoryCommand
        guard let home = cmd.range(of: "$HOME/.local/bin"),
              let brew = cmd.range(of: "/opt/homebrew/bin")
        else {
            return XCTFail("the launch PATH directories must appear in the probe")
        }
        XCTAssertTrue(
            home.lowerBound < brew.lowerBound,
            "the probe must search in the launcher's order, or it reports a binary that never runs"
        )
        for dir in RemoteShellPath.binDirs {
            let needle = dir.hasPrefix("$HOME/") ? String(dir.dropFirst(6)) : dir
            XCTAssertTrue(cmd.contains(needle), "missing \(dir) from the probe PATH")
        }
    }

    /// jinwoo-macbook-pro-sub, exactly as found: a stale winner in
    /// $HOME/.local/bin and the current copy shadowed behind it.
    func test_parsesAWinnerAndTheCopiesItShadows() {
        let inventory = PeerHostDoctor.parseBinaryInventory("""
        os=Darwin
        ssh-user=jinwoo
        app=0.170.1
        tm-agent=/Users/jinwoo/.local/bin/tm-agent|tm-agent 0.167.0
        tm-agent.shadowed=/opt/homebrew/bin/tm-agent|tm-agent 0.170.1
        """)
        XCTAssertEqual(inventory.appVersion, "0.170.1")
        XCTAssertEqual(inventory.hostOS, "Darwin")
        XCTAssertEqual(inventory.sshUser, "jinwoo")
        XCTAssertEqual(inventory.cli?.path, "/Users/jinwoo/.local/bin/tm-agent")
        XCTAssertEqual(inventory.cli?.version, "tm-agent 0.167.0")
        XCTAssertEqual(inventory.cliShadowed.count, 1)
        XCTAssertEqual(inventory.cliShadowed.first?.version, "tm-agent 0.170.1")
    }

    func test_reportsWhenSSHAndDaemonAccountsDifferOnLinux() {
        let warnings = PeerHostDoctor.inventoryWarnings(
            PeerHostDoctor.parseBinaryInventory("""
            os=Linux
            ssh-user=root
            daemon-user=term-mesh
            term-meshd=/usr/local/bin/term-meshd|term-meshd 0.180.0
            tm-agent-bridge=/usr/local/bin/tm-agent-bridge|
            """)
        )
        XCTAssertEqual(warnings.count, 1, "\(warnings)")
        XCTAssertTrue(warnings[0].contains("SSH connects as root"), warnings[0])
        XCTAssertTrue(warnings[0].contains("panes run as term-mesh"), warnings[0])
        XCTAssertTrue(warnings[0].contains("Reinstall term-meshd"), warnings[0])
    }

    func test_matchingSSHAndDaemonAccountsStaySilent() {
        let warnings = PeerHostDoctor.inventoryWarnings(
            PeerHostDoctor.parseBinaryInventory("""
            os=Linux
            ssh-user=root
            daemon-user=root
            term-meshd=/usr/local/bin/term-meshd|term-meshd 0.180.0
            tm-agent-bridge=/usr/local/bin/tm-agent-bridge|
            """)
        )
        XCTAssertEqual(warnings, [])
    }

    func test_reportsBothTheShadowAndTheAppMismatch() {
        let warnings = PeerHostDoctor.inventoryWarnings(
            PeerHostDoctor.parseBinaryInventory("""
            app=0.170.1
            tm-agent=/Users/jinwoo/.local/bin/tm-agent|tm-agent 0.167.0
            tm-agent.shadowed=/opt/homebrew/bin/tm-agent|tm-agent 0.170.1
            """)
        )
        XCTAssertEqual(warnings.count, 2, "\(warnings)")
        XCTAssertTrue(
            warnings.contains { $0.contains("/opt/homebrew/bin/tm-agent") && $0.contains("shadowed") },
            "the shadowed copy must be named — it is what makes the host look current: \(warnings)"
        )
        XCTAssertTrue(
            warnings.contains { $0.contains("0.167.0") && $0.contains("0.170.1") },
            "both versions belong in the message: \(warnings)"
        )
    }

    /// A host whose copies agree says nothing. A warning that fires on
    /// healthy hosts is one people stop reading.
    func test_aConsistentHostIsSilent() {
        let warnings = PeerHostDoctor.inventoryWarnings(
            PeerHostDoctor.parseBinaryInventory("""
            app=0.170.1
            tm-agent=/opt/homebrew/bin/tm-agent|tm-agent 0.170.1
            term-meshd=/usr/local/bin/term-meshd|term-meshd 0.170.1
            tm-agent-bridge=/usr/local/bin/tm-agent-bridge|
            """)
        )
        XCTAssertEqual(warnings, [])
    }

    /// jwserver69: the daemon that answers on PATH is not the one systemd
    /// started. Same shape, different binary.
    func test_aShadowedDaemonIsReportedToo() {
        let warnings = PeerHostDoctor.inventoryWarnings(
            PeerHostDoctor.parseBinaryInventory("""
            term-meshd=/root/.local/bin/term-meshd|term-meshd 0.168.0
            term-meshd.shadowed=/usr/local/bin/term-meshd|term-meshd 0.169.0
            tm-agent-bridge=/root/.local/bin/tm-agent-bridge|
            """)
        )
        XCTAssertEqual(warnings.count, 1, "\(warnings)")
        XCTAssertTrue(warnings[0].contains("term-meshd"), warnings[0])
        XCTAssertTrue(warnings[0].contains("0.168.0") && warnings[0].contains("0.169.0"), warnings[0])
    }

    /// A Linux host has no app bundle, and a shadow at the same version is
    /// just a duplicate install — neither is worth a line.
    func test_noAppVersionAndMatchingShadowsStaySilent() {
        let warnings = PeerHostDoctor.inventoryWarnings(
            PeerHostDoctor.parseBinaryInventory("""
            tm-agent=/root/.local/bin/tm-agent|tm-agent 0.170.1
            tm-agent.shadowed=/usr/local/bin/tm-agent|tm-agent 0.170.1
            """)
        )
        XCTAssertEqual(warnings, [])
    }

    /// Garbage and future keys are ignored rather than failing the report.
    func test_unknownLinesDoNotBreakTheReport() {
        let inventory = PeerHostDoctor.parseBinaryInventory("""
        Warning: Permanently added a host key
        future.key=whatever
        tm-agent=/usr/local/bin/tm-agent|tm-agent 0.170.1
        """)
        XCTAssertEqual(inventory.cli?.path, "/usr/local/bin/tm-agent")
        XCTAssertNil(inventory.appVersion)
    }

    // MARK: - The bridge

    /// A daemon host with no bridge cannot hold codex/kiro/cursor/agy agents
    /// as native panels. Nothing else reports that, and the symptom on its own
    /// is just "why did this open as a terminal pane".
    func test_aDaemonHostWithoutABridgeIsReported() {
        let warnings = PeerHostDoctor.inventoryWarnings(
            PeerHostDoctor.parseBinaryInventory("""
            term-meshd=/usr/local/bin/term-meshd|term-meshd 0.179.0
            tm-agent=/usr/local/bin/tm-agent|tm-agent 0.179.0
            """)
        )
        XCTAssertEqual(warnings.count, 1, "\(warnings)")
        XCTAssertTrue(warnings[0].contains("tm-agent-bridge"), warnings[0])
    }

    func test_aDaemonHostWithABridgeIsSilent() {
        let warnings = PeerHostDoctor.inventoryWarnings(
            PeerHostDoctor.parseBinaryInventory("""
            term-meshd=/usr/local/bin/term-meshd|term-meshd 0.179.0
            tm-agent=/usr/local/bin/tm-agent|tm-agent 0.179.0
            tm-agent-bridge=/usr/local/bin/tm-agent-bridge|
            """)
        )
        XCTAssertEqual(warnings, [])
    }

    /// A Mac peer serves from the app bundle, which carries its own bridge.
    /// Reporting a missing one there would describe a problem that does not
    /// exist — the PATH this probe searches is not where it would live.
    func test_aHostWithNoDaemonIsNotAskedAboutTheBridge() {
        let warnings = PeerHostDoctor.inventoryWarnings(
            PeerHostDoctor.parseBinaryInventory("""
            app=0.179.0
            tm-agent=/opt/homebrew/bin/tm-agent|tm-agent 0.179.0
            """)
        )
        XCTAssertEqual(warnings, [])
    }

    /// The bridge has no --version, so the probe sends an empty one. That must
    /// still count as present rather than reading as "found nothing".
    func test_aBridgeWithoutAVersionStillCountsAsPresent() {
        let inventory = PeerHostDoctor.parseBinaryInventory(
            "tm-agent-bridge=/usr/local/bin/tm-agent-bridge|"
        )
        XCTAssertEqual(inventory.bridge?.path, "/usr/local/bin/tm-agent-bridge")
        XCTAssertEqual(inventory.bridge?.version, "")
    }
}
