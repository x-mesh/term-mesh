import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

final class PeerDaemonVersionTests: XCTestCase {

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

    // MARK: - classifyVersionOutput (checkVersion's exit-code mapping, ssh-free)

    func test_classifyVersionOutput_missingBinaryExitCodeIsNil() {
        let result = PeerHostDoctor.classifyVersionOutput(
            exitCode: PeerHostDoctor.versionMissingExitCode,
            timedOut: false,
            stdout: ""
        )
        XCTAssertNil(result, "exit 44 (binary not found) must map to nil")
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
        XCTAssertEqual(result, "0.156.0")
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
        XCTAssertEqual(result, "0.156.0")
    }

    func test_classifyVersionOutput_noMatchingLineIsNil() {
        let result = PeerHostDoctor.classifyVersionOutput(
            exitCode: 0, timedOut: false, stdout: "unexpected garbage\n"
        )
        XCTAssertNil(result)
    }

    // MARK: - parseVersionLine

    func test_parseVersionLine_trimsWhitespace() {
        XCTAssertEqual(
            PeerHostDoctor.parseVersionLine(from: "  term-meshd 1.0.0  \n"),
            "1.0.0"
        )
    }

    func test_parseVersionLine_emptyStringIsNil() {
        XCTAssertNil(PeerHostDoctor.parseVersionLine(from: ""))
    }

    // MARK: - Local end-to-end of the probe script body (no ssh)

    /// Runs the script body under /bin/sh exactly as a remote POSIX
    /// shell would, with PATH and HOME pointed at a scratch dir that
    /// has neither `term-meshd` on PATH nor `~/.local/bin/term-meshd`.
    /// Exercises the real fallback + sentinel logic, not just the
    /// string literal.
    func test_script_exits44WhenBinaryMissing() throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let run = try runScriptBody(home: scratch, path: "/usr/bin:/bin")
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

        let binDir = scratch + "/bin"
        try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        let fakeBinary = binDir + "/term-meshd"
        let script = "#!/bin/sh\necho \"term-meshd 9.9.9\"\n"
        try script.write(toFile: fakeBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary)

        let run = try runScriptBody(home: scratch, path: "\(binDir):/usr/bin:/bin")
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

        let localBinDir = scratch + "/.local/bin"
        try FileManager.default.createDirectory(atPath: localBinDir, withIntermediateDirectories: true)
        let fakeBinary = localBinDir + "/term-meshd"
        let script = "#!/bin/sh\necho \"term-meshd 1.2.3\"\n"
        try script.write(toFile: fakeBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary)

        // Deliberately bare PATH — command -v must fail so the
        // $HOME/.local/bin fallback is what's exercised here.
        let run = try runScriptBody(home: scratch, path: "/usr/bin:/bin")
        XCTAssertEqual(run.exit, 0, "stderr: \(run.stderr)")
        XCTAssertEqual(run.stdout, "term-meshd 1.2.3")
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
        // A string compare would put "0.9.0" AFTER "0.100.0" ("9" > "1"
        // as characters) — the numeric comparison must not.
        XCTAssertEqual(
            PeerDaemonVersion.compare(installed: "0.9.0", latest: "0.100.0"),
            .outdated(latest: "0.100.0")
        )
    }

    func test_compare_sameVersionIsUpToDate() {
        XCTAssertEqual(
            PeerDaemonVersion.compare(installed: "0.156.0", latest: "v0.156.0"),
            .upToDate
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
}
