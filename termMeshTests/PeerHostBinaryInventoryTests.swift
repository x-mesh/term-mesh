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
        guard let bundled = cmd.range(
                  of: "/Applications/term-mesh.app/Contents/Resources/bin"
              ),
              let home = cmd.range(of: "$HOME/.local/bin"),
              let brew = cmd.range(of: "/opt/homebrew/bin")
        else {
            return XCTFail("the launch PATH directories must appear in the probe")
        }
        XCTAssertTrue(
            bundled.lowerBound < home.lowerBound,
            "a Mac peer must prefer the tools shipped with its app over user installs"
        )
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

    func test_parsesAgentShellAndShellIndependentEnvironmentStatus() {
        let inventory = PeerHostDoctor.parseBinaryInventory("""
        login-shell=/usr/bin/zsh
        agent-shell=/usr/bin/zsh
        home=/root
        agent-env-path=/root/.config/term-mesh/agent-env
        agent-env-present=1
        """)
        XCTAssertEqual(inventory.loginShell, "/usr/bin/zsh")
        XCTAssertEqual(inventory.agentShell, "/usr/bin/zsh")
        XCTAssertEqual(
            inventory.agentEnvironmentPath,
            "/root/.config/term-mesh/agent-env"
        )
        XCTAssertEqual(inventory.agentEnvironmentFileExists, true)
    }

    func test_inventoryReportsTheBourneFallbackAsTheActualAgentShell() {
        let command = PeerHostDoctor.binaryInventoryCommand
        XCTAssertTrue(command.contains(#"case "${agent_shell##*/}""#))
        XCTAssertTrue(command.contains("agent_shell=/bin/sh"))
        XCTAssertTrue(command.contains(#"echo "agent-shell=$agent_shell""#))
    }

    func test_inventoryChecksAgentEnvPresenceWithoutReadingIt() {
        let command = PeerHostDoctor.binaryInventoryCommand
        XCTAssertTrue(command.contains(#"[ -f "$agent_env" ]"#))
        XCTAssertFalse(command.contains(#"cat "$agent_env""#))
        XCTAssertFalse(command.contains(#". "$agent_env""#))
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

    /// A CLI can be installed, found by this probe, and used by every agent on
    /// the host while the pane beside them cannot see it: agents run with a
    /// fixed PATH, panes build theirs from the login profile. Measured on a
    /// host whose `~/.local/bin` held claude, codex and git-kit and whose
    /// login PATH never mentioned it.
    func test_reportsWhenPanesCannotSeeTheCLI() {
        let warnings = PeerHostDoctor.inventoryWarnings(
            PeerHostDoctor.parseBinaryInventory("""
            os=Linux
            ssh-user=root
            daemon-user=root
            home=/root
            login-shell=/bin/bash
            login-path=/usr/local/bin:/usr/bin:/bin
            tm-agent=/opt/tools/bin/tm-agent|tm-agent 0.180.0
            """)
        )
        XCTAssertEqual(warnings.count, 1, "\(warnings)")
        XCTAssertTrue(warnings[0].contains("/opt/tools/bin"), warnings[0])
        XCTAssertTrue(warnings[0].contains("/bin/bash"), warnings[0])
        XCTAssertTrue(warnings[0].contains("Agents are unaffected"), warnings[0])
    }

    func test_reportsHomebrewTmAgentHiddenFromMacSSHLoginPath() {
        let warnings = PeerHostDoctor.inventoryWarnings(
            PeerHostDoctor.parseBinaryInventory("""
            os=Darwin
            app=0.220.0
            home=/Users/jinwoo
            login-shell=/bin/zsh
            login-path=/usr/bin:/bin:/usr/sbin:/sbin
            tm-agent=/Applications/term-mesh.app/Contents/Resources/bin/tm-agent|tm-agent 0.220.0
            tm-agent.shadowed=/opt/homebrew/bin/tm-agent|tm-agent 0.220.0
            """)
        )
        XCTAssertEqual(warnings.count, 1, "\(warnings)")
        XCTAssertTrue(warnings[0].contains("/opt/homebrew/bin"), warnings[0])
        XCTAssertTrue(warnings[0].contains("Terminal panes cannot find tm-agent"), warnings[0])
    }

    func testHomebrewTmAgentVisibleToLoginShellStaysSilent() {
        let warnings = PeerHostDoctor.inventoryWarnings(
            PeerHostDoctor.parseBinaryInventory("""
            os=Darwin
            app=0.220.0
            home=/Users/jinwoo
            login-shell=/bin/zsh
            login-path=/opt/homebrew/bin:/usr/bin:/bin
            tm-agent=/Applications/term-mesh.app/Contents/Resources/bin/tm-agent|tm-agent 0.220.0
            tm-agent.shadowed=/opt/homebrew/bin/tm-agent|tm-agent 0.220.0
            """)
        )
        XCTAssertEqual(warnings, [], "\(warnings)")
    }

    /// The daemon prepends `~/.local/bin` to a pane's PATH itself, so naming
    /// it would report a gap that is already closed.
    func test_cliUnderHomeLocalBinStaysSilent() {
        let warnings = PeerHostDoctor.inventoryWarnings(
            PeerHostDoctor.parseBinaryInventory("""
            os=Linux
            ssh-user=root
            daemon-user=root
            home=/root
            login-shell=/bin/bash
            login-path=/usr/local/bin:/usr/bin:/bin
            tm-agent=/root/.local/bin/tm-agent|tm-agent 0.180.0
            """)
        )
        XCTAssertEqual(warnings, [], "\(warnings)")
    }

    /// No login PATH read means no claim about what a pane can see.
    func test_missingLoginPathStaysSilent() {
        let warnings = PeerHostDoctor.inventoryWarnings(
            PeerHostDoctor.parseBinaryInventory("""
            os=Linux
            ssh-user=root
            daemon-user=root
            tm-agent=/opt/tools/bin/tm-agent|tm-agent 0.180.0
            """)
        )
        XCTAssertEqual(warnings, [], "\(warnings)")
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
            os=Linux
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
            os=Linux
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

    /// A Mac app launches its bundled daemon and bundled bridge together. The
    /// fixed SSH PATH may expose only the daemon, but that is not evidence the
    /// app is missing its bridge (observed on mac-sub with app v0.193.0).
    func test_aMacBundledDaemonWithoutAPathBridgeStaysSilent() {
        let warnings = PeerHostDoctor.inventoryWarnings(
            PeerHostDoctor.parseBinaryInventory("""
            os=Darwin
            app=0.193.0
            term-meshd=/Applications/term-mesh.app/Contents/Resources/bin/term-meshd|term-meshd 0.193.0
            tm-agent=/opt/homebrew/bin/tm-agent|tm-agent 0.193.0
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

    func test_cleanupOffersOnlyHomeOwnedVersionDrift() {
        let inventory = PeerHostDoctor.parseBinaryInventory("""
        home=/Users/jinwoo
        tm-agent=/Applications/term-mesh.app/Contents/Resources/bin/tm-agent|tm-agent 0.210.0
        tm-agent.shadowed=/Users/jinwoo/bin/tm-agent|tm-agent 0.199.0|1:2:3:4
        tm-agent.shadowed=/usr/local/bin/tm-agent|tm-agent 0.198.0|2:3:4:5
        term-meshd=/Applications/term-mesh.app/Contents/Resources/bin/term-meshd|term-meshd 0.210.0
        term-meshd.shadowed=/Users/jinwoo/bin/term-meshd|term-meshd 0.199.0|3:4:5:6
        """)
        XCTAssertEqual(
            PeerHostDoctor.shadowedBinaryCleanupCandidates(inventory).map(\.path),
            ["/Users/jinwoo/bin/term-meshd", "/Users/jinwoo/bin/tm-agent"]
        )
    }

    func test_binaryArchiveCommandKeepsPathsOnStdinAndUnderHome() {
        let command = PeerHostDoctor.shadowedBinaryArchiveCommand
        XCTAssertTrue(command.contains("while IFS=\"$tab\" read -r p"))
        XCTAssertTrue(command.contains("home_real=$(realpath \"$HOME\")"))
        XCTAssertTrue(command.contains("realpath"))
        XCTAssertTrue(command.contains("actual_identity"))
        XCTAssertTrue(command.contains("actual_version"))
        XCTAssertTrue(command.contains("cleanup-backups"))
        XCTAssertTrue(command.contains("mktemp -d"), "each archive needs a collision-free root")
        XCTAssertTrue(command.contains("[ ! -L \"$root\" ]"), "backup parents must not escape HOME through symlinks")
        XCTAssertTrue(command.contains("[ ! -e \"$dest\" ]"), "an existing backup must never be overwritten")
        XCTAssertFalse(command.contains("rm -"))
        let parsed = PeerHostDoctor.parseBinaryArchiveResult(
            "archived=/Users/jinwoo/bin/tm-agent\nprotected=/usr/bin/tool\nchanged=/Users/jinwoo/bin/term-meshd\n"
        )
        XCTAssertEqual(parsed.archived, ["/Users/jinwoo/bin/tm-agent"])
        XCTAssertEqual(parsed.protected, ["/usr/bin/tool"])
        XCTAssertEqual(parsed.changed, ["/Users/jinwoo/bin/term-meshd"])
    }
}

/// Leftover daemons are the failure that looks like nothing: the host answers,
/// the app runs, and a process nobody points at holds sockets from yesterday.
/// Every fixture here is a shape observed on jinwoo-macbook-pro-sub.
final class PeerHostDaemonSnapshotTests: XCTestCase {
    /// Same `sh -c '…'` wrapper constraint as every other fixed probe.
    func test_command_hasNoSingleQuoteInsideBody() {
        let cmd = PeerHostDoctor.daemonInstancesProbeCommand
        XCTAssertTrue(cmd.hasPrefix("sh -c '"), "expected sh -c '…' wrapper")
        XCTAssertTrue(cmd.hasSuffix("'"), "expected closing single quote")
        let body = String(cmd.dropFirst("sh -c '".count).dropLast(1))
        XCTAssertFalse(body.contains("'"), "probe body must not contain single quotes")
    }

    /// `lsof -p X -U` ORs its selectors: every process reports every unix
    /// socket on the machine, the app appears connected to all of them, and
    /// nothing is ever stale. `-a` is what makes the probe mean anything.
    func test_command_andsTheLsofSelectors() {
        XCTAssertTrue(
            PeerHostDoctor.daemonInstancesProbeCommand.contains("lsof -a -p"),
            "lsof selectors must be AND-ed or the probe silently reports nothing stale"
        )
    }

    private let observedOutput = """
    app=87534
    appsocks=/tmp/term-mesh-peer-501/peer.sock /tmp/term-mesh-relays-501/cee24596.sock /tmp/term-mesh.sock
    daemon=42767 ppid=1 etime=01-05:10:54 probe=1 unixfds=5 socketfds=2 anonfds=3 peerfds=1 started=Mon_Aug_24 exe=/app/term-meshd socks=/private/tmp/term-meshd-peer.sock /private/tmp/term-meshd.sock
    daemon-existing=42767 path=/private/tmp/term-meshd-peer.sock
    daemon=44865 ppid=1 etime=01-05:07:10 probe=1 unixfds=5 socketfds=2 anonfds=3 peerfds=1 started=Sun_Aug_23 exe=/app/term-meshd socks=/var/folders/rd/xx/T/term-meshd-peer.sock /var/folders/rd/xx/T/term-meshd.sock
    daemon-existing=44865 path=/var/folders/rd/xx/T/term-meshd-peer.sock
    """

    func test_parsesTheAppAndEveryDaemon() {
        let snapshot = PeerHostDoctor.parseDaemonSnapshot(observedOutput)
        XCTAssertEqual(snapshot.appPid, 87534)
        XCTAssertEqual(snapshot.appSockets.count, 3)
        XCTAssertEqual(snapshot.daemons.map(\.pid), [42767, 44865])
        XCTAssertEqual(snapshot.daemons.first?.parentPid, 1)
        XCTAssertEqual(snapshot.daemons.first?.elapsed, "01-05:10:54")
        XCTAssertEqual(
            snapshot.daemons.first?.sockets,
            ["/private/tmp/term-meshd-peer.sock", "/private/tmp/term-meshd.sock"]
        )
        XCTAssertEqual(
            snapshot.daemons.first?.existingSockets,
            ["/private/tmp/term-meshd-peer.sock"]
        )
        XCTAssertEqual(snapshot.daemons.first?.peerFDCount, 1)
        XCTAssertEqual(snapshot.daemons.first?.socketFDCount, 2)
        XCTAssertEqual(snapshot.daemons.first?.unixSocketFDCount, 5)
        XCTAssertEqual(snapshot.daemons.first?.anonymousSocketFDCount, 3)
        XCTAssertEqual(snapshot.daemons.first?.socketProbeComplete, true)
        XCTAssertEqual(snapshot.daemons.first?.startIdentity, "Mon_Aug_24")
        XCTAssertEqual(snapshot.daemons.first?.executablePath, "/app/term-meshd")
    }

    /// Peer listeners may be serving another Mac. Local lsof cannot prove
    /// external client count is zero, so they are not cleanup candidates.
    func test_peerServingDaemonsAreNeverInferredStaleFromLocalAppSockets() {
        let stale = PeerHostDoctor.staleDaemons(
            in: PeerHostDoctor.parseDaemonSnapshot(observedOutput)
        )
        XCTAssertTrue(stale.isEmpty)
    }

    func test_unlinkedPeerFDIsCleanupCandidate() {
        let output = """
        app=87534
        appsocks=/tmp/term-mesh-peer-501/peer.sock
        daemon=42767 ppid=1 etime=01-05:10:54 probe=1 socketfds=1 peerfds=1 started=old exe=/app/term-meshd socks=/private/tmp/term-meshd-peer.sock
        """
        XCTAssertEqual(
            PeerHostDoctor.staleDaemons(
                in: PeerHostDoctor.parseDaemonSnapshot(output)
            ).map(\.pid),
            [42767]
        )
    }

    func test_incompleteSocketProbeFailsClosed() {
        let output = """
        app=87534
        appsocks=/tmp/term-mesh-peer-501/peer.sock
        daemon=42767 ppid=1 etime=01-05:10:54 probe=0 socketfds=0 peerfds=0 started=old exe=/app/term-meshd socks=
        """
        XCTAssertTrue(
            PeerHostDoctor.staleDaemons(
                in: PeerHostDoctor.parseDaemonSnapshot(output)
            ).isEmpty,
            "an unavailable lsof result is uncertainty, never permission to signal"
        )
    }

    func test_customSocketPathStillProtectsAcceptedClient() {
        let output = """
        app=87534
        appsocks=/tmp/custom-project.sock
        daemon=42767 ppid=1 etime=01-05:10:54 probe=1 socketfds=2 peerfds=0 started=owner exe=/app/term-meshd socks=/tmp/custom-project.sock
        """
        XCTAssertTrue(
            PeerHostDoctor.staleDaemons(
                in: PeerHostDoctor.parseDaemonSnapshot(output)
            ).isEmpty,
            "accepted clients on custom paths must not depend on a term-mesh filename"
        )
        XCTAssertTrue(
            PeerHostDoctor.daemonInstancesProbeCommand.contains("s/^n\\(\\/.*\\)/\\1/p")
        )
    }

    func test_socketRecordsPreserveWhitespaceLosslessly() {
        let output = """
        app=87534
        app-socket=L3RtcC9zZXNzaW9uIG93bmVyLnNvY2s=
        daemon=42767 ppid=1 etime=00:01:00 probe=1 unixfds=4 socketfds=1 anonfds=3 peerfds=0 started=owner exe=/app/term-meshd socks=
        daemon-socket=42767 encoded=L3RtcC9zZXNzaW9uIG93bmVyLnNvY2s=
        daemon-existing=42767 encoded=L3RtcC9zZXNzaW9uIG93bmVyLnNvY2s=
        """
        let snapshot = PeerHostDoctor.parseDaemonSnapshot(output)
        XCTAssertEqual(snapshot.appSockets, ["/tmp/session owner.sock"])
        XCTAssertEqual(snapshot.daemons.first?.sockets, ["/tmp/session owner.sock"])
        XCTAssertEqual(snapshot.daemons.first?.existingSockets, ["/tmp/session owner.sock"])
        XCTAssertTrue(PeerHostDoctor.staleDaemons(in: snapshot).isEmpty)
        XCTAssertTrue(PeerHostDoctor.daemonInstancesProbeCommand.contains("base64"))
        XCTAssertTrue(PeerHostDoctor.daemonInstancesProbeCommand.contains("netstat -anv -f unix"))
        XCTAssertTrue(PeerHostDoctor.daemonInstancesProbeCommand.contains("00000002"))
    }

    func test_unexpectedAnonymousUnixFDsFailClosed() {
        let output = """
        app=87534
        daemon=42767 ppid=1 etime=01:00:00 probe=1 unixfds=5 socketfds=1 anonfds=4 peerfds=0 started=owner exe=/app/term-meshd socks=/tmp/custom.sock
        """
        XCTAssertTrue(
            PeerHostDoctor.staleDaemons(
                in: PeerHostDoctor.parseDaemonSnapshot(output)
            ).isEmpty
        )
    }

    func test_verifiedSessionOwnerIsExplicitlyProtected() {
        let output = """
        app=87534
        appsocks=/tmp/term-mesh-peer-501/peer.sock
        daemon=42767 ppid=1 etime=01-05:10:54 probe=1 socketfds=1 peerfds=1 started=owner exe=/app/term-meshd socks=/tmp/owner-peer.sock
        """
        let snapshot = PeerHostDoctor.parseDaemonSnapshot(output)
        XCTAssertEqual(PeerHostDoctor.staleDaemons(in: snapshot).map(\.pid), [42767])
        XCTAssertTrue(
            PeerHostDoctor.staleDaemons(in: snapshot, protecting: [42767]).isEmpty
        )
    }

    func test_samePathRebindKeepsCurrentAppChildAndFindsOldGeneration() {
        let output = """
        app=90001
        appsocks=/tmp/term-mesh-peer-501/peer.sock
        daemon=42767 ppid=1 etime=01-05:10:54 probe=1 socketfds=1 peerfds=1 started=old exe=/app/term-meshd socks=/tmp/term-meshd-peer.sock
        daemon-existing=42767 path=/tmp/term-meshd-peer.sock
        daemon=51000 ppid=90001 etime=00:00:10 probe=1 socketfds=1 peerfds=1 started=new exe=/app/term-meshd socks=/tmp/term-meshd-peer.sock
        daemon-existing=51000 path=/tmp/term-meshd-peer.sock
        daemon-current=51000 encoded=L3RtcC90ZXJtLW1lc2hkLXBlZXIuc29jaw==
        """
        let snapshot = PeerHostDoctor.parseDaemonSnapshot(output)
        XCTAssertEqual(snapshot.daemons.last?.currentListenerSockets, ["/tmp/term-meshd-peer.sock"])
        XCTAssertEqual(
            PeerHostDoctor.staleDaemons(
                in: snapshot,
                protecting: [51000]
            ).map(\.pid),
            [42767]
        )
    }

    func test_samePathWithoutExactKernelOwnerFailsClosed() {
        let output = """
        app=90001
        daemon=42767 ppid=90001 etime=00:10:00 probe=1 socketfds=2 peerfds=2 started=old exe=/app/term-meshd socks=/tmp/term-meshd-peer.sock
        daemon-existing=42767 path=/tmp/term-meshd-peer.sock
        daemon=51000 ppid=1 etime=00:00:10 probe=1 socketfds=1 peerfds=1 started=new exe=/app/term-meshd socks=/tmp/term-meshd-peer.sock
        daemon-existing=51000 path=/tmp/term-meshd-peer.sock
        """
        XCTAssertTrue(
            PeerHostDoctor.staleDaemons(
                in: PeerHostDoctor.parseDaemonSnapshot(output),
                protecting: [42767, 51000]
            ).isEmpty,
            "accepted clients and app parentage cannot substitute for exact bind ownership"
        )
    }

    func test_unlinkedDaemonWithAcceptedPeerClientIsProtected() {
        let output = """
        app=90001
        appsocks=/tmp/term-mesh-peer-501/peer.sock
        daemon=42767 ppid=1 etime=01-05:10:54 probe=1 socketfds=2 peerfds=2 started=old exe=/app/term-meshd socks=/tmp/old-peer.sock
        """
        XCTAssertTrue(
            PeerHostDoctor.staleDaemons(
                in: PeerHostDoctor.parseDaemonSnapshot(output)
            ).isEmpty
        )
    }

    func test_controlOnlyDaemonOutsideTheAppCanBeStale() {
        let output = """
        app=87534
        appsocks=/tmp/term-mesh.sock
        daemon=42767 ppid=1 etime=01-05:10:54 probe=1 socketfds=1 peerfds=0 started=old exe=/app/term-meshd socks=/private/tmp/term-meshd.sock
        """
        XCTAssertEqual(
            PeerHostDoctor.staleDaemons(
                in: PeerHostDoctor.parseDaemonSnapshot(output)
            ).map(\.pid),
            [42767]
        )
    }

    /// Production regression, 2026-08-23: the Mac app owns its bundled
    /// session daemon as a child process, but the listener belongs to the
    /// child and therefore never appears in the app process's lsof list.
    /// Cleanup called that daemon unused, SIGTERM'd it, and disconnected
    /// every Project another Mac had attached through it. Parent ownership is
    /// authoritative even when no socket pathname intersects.
    func test_appChildSessionOwnerIsNeverStaleWithoutSocketIntersection() {
        let output = """
        app=65188
        appsocks=/tmp/term-mesh-peer-501/peer.sock /tmp/term-mesh.sock
        daemon=65197 ppid=65188 etime=02:23:13 probe=1 socketfds=2 peerfds=1 started=current exe=/app/term-meshd socks=/var/folders/rd/xx/T/term-meshd-peer.sock /var/folders/rd/xx/T/term-meshd.sock
        """
        XCTAssertTrue(
            PeerHostDoctor.staleDaemons(
                in: PeerHostDoctor.parseDaemonSnapshot(output)
            ).isEmpty,
            "the app's own child daemon may be the session owner for another Mac"
        )
    }

    /// An adopted daemon shows up as a client connection in the app's own
    /// socket list. Killing that one would end the sessions another machine
    /// reattaches to — the opposite of the point.
    func test_anAdoptedDaemonIsNotStale() {
        let output = """
        app=90001
        appsocks=/tmp/term-mesh-peer-501/peer.sock /private/tmp/term-meshd.sock
        daemon=42767 ppid=1 etime=00:10:00 probe=1 socketfds=3 peerfds=2 started=adopted exe=/app/term-meshd socks=/private/tmp/term-meshd-peer.sock /private/tmp/term-meshd.sock
        daemon=44865 ppid=1 etime=01-05:07:10 probe=1 socketfds=1 peerfds=0 started=old exe=/app/term-meshd socks=/var/folders/rd/xx/T/term-meshd.sock
        """
        let stale = PeerHostDoctor.staleDaemons(in: PeerHostDoctor.parseDaemonSnapshot(output))
        XCTAssertEqual(stale.map(\.pid), [44865], "only the daemon outside the app's sockets")
    }

    /// With no app running, a daemon may be holding sessions for the next
    /// launch to adopt. Outliving the app is deliberate, so "no app" is not
    /// evidence of anything and the answer must be empty.
    func test_noRunningAppMeansNoVerdict() {
        let output = """
        app=none
        daemon=42767 ppid=1 etime=01-05:10:54 probe=1 socketfds=1 peerfds=0 started=old exe=/app/term-meshd socks=/private/tmp/term-meshd.sock
        """
        let snapshot = PeerHostDoctor.parseDaemonSnapshot(output)
        XCTAssertNil(snapshot.appPid)
        XCTAssertEqual(snapshot.daemons.count, 1)
        XCTAssertTrue(PeerHostDoctor.staleDaemons(in: snapshot).isEmpty)
    }

    /// The cleanup reply names what it actually ended. A pid that was already
    /// gone comes back as `failed=` and must not be reported as stopped.
    func test_parsesOnlyTheKilledPids() {
        XCTAssertEqual(
            PeerHostDoctor.parseTerminatedPids("killed=42767\nfailed=44865\nreplaced=51000\n"),
            [42767]
        )
        XCTAssertTrue(PeerHostDoctor.parseTerminatedPids("").isEmpty)
    }

    /// The pids travel on stdin; the command text stays fixed. The remote
    /// guard is the second half of that — a non-numeric line is skipped.
    func test_cleanupCommandRefusesNonNumericInput() {
        let cmd = PeerHostDoctor.daemonCleanupCommand
        XCTAssertTrue(cmd.contains("*[!0-9]*"), "non-numeric stdin must be skipped remotely")
        XCTAssertFalse(cmd.contains("kill -KILL"), "cleanup must not interrupt the daemon's own descendant teardown")
        XCTAssertTrue(cmd.contains("[ \"$n\" -lt 120 ]"), "grace must exceed daemon server shutdown budget")
        XCTAssertEqual(
            cmd.components(separatedBy: "[ \"$n\" -lt 120 ]").count - 1,
            1,
            "all daemons must share one grace window"
        )
        XCTAssertTrue(cmd.contains("expected_start"), "PID reuse must be guarded by process start identity")
        XCTAssertTrue(cmd.contains("expected_exe"), "PID reuse must be guarded by executable identity")
        XCTAssertTrue(
            cmd.contains(".app/Contents/MacOS/term-mesh"),
            "kill-time guard must protect the app's current child daemon"
        )
        XCTAssertTrue(cmd.contains("socketfds"), "an existing control or peer client must remain protected")
        XCTAssertTrue(cmd.contains("if ! raw=$(lsof"), "a failed client probe must protect the process")
        XCTAssertFalse(cmd.contains("$checked"), "client checks must not be separated from SIGTERM by a second pass")
        XCTAssertTrue(cmd.contains("done; n=0"), "all eligible daemons must receive SIGTERM before the shared wait")
        XCTAssertTrue(cmd.contains("-F fn"), "all UNIX FD records, including anonymous ones, must be counted")
        XCTAssertTrue(cmd.contains("anonfds"), "anonymous client candidates must fail closed")
    }

    /// The readiness script decides whether a leader may start, and its
    /// catch-all turns any error into "CLI unavailable". The diagnostic
    /// appended to it must therefore be unable to fail outward: the probe ends
    /// in `exit 44` on every non-Mac host, and that alone would have stopped
    /// leaders from starting on Linux.
    func test_leaderDiagnosticCannotAffectItsHostScript() {
        let fragment = TeamOrchestrator.leaderDaemonDiagnostic
        XCTAssertTrue(fragment.hasPrefix("( "), "must run in a subshell")
        XCTAssertTrue(fragment.hasSuffix("|| true"), "must swallow its own exit status")
        XCTAssertTrue(fragment.contains("exit 44"), "still the same probe body")
    }

    /// The probe body and the standalone command must stay the same probe.
    func test_probeCommandWrapsTheSharedBody() {
        XCTAssertEqual(
            PeerHostDoctor.daemonInstancesProbeCommand,
            "sh -c '" + PeerHostDoctor.daemonInstancesProbeBody + "'"
        )
    }

    /// Riding along on the readiness round trip means the daemon lines arrive
    /// mixed in with readiness markers. The parser reads whole-line keys, so
    /// the marker is not one of them — but only because the diagnostic opens
    /// a fresh line first.
    func test_parsesDaemonLinesOutOfReadinessOutput() {
        let output = """
        __TERMMESH_LEADER_READY__
        app=87534
        appsocks=/tmp/term-mesh-peer-501/peer.sock
        daemon=42767 ppid=1 etime=01-05:10:54 probe=1 socketfds=1 peerfds=0 started=old exe=/app/term-meshd socks=/private/tmp/term-meshd.sock
        """
        let snapshot = PeerHostDoctor.parseDaemonSnapshot(output)
        XCTAssertEqual(snapshot.appPid, 87534)
        XCTAssertEqual(PeerHostDoctor.staleDaemons(in: snapshot).map(\.pid), [42767])
    }

    /// The marker is written with `printf %s`. Without the diagnostic opening
    /// its own line, its first key lands glued to that marker, the app is
    /// missed, and "no app" is the case that reports nothing — a diagnostic
    /// that is silent everywhere instead of wrong somewhere.
    func test_diagnosticOpensItsOwnLine() {
        XCTAssertTrue(
            TeamOrchestrator.leaderDaemonDiagnostic.hasPrefix("( echo;"),
            "the probe must start a fresh line or its first key merges with the marker"
        )
        let glued = "__TERMMESH_LEADER_READY__app=87534"
        XCTAssertNil(
            PeerHostDoctor.parseDaemonSnapshot(glued).appPid,
            "documents why the newline is required"
        )
    }

    /// A host with one app and one adopted daemon — the healthy shape, which
    /// must never produce a cleanup prompt.
    func test_healthyHostReportsNothing() {
        let output = """
        app=90001
        appsocks=/tmp/term-mesh-peer-501/peer.sock /var/folders/rd/xx/T/term-meshd.sock
        daemon=51000 ppid=1 etime=02:00:00 probe=1 socketfds=1 peerfds=0 started=current exe=/app/term-meshd socks=/var/folders/rd/xx/T/term-meshd.sock
        daemon-existing=51000 path=/var/folders/rd/xx/T/term-meshd.sock
        """
        XCTAssertTrue(
            PeerHostDoctor.staleDaemons(in: PeerHostDoctor.parseDaemonSnapshot(output)).isEmpty
        )
    }
}
