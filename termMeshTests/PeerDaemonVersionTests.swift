import Darwin
import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class PeerDaemonVersionTests: XCTestCase {

    func test_healthBaselineCommand_isFixedQuotedAndMeasuresBothPlanes() {
        let command = PeerHostDoctor.healthBaselineCommand
        XCTAssertTrue(command.hasPrefix("sh -c '"))
        XCTAssertTrue(command.hasSuffix("'"))
        let body = String(command.dropFirst("sh -c '".count).dropLast())
        XCTAssertFalse(body.contains("'"))
        XCTAssertTrue(body.contains("health-control-rpc"))
        XCTAssertTrue(body.contains("health-peer-present"))
        XCTAssertTrue(body.contains("attach relay lagged"))
        XCTAssertTrue(body.contains("frame length .* exceeds"))
        XCTAssertTrue(body.contains("/run/user/$(id -u)/term-meshd.sock"))
    }

    func test_healthBaseline_requiresControlAndProtocolIntegrity() {
        let healthy = PeerHostDoctor.parseHealthBaseline("""
        health-service-active=1
        health-control-path=/tmp/term-meshd.sock
        health-control-present=1
        health-control-rpc=1
        health-peer-path=/run/term-mesh/tm-peer.sock
        health-peer-present=1
        health-relay-lag-5m=0
        health-resume-heal-5m=0
        health-protocol-mismatch-5m=0
        """)
        XCTAssertEqual(healthy?.verdict, .healthy)

        var missingControl = healthy!
        missingControl.controlPathPresent = false
        XCTAssertEqual(missingControl.verdict, .unhealthy)

        var protocolMismatch = healthy!
        protocolMismatch.protocolMismatchCount = 1
        XCTAssertEqual(protocolMismatch.verdict, .unhealthy)

        var lagging = healthy!
        lagging.relayLagCount = 2
        XCTAssertEqual(lagging.verdict, .degraded)
    }

    func test_healthBaseline_duplicateBannerKeysUseFinalProbeBlock() {
        let parsed = PeerHostDoctor.parseHealthBaseline("""
        health-service-active=0
        health-control-path=/banner/stale.sock
        health-service-active=1
        health-control-path=/run/user/501/term-meshd.sock
        health-control-present=1
        health-control-rpc=1
        health-peer-path=/run/user/501/tm-peer.sock
        health-peer-present=1
        health-relay-lag-5m=0
        health-resume-heal-5m=0
        health-protocol-mismatch-5m=0
        """)

        XCTAssertEqual(parsed?.serviceActive, true)
        XCTAssertEqual(parsed?.controlPath, "/run/user/501/term-meshd.sock")
        XCTAssertEqual(parsed?.verdict, .healthy)
    }

    func test_healthBaseline_rejectsPartialProbeOutput() {
        XCTAssertNil(PeerHostDoctor.parseHealthBaseline("""
        health-service-active=1
        health-control-present=1
        """))
    }

    // MARK: - PeerHostDoctor.versionProbeCommand script invariants

    /// Same structural constraint as PeerSocketProber.remoteCommand:
    /// the body rides inside `sh -c '…'`, so a single quote anywhere in
    /// it would end the quoting early on the remote shell and break the
    /// probe on every host.
    func test_versionProbeCommand_hasNoSingleQuoteInsideBody() {
        let cmd = PeerHostDoctor.versionProbeCommand
        XCTAssertTrue(cmd.hasPrefix("sh -c '"), "expected sh -c '…' wrapper")
        XCTAssertTrue(cmd.hasSuffix("'"), "expected closing single quote")
        let body = String(cmd.dropFirst("sh -c '".count).dropLast(1))
        XCTAssertFalse(body.contains("'"),
                       "probe body must not contain single quotes")
    }

    func test_versionProbeCommand_containsPathFallbackAndSentinel() {
        let cmd = PeerHostDoctor.versionProbeCommand
        XCTAssertTrue(cmd.contains("command -v term-meshd"))
        XCTAssertTrue(cmd.contains("$HOME/.local/bin/term-meshd"))
        XCTAssertTrue(cmd.contains("--version"))
        XCTAssertTrue(cmd.contains("exit 44"))
        XCTAssertEqual(PeerHostDoctor.versionMissingExitCode, 44)
    }

    /// OS-aware unification: the Darwin branch must ask the app bundle
    /// for its own version rather than looking for term-meshd.
    func test_versionProbeCommand_containsDarwinAppBranch() {
        let cmd = PeerHostDoctor.versionProbeCommand
        XCTAssertTrue(cmd.contains(#"uname -s"#))
        XCTAssertTrue(cmd.contains("Darwin"))
        XCTAssertTrue(cmd.contains("/usr/bin/defaults read"))
        XCTAssertTrue(cmd.contains("/Applications/term-mesh.app/Contents/Info.plist"))
        XCTAssertTrue(cmd.contains("CFBundleShortVersionString"))
        XCTAssertTrue(cmd.contains("term-mesh-app"))
    }

    // MARK: - classifyVersionOutput (checkVersion's exit-code mapping, ssh-free)

    func test_classifyVersionOutput_missingBinaryExitCodeIsNil() {
        let result = PeerHostDoctor.classifyVersionOutput(
            exitCode: PeerHostDoctor.versionMissingExitCode,
            timedOut: false,
            stdout: ""
        )
        XCTAssertNil(result, "exit 44 (binary/app not found) must map to nil")
    }

    func test_classifyVersionOutput_timedOutIsNilEvenWithExitZero() {
        let result = PeerHostDoctor.classifyVersionOutput(
            exitCode: 0, timedOut: true, stdout: "term-meshd 1.2.3\n"
        )
        XCTAssertNil(result)
    }

    func test_classifyVersionOutput_otherNonZeroExitIsNil() {
        let result = PeerHostDoctor.classifyVersionOutput(
            exitCode: 127, timedOut: false, stdout: ""
        )
        XCTAssertNil(result)
    }

    func test_classifyVersionOutput_cleanLine() {
        let result = PeerHostDoctor.classifyVersionOutput(
            exitCode: 0, timedOut: false, stdout: "term-meshd 0.156.0\n"
        )
        XCTAssertEqual(result?.version, "0.156.0")
        XCTAssertEqual(result?.hostKind, .daemon)
    }

    /// Mac probe output: same classification path, but the `term-mesh-app`
    /// prefix must resolve to `.hostKind == .app` instead of `.daemon`.
    func test_classifyVersionOutput_macAppLine() {
        let result = PeerHostDoctor.classifyVersionOutput(
            exitCode: 0, timedOut: false, stdout: "term-mesh-app 0.159.0\n"
        )
        XCTAssertEqual(result?.version, "0.159.0")
        XCTAssertEqual(result?.hostKind, .app)
    }

    func test_classifyVersionOutput_motdPrefixedOutput_picksLastMatchingLine() {
        // A non-login shell can still echo a banner ahead of the real
        // command output; the LAST matching line wins.
        let stdout = """
        Welcome to Ubuntu 22.04 LTS
        term-meshd 0.9.0 (stale banner from a prior line, should not win)
        term-meshd 0.156.0
        """
        let result = PeerHostDoctor.classifyVersionOutput(
            exitCode: 0, timedOut: false, stdout: stdout
        )
        XCTAssertEqual(result?.version, "0.156.0")
        XCTAssertEqual(result?.hostKind, .daemon)
    }

    func test_classifyVersionOutput_noMatchingLineIsNil() {
        let result = PeerHostDoctor.classifyVersionOutput(
            exitCode: 0, timedOut: false, stdout: "unexpected garbage\n"
        )
        XCTAssertNil(result)
    }

    // MARK: - parseHostVersionLine (OS-aware: daemon vs app prefix)

    func test_parseHostVersionLine_daemonPrefix() {
        let result = PeerHostDoctor.parseHostVersionLine(from: "term-meshd 0.156.0\n")
        XCTAssertEqual(result?.version, "0.156.0")
        XCTAssertEqual(result?.hostKind, .daemon)
    }

    func test_parseHostVersionLine_appPrefix() {
        let result = PeerHostDoctor.parseHostVersionLine(from: "term-mesh-app 0.159.0\n")
        XCTAssertEqual(result?.version, "0.159.0")
        XCTAssertEqual(result?.hostKind, .app)
    }

    /// The two prefixes never legitimately co-occur in one real probe
    /// run (a single host only ever takes one branch), but the regex's
    /// "last match wins" behavior must still hold across either prefix
    /// consistently, not just within one.
    func test_parseHostVersionLine_lastMatchWinsAcrossMixedPrefixes() {
        let stdout = """
        term-meshd 0.9.0
        term-mesh-app 0.159.0
        """
        let result = PeerHostDoctor.parseHostVersionLine(from: stdout)
        XCTAssertEqual(result?.version, "0.159.0")
        XCTAssertEqual(result?.hostKind, .app)
    }

    func test_parseHostVersionLine_emptyStringIsNil() {
        XCTAssertNil(PeerHostDoctor.parseHostVersionLine(from: ""))
    }

    // MARK: - Host-kind fallback and install policy

    func test_parseHostKindLine_distinguishesDaemonAndApp() {
        XCTAssertEqual(PeerHostDoctor.parseHostKindLine(from: "term-meshd\n"), .daemon)
        XCTAssertEqual(PeerHostDoctor.parseHostKindLine(from: "term-mesh-app\n"), .app)
        XCTAssertNil(PeerHostDoctor.parseHostKindLine(from: "Darwin\n"))
    }

    func test_parseHostKindLine_ignoresMOTDAndUsesLastSentinel() {
        XCTAssertEqual(
            PeerHostDoctor.parseHostKindLine(
                from: "Welcome\nterm-mesh-app\nnoise\nterm-meshd\n"
            ),
            .daemon
        )
    }

    func test_forceReinstall_requiresConfirmedLinuxHost() {
        let state = PeerHostEditorView.DoctorState.relayFailed(
            socket: "/run/term-mesh.sock", message: "incompatible handshake"
        )
        XCTAssertTrue(PeerHostEditorView.shouldShowForceReinstallButton(
            isNew: false, hasTestedDraft: true, hostKind: .daemon,
            showsUpdateButton: false, doctorState: state
        ))
        XCTAssertFalse(PeerHostEditorView.shouldShowForceReinstallButton(
            isNew: false, hasTestedDraft: true, hostKind: .app,
            showsUpdateButton: false, doctorState: state
        ))
        XCTAssertFalse(PeerHostEditorView.shouldShowForceReinstallButton(
            isNew: false, hasTestedDraft: true, hostKind: nil,
            showsUpdateButton: false, doctorState: state
        ))
    }

    func test_forceReinstall_isAvailableInEditHostBeforeTest() {
        XCTAssertTrue(PeerHostEditorView.shouldShowForceReinstallButton(
            isNew: false, hasTestedDraft: false, hostKind: nil,
            showsUpdateButton: false, doctorState: .idle
        ))
        XCTAssertFalse(PeerHostEditorView.shouldShowForceReinstallButton(
            isNew: true, hasTestedDraft: false, hostKind: nil,
            showsUpdateButton: false, doctorState: .idle
        ))
    }

    func test_forceReinstall_doesNotCompeteWithUpdateAction() {
        XCTAssertFalse(PeerHostEditorView.shouldShowForceReinstallButton(
            isNew: false, hasTestedDraft: true, hostKind: .daemon, showsUpdateButton: true,
            doctorState: .updateAvailable(
                socket: "/run/term-mesh.sock", remote: "0.170.0", latest: "v0.178.0"
            )
        ))
    }

    func test_plainInstall_requiresDaemonMissingAndIsHiddenOnlyForMacs() {
        XCTAssertTrue(PeerHostEditorView.shouldShowInstallButton(
            hasTestedDraft: true, hostKind: .daemon, doctorState: .daemonMissing
        ))
        XCTAssertFalse(PeerHostEditorView.shouldShowInstallButton(
            hasTestedDraft: true, hostKind: .app, doctorState: .daemonMissing
        ))
        XCTAssertFalse(PeerHostEditorView.shouldShowInstallButton(
            hasTestedDraft: false, hostKind: .daemon, doctorState: .daemonMissing
        ))
        XCTAssertFalse(PeerHostEditorView.shouldShowInstallButton(
            hasTestedDraft: true, hostKind: .daemon, doctorState: .idle
        ))
    }

    /// The OS probe is a second SSH round trip, and it can fail on a host that
    /// is perfectly installable. It must not hold a veto over the ONE action
    /// `.daemonMissing` exists to offer: a nil kind there is "could not ask",
    /// not "not Linux", and Reinstall does not cover the gap because it
    /// requires a confirmed `.daemon`.
    func test_plainInstall_survivesAnInconclusiveHostKindProbe() {
        XCTAssertTrue(
            PeerHostEditorView.shouldShowInstallButton(
                hasTestedDraft: true, hostKind: nil, doctorState: .daemonMissing
            ),
            "an unknown host kind must not remove the only install path"
        )
        XCTAssertFalse(
            PeerHostEditorView.shouldShowForceReinstallButton(
                isNew: false, hasTestedDraft: true, hostKind: nil,
                showsUpdateButton: false, doctorState: .daemonMissing
            ),
            "reinstall stays gated on a confirmed Linux host, so it cannot stand in"
        )
    }

    // MARK: - parseVersionLine (back-compat daemon-only view)

    func test_parseVersionLine_trimsWhitespace() {
        XCTAssertEqual(
            PeerHostDoctor.parseVersionLine(from: "  term-meshd 1.0.0  \n"),
            "1.0.0"
        )
    }

    func test_parseVersionLine_emptyStringIsNil() {
        XCTAssertNil(PeerHostDoctor.parseVersionLine(from: ""))
    }

    /// `parseVersionLine` is documented as a daemon-only view — it must
    /// still resolve to a version when an app-prefixed line is the only
    /// match (it delegates to `parseHostVersionLine` under the hood),
    /// but callers relying on it never see which kind produced it.
    func test_parseVersionLine_alsoResolvesAppPrefixedVersion() {
        XCTAssertEqual(
            PeerHostDoctor.parseVersionLine(from: "term-mesh-app 0.159.0\n"),
            "0.159.0"
        )
    }

    // MARK: - Local end-to-end of the probe script body (no ssh)

    /// Runs the script body under /bin/sh exactly as a remote POSIX
    /// shell would, with PATH and HOME pointed at a scratch dir that
    /// has neither `term-meshd` on PATH nor `~/.local/bin/term-meshd`.
    /// Exercises the real fallback + sentinel logic, not just the
    /// string literal. Forces the non-Darwin (else) branch via a fake
    /// `uname` prepended to PATH — the suite always runs on a real
    /// macOS host, so without this override `uname -s` would genuinely
    /// report "Darwin" and the script would always skip these
    /// term-meshd fixtures for the Mac-app branch instead.
    func test_script_exits44WhenBinaryMissing() throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let unameDir = try fakeUnameDir(in: scratch, reporting: "Linux")

        let run = try runScriptBody(home: scratch, path: "\(unameDir):/usr/bin:/bin")
        XCTAssertEqual(run.exit, PeerHostDoctor.versionMissingExitCode,
                       "stdout: \(run.stdout) stderr: \(run.stderr)")
        XCTAssertEqual(run.stdout, "")
    }

    /// Same script, but with a fake `term-meshd` on PATH — proves the
    /// `command -v` branch is taken and its output flows through
    /// untouched.
    func test_script_printsVersionWhenOnPath() throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let unameDir = try fakeUnameDir(in: scratch, reporting: "Linux")

        let binDir = scratch + "/bin"
        try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        let fakeBinary = binDir + "/term-meshd"
        let script = "#!/bin/sh\necho \"term-meshd 9.9.9\"\n"
        try script.write(toFile: fakeBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary)

        let run = try runScriptBody(home: scratch, path: "\(unameDir):\(binDir):/usr/bin:/bin")
        XCTAssertEqual(run.exit, 0, "stderr: \(run.stderr)")
        XCTAssertEqual(run.stdout, "term-meshd 9.9.9")
        XCTAssertEqual(PeerHostDoctor.parseVersionLine(from: run.stdout), "9.9.9")
    }

    /// Same fallback, but reached via `~/.local/bin/term-meshd` instead
    /// of PATH — the non-login-ssh-PATH escape hatch the command exists
    /// for in the first place.
    func test_script_fallsBackToLocalBin() throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let unameDir = try fakeUnameDir(in: scratch, reporting: "Linux")

        let localBinDir = scratch + "/.local/bin"
        try FileManager.default.createDirectory(atPath: localBinDir, withIntermediateDirectories: true)
        let fakeBinary = localBinDir + "/term-meshd"
        let script = "#!/bin/sh\necho \"term-meshd 1.2.3\"\n"
        try script.write(toFile: fakeBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary)

        // Deliberately bare PATH (besides the fake uname) — command -v
        // must fail so the $HOME/.local/bin fallback is what's
        // exercised here.
        let run = try runScriptBody(home: scratch, path: "\(unameDir):/usr/bin:/bin")
        XCTAssertEqual(run.exit, 0, "stderr: \(run.stderr)")
        XCTAssertEqual(run.stdout, "term-meshd 1.2.3")
    }

    /// Darwin branch: reads the app bundle's own version instead of
    /// looking for term-meshd. The plist path is a fixed literal in the
    /// production command (security contract — every remote command is
    /// a fixed string, never built from per-host input), so this can't
    /// point at a scratch fixture; it runs against whatever is actually
    /// installed at /Applications/term-mesh.app on the test machine,
    /// skips when that's absent (e.g. a CI runner without the app
    /// installed), and is self-verifying against a live `defaults read`
    /// of the same plist rather than a hardcoded version string that
    /// would go stale every release.
    func test_script_darwinBranch_printsAppVersionFromPlist() throws {
        let plistPath = "/Applications/term-mesh.app/Contents/Info.plist"
        guard FileManager.default.fileExists(atPath: plistPath) else {
            throw XCTSkip("term-mesh.app not installed at /Applications — skipping live Darwin probe")
        }
        guard let expected = try readPlistVersion(plistPath), !expected.isEmpty else {
            throw XCTSkip("could not read CFBundleShortVersionString from the installed app — skipping")
        }

        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let unameDir = try fakeUnameDir(in: scratch, reporting: "Darwin")

        let run = try runScriptBody(home: scratch, path: "\(unameDir):/usr/bin:/bin")
        XCTAssertEqual(run.exit, 0, "stderr: \(run.stderr)")
        XCTAssertEqual(run.stdout, "term-mesh-app \(expected)")
        XCTAssertEqual(PeerHostDoctor.parseHostVersionLine(from: run.stdout)?.hostKind, .app)
        XCTAssertEqual(PeerHostDoctor.parseHostVersionLine(from: run.stdout)?.version, expected)
    }

    // MARK: - PeerDaemonVersion.parseComponents

    func test_parseComponents_plain() {
        XCTAssertEqual(PeerDaemonVersion.parseComponents("1.2.3"), [1, 2, 3])
    }

    func test_parseComponents_vPrefix() {
        XCTAssertEqual(PeerDaemonVersion.parseComponents("v1.2.3"), [1, 2, 3])
        XCTAssertEqual(PeerDaemonVersion.parseComponents("V0.156.0"), [0, 156, 0])
    }

    func test_parseComponents_prereleaseIsExcluded() {
        XCTAssertEqual(PeerDaemonVersion.parseComponents("1.2.3-rc1"), [1, 2, 3])
        XCTAssertEqual(PeerDaemonVersion.parseComponents("v1.2.3-beta.2"), [1, 2, 3])
    }

    func test_parseComponents_buildMetadataIsExcluded() {
        XCTAssertEqual(PeerDaemonVersion.parseComponents("1.2.3+build5"), [1, 2, 3])
    }

    func test_parseComponents_unparsableIsNil() {
        XCTAssertNil(PeerDaemonVersion.parseComponents("abc"))
        XCTAssertNil(PeerDaemonVersion.parseComponents(""))
        XCTAssertNil(PeerDaemonVersion.parseComponents("1.x.3"))
    }

    // MARK: - PeerDaemonVersion.compare (numeric, not lexicographic)

    func test_compare_digitBoundary_notLexicographic() {
        // A string compare would put "0.157.9" AFTER "0.157.100" ("9" >
        // "1" as characters) — the numeric comparison must not. Both
        // sides sit at/above versionSyncFloor so this exercises the
        // precise-comparison branch, not the legacy short-circuit.
        XCTAssertEqual(
            PeerDaemonVersion.compare(installed: "0.157.9", latest: "0.157.100"),
            .outdated(latest: "0.157.100")
        )
    }

    func test_compare_sameVersionIsUpToDate() {
        // Above versionSyncFloor, so this exercises the precise
        // comparison branch rather than the legacy short-circuit.
        XCTAssertEqual(
            PeerDaemonVersion.compare(installed: "0.160.0", latest: "v0.160.0"),
            .upToDate
        )
    }

    // MARK: - PeerDaemonVersion.compare — versionSyncFloor / .legacy

    func test_versionSyncFloor_isParsable() {
        // Precondition the compare() implementation force-unwraps —
        // guards against a future edit turning the floor literal into
        // something parseComponents can't handle.
        XCTAssertNotNil(PeerDaemonVersion.parseComponents(PeerDaemonVersion.versionSyncFloor))
    }

    func test_compare_belowSyncFloor_isLegacy() {
        // The real-world case that motivated this: a daemon reporting
        // "0.72.0" predates the version-sync release and used an
        // unrelated Cargo numbering scheme entirely — numeric ordering
        // against a v0.156.x app release tag is not a meaningful
        // "outdated" signal (or "up to date" — either would be a
        // coincidence), so this must NOT be .outdated/.upToDate.
        XCTAssertEqual(
            PeerDaemonVersion.compare(installed: "0.72.0", latest: "0.156.0"),
            .legacy(latest: "0.156.0")
        )
    }

    func test_compare_belowSyncFloor_isLegacyEvenWhenNumericallyAheadOfLatest() {
        // Guards against a naive "legacy iff outdated" implementation:
        // a legacy build can numerically exceed `latest` (unrelated
        // series) and must still report .legacy, not .upToDate.
        XCTAssertEqual(
            PeerDaemonVersion.compare(installed: "0.72.0", latest: "0.50.0"),
            .legacy(latest: "0.50.0")
        )
    }

    func test_compare_atSyncFloor_isPreciseNotLegacy() {
        // installed == versionSyncFloor is NOT "below floor" — the
        // sync release itself must get the precise comparison, not the
        // legacy tone.
        XCTAssertEqual(
            PeerDaemonVersion.compare(
                installed: PeerDaemonVersion.versionSyncFloor,
                latest: PeerDaemonVersion.versionSyncFloor
            ),
            .upToDate
        )
    }

    func test_compare_aboveSyncFloor_belowLatestIsOutdated() {
        XCTAssertEqual(
            PeerDaemonVersion.compare(installed: "0.157.0", latest: "0.160.0"),
            .outdated(latest: "0.160.0")
        )
    }

    func test_compare_installedNewerThanLatestIsUpToDate() {
        // Not "outdated" — a locally-built dev daemon ahead of the
        // latest tagged release must not trigger an update prompt.
        XCTAssertEqual(
            PeerDaemonVersion.compare(installed: "1.0.0", latest: "0.156.0"),
            .upToDate
        )
    }

    func test_compare_shorterComponentsPadWithZero() {
        XCTAssertEqual(
            PeerDaemonVersion.compare(installed: "1.2", latest: "1.2.0"),
            .upToDate
        )
    }

    func test_compare_unparsableEitherSideIsUnknown() {
        XCTAssertEqual(
            PeerDaemonVersion.compare(installed: "garbage", latest: "0.156.0"),
            .unknown
        )
        XCTAssertEqual(
            PeerDaemonVersion.compare(installed: "0.156.0", latest: "garbage"),
            .unknown
        )
    }

    // MARK: - PeerDaemonVersion.parseTagFromReleaseURL (API-free fallback)

    func test_parseTagFromReleaseURL_extractsTagFromRedirectTarget() {
        XCTAssertEqual(
            PeerDaemonVersion.parseTagFromReleaseURL(
                "https://github.com/x-mesh/term-mesh/releases/tag/v0.178.0"
            ),
            "v0.178.0"
        )
    }

    /// A repo with no published releases never redirects, so the final
    /// URL is still `…/releases/latest`. Inventing a tag from that would
    /// be compared against the host's real version and reported as an
    /// available update — nil is the only honest answer.
    func test_parseTagFromReleaseURL_unredirectedLatestIsNil() {
        XCTAssertNil(
            PeerDaemonVersion.parseTagFromReleaseURL(
                "https://github.com/x-mesh/term-mesh/releases/latest"
            )
        )
        XCTAssertNil(PeerDaemonVersion.parseTagFromReleaseURL(""))
        XCTAssertNil(
            PeerDaemonVersion.parseTagFromReleaseURL("https://github.com/x-mesh/term-mesh")
        )
    }

    /// A trailing path segment means this is not the tag page itself
    /// (`…/tag/v1.0.0/whatever`), and a bare `…/tag/` carries no tag.
    func test_parseTagFromReleaseURL_rejectsNonTerminalAndEmptyTag() {
        XCTAssertNil(
            PeerDaemonVersion.parseTagFromReleaseURL(
                "https://github.com/x-mesh/term-mesh/releases/tag/v0.178.0/files"
            )
        )
        XCTAssertNil(
            PeerDaemonVersion.parseTagFromReleaseURL(
                "https://github.com/x-mesh/term-mesh/releases/tag/"
            )
        )
    }

    func test_parseTagFromReleaseURL_stripsQueryAndFragment() {
        XCTAssertEqual(
            PeerDaemonVersion.parseTagFromReleaseURL(
                "https://github.com/x-mesh/term-mesh/releases/tag/v0.178.0?foo=1"
            ),
            "v0.178.0"
        )
        XCTAssertEqual(
            PeerDaemonVersion.parseTagFromReleaseURL(
                "https://github.com/x-mesh/term-mesh/releases/tag/v0.178.0#notes"
            ),
            "v0.178.0"
        )
    }

    /// The parsed tag feeds straight into `compare`, so it has to come
    /// out in a shape that parses — this is the whole contract between
    /// the fallback and the version comparison.
    func test_parseTagFromReleaseURL_resultComparesAsOutdated() {
        guard let tag = PeerDaemonVersion.parseTagFromReleaseURL(
            "https://github.com/x-mesh/term-mesh/releases/tag/v0.178.0"
        ) else {
            return XCTFail("expected a tag")
        }
        XCTAssertEqual(
            PeerDaemonVersion.compare(installed: "0.170.2", latest: tag),
            .outdated(latest: "v0.178.0")
        )
    }

    // MARK: - PeerHostDoctor.waitForExit (runRemote's SIGTERM→SIGKILL escalation)

    /// Exercises the exact building block runRemote's timeout branch
    /// relies on to stay bounded: an ssh child that ignores SIGTERM
    /// outright is a documented hazard (see PeerSocketProber.probe's
    /// identical escalation) — without it, runRemote would await pipe
    /// EOF that never arrives and hang past its stated timeoutSeconds.
    /// SIG_IGN survives exec, so a plain `sh -c 'trap "" TERM; sleep N'`
    /// reproduces a SIGTERM-ignoring child without any special binary.
    func test_waitForExit_escalatesPastSigtermIgnoringChild() async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "trap '' TERM; sleep 30"]
        try proc.run()
        defer { if proc.isRunning { kill(proc.processIdentifier, SIGKILL) } }

        // Let the trap install before signaling.
        try await Task.sleep(nanoseconds: 100_000_000)
        proc.terminate()

        let exitedAfterTerm = await PeerHostDoctor.waitForExit(proc, timeout: 0.5)
        XCTAssertFalse(exitedAfterTerm, "child traps SIGTERM — must still be running")
        XCTAssertTrue(proc.isRunning)

        kill(proc.processIdentifier, SIGKILL)
        let exitedAfterKill = await PeerHostDoctor.waitForExit(proc, timeout: 2.0)
        XCTAssertTrue(exitedAfterKill, "SIGKILL must reap even a SIGTERM-ignoring child")
    }

    func test_waitForExit_trueWhenAlreadyExited() async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "exit 0"]
        try proc.run()
        proc.waitUntilExit()

        let exited = await PeerHostDoctor.waitForExit(proc, timeout: 1.0)
        XCTAssertTrue(exited)
    }

    /// The picker labels a host with whatever the serving process answers in
    /// the Hello handshake. The app-hosted server used to answer a hardcoded
    /// "debug-server" — on every build, updated or not.
    func test_appHostedServerAdvertisesTheBundleVersionNotAPlaceholder() {
        let version = PeerHostCoordinator.advertisedAppVersion(
            bundle: Bundle(for: PeerHostCoordinator.self)
        )
        XCTAssertNotNil(
            PeerDaemonVersion.parseComponents(version),
            "must be a real X.Y.Z version, got: \(version)"
        )
        XCTAssertNotEqual(version, "0.0.0", "the fallback must not be what ships")
        XCTAssertNotEqual(version, "debug-server")
    }

    /// The raw plist value is untrusted: whitespace-only must fall back like
    /// a missing key (advertising " \n" verbatim is how a picker shows an
    /// empty version chip), and surrounding whitespace must not survive into
    /// the wire string a client parses.
    func test_advertisedAppVersionTrimsAndFallsBackHonestly() {
        XCTAssertEqual(PeerHostCoordinator.advertisedAppVersion(rawBundleVersion: nil), "0.0.0")
        XCTAssertEqual(PeerHostCoordinator.advertisedAppVersion(rawBundleVersion: " \n"), "0.0.0")
        XCTAssertEqual(
            PeerHostCoordinator.advertisedAppVersion(rawBundleVersion: " 0.194.0 "),
            "0.194.0"
        )
    }

    // MARK: - Helpers (mirrors PeerSocketProberTests' local script runner)

    private func makeScratchDir() throws -> String {
        let path = "/tmp/pdv-test-\(getpid())-\(UInt32.random(in: 0..<0xFFFF))"
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true
        )
        return path
    }

    private struct ScriptRun {
        let exit: Int32
        let stdout: String
        let stderr: String
    }

    private func runScriptBody(home: String, path: String) throws -> ScriptRun {
        let cmd = PeerHostDoctor.versionProbeCommand
        let body = String(cmd.dropFirst("sh -c '".count).dropLast(1))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", body]
        proc.environment = ["HOME": home, "PATH": path]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        let stdout = String(
            data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        return ScriptRun(
            exit: proc.terminationStatus,
            stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Creates a scratch bin dir containing a fake `uname` that always
    /// prints `os` regardless of arguments (the script only ever calls
    /// `uname -s`) — lets the Linux/Darwin branch of
    /// `versionProbeCommand` be exercised deterministically. Without
    /// this override, `uname -s` on the actual test host (always macOS
    /// per this project's build/test conventions) would genuinely
    /// report "Darwin" and the else (Linux) branch could never be
    /// reached via a live shell run.
    private func fakeUnameDir(in scratch: String, reporting os: String) throws -> String {
        let dir = scratch + "/fakeuname"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let bin = dir + "/uname"
        try "#!/bin/sh\necho \"\(os)\"\n".write(toFile: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin)
        return dir
    }

    /// Reads a plist key via the real `/usr/bin/defaults` — used only
    /// to make `test_script_darwinBranch_printsAppVersionFromPlist`
    /// self-verifying against whatever is actually installed, instead
    /// of asserting a hardcoded version string that would go stale
    /// every release. Returns nil on any read failure.
    private func readPlistVersion(_ plistPath: String) throws -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        proc.arguments = ["read", plistPath, "CFBundleShortVersionString"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
