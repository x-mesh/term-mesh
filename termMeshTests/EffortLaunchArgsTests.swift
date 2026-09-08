import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// Per-agent/leader reasoning-effort setting: the spawn-arg translation, the
/// allowed-value normalization, and the backward-compat decode for presets
/// written before the `effort` field existed.
@MainActor
final class EffortLaunchArgsTests: XCTestCase {
    // MARK: - TeamOrchestrator.effortLaunchArgs

    func testEffortLaunchArgsClaudeUsesEffortFlag() {
        XCTAssertEqual(
            TeamOrchestrator.effortLaunchArgs(cli: "claude", effort: "high"),
            ["--effort", "high"]
        )
    }

    func testEffortLaunchArgsKiroUsesEffortFlag() {
        XCTAssertEqual(
            TeamOrchestrator.effortLaunchArgs(cli: "kiro", effort: "xhigh"),
            ["--effort", "xhigh"]
        )
    }

    func testEffortLaunchArgsCodexUsesConfigOverride() {
        XCTAssertEqual(
            TeamOrchestrator.effortLaunchArgs(cli: "codex", effort: "max"),
            ["-c", "model_reasoning_effort=max"]
        )
    }

    func testEffortLaunchArgsIgnoredForUnsupportedCLIs() {
        for cli in ["gemini", "cursor", "agy", "repl"] {
            XCTAssertEqual(
                TeamOrchestrator.effortLaunchArgs(cli: cli, effort: "high"),
                [],
                cli
            )
        }
    }

    func testEffortLaunchArgsEmptyProducesNoArgsForAnyCLI() {
        for cli in ["claude", "kiro", "codex", "gemini"] {
            XCTAssertEqual(
                TeamOrchestrator.effortLaunchArgs(cli: cli, effort: ""),
                [],
                cli
            )
        }
    }

    // MARK: - Codex tier -> effort fallback (used only when no explicit effort is set)

    func testCodexReasoningEffortTierFallback() {
        XCTAssertEqual(TeamOrchestrator.codexReasoningEffort("opus"), "high")
        XCTAssertEqual(TeamOrchestrator.codexReasoningEffort("sonnet"), "medium")
        XCTAssertEqual(TeamOrchestrator.codexReasoningEffort("haiku"), "low")
        XCTAssertNil(TeamOrchestrator.codexReasoningEffort("gpt-5.6-sol"))
    }

    // MARK: - AgentRolePreset.normalizeEffort

    func testNormalizeEffortAcceptsKnownValuesCaseInsensitively() {
        XCTAssertEqual(AgentRolePreset.normalizeEffort("HIGH", for: "claude"), "high")
        XCTAssertEqual(AgentRolePreset.normalizeEffort("Medium", for: "codex"), "medium")
        XCTAssertEqual(AgentRolePreset.normalizeEffort("xhigh", for: "kiro"), "xhigh")
    }

    func testNormalizeEffortRejectsUnknownValue() {
        XCTAssertEqual(AgentRolePreset.normalizeEffort("ultra", for: "claude"), "")
    }

    func testNormalizeEffortRejectsUnsupportedCLIRegardlessOfValue() {
        XCTAssertEqual(AgentRolePreset.normalizeEffort("high", for: "gemini"), "")
        XCTAssertEqual(AgentRolePreset.normalizeEffort("high", for: "cursor"), "")
    }

    func testSupportsEffortMatchesEffortsList() {
        XCTAssertTrue(AgentRolePreset.supportsEffort(cli: "claude"))
        XCTAssertTrue(AgentRolePreset.supportsEffort(cli: "kiro"))
        XCTAssertTrue(AgentRolePreset.supportsEffort(cli: "codex"))
        XCTAssertFalse(AgentRolePreset.supportsEffort(cli: "gemini"))
    }

    // MARK: - Archive/preset persist round-trip: legacy data with no `effort` key

    /// A preset written before this field existed has no `effort` key at all.
    /// The synthesized decoder must fall back to the property's default ("")
    /// rather than fail the whole decode.
    func testAgentRolePresetDecodesLegacyDataMissingEffortAsEmpty() throws {
        let json = """
        {
            "id": "8C1F1A9E-6B9B-4B8E-9C1A-1E2B3C4D5E6F",
            "name": "executor",
            "displayName": "Executor",
            "cli": "claude",
            "model": "sonnet",
            "color": "green",
            "instructions": "",
            "isBuiltIn": false
        }
        """
        let preset = try JSONDecoder().decode(AgentRolePreset.self, from: Data(json.utf8))
        XCTAssertEqual(preset.effort, "")
    }

    /// The forward direction: a preset that does carry `effort` round-trips
    /// through encode/decode unchanged.
    func testAgentRolePresetRoundTripsExplicitEffort() throws {
        var preset = AgentRolePreset(name: "reviewer", cli: "codex", model: "opus")
        preset.effort = "high"
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(AgentRolePreset.self, from: data)
        XCTAssertEqual(decoded.effort, "high")
    }
}
