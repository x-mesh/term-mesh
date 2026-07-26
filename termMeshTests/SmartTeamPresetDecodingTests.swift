import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// A `SmartTeamPreset` (and the custom-template store around it) is read back
/// from disk long after it was written, sometimes by a build that shipped
/// months after the one that wrote the file. Both directions have to hold:
/// a file from an older build must still decode, and a newer field must not
/// break an older decoder. These tests pin both directions down explicitly
/// rather than leaving them to be discovered by a user's crash report.
final class SmartTeamPresetDecodingTests: XCTestCase {
    private let iso8601Decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - ProviderPreference / SmartTeamPreset

    /// `primaryModel`/`fallbackModel` are optional ("nil = use CLI default"),
    /// so a preference written before a role had a pinned model must still
    /// decode rather than fail the whole preset.
    func testProviderPreferenceDecodesWithoutOptionalModelKeys() throws {
        let json = """
        {
            "role": "explorer",
            "primaryCli": "claude",
            "fallbackCli": "claude",
            "reason": "Fast lookups"
        }
        """
        let pref = try iso8601Decoder.decode(ProviderPreference.self, from: Data(json.utf8))

        XCTAssertEqual(pref.role, "explorer")
        XCTAssertEqual(pref.primaryCli, "claude")
        XCTAssertNil(pref.primaryModel)
        XCTAssertEqual(pref.fallbackCli, "claude")
        XCTAssertNil(pref.fallbackModel)
    }

    /// A whole preset saved before per-role models existed: every agent slot
    /// omits primaryModel/fallbackModel.
    func testSmartTeamPresetDecodesFromMinimalLegacyJSON() throws {
        let json = """
        {
            "id": "standard",
            "name": "Standard",
            "icon": "person.3",
            "description": "General development",
            "leaderMode": "claude",
            "agents": [
                {"role": "explorer", "primaryCli": "claude", "fallbackCli": "claude", "reason": "Fast lookups"},
                {"role": "executor", "primaryCli": "claude", "fallbackCli": "claude", "reason": "Best general coding"}
            ]
        }
        """
        let preset = try iso8601Decoder.decode(SmartTeamPreset.self, from: Data(json.utf8))

        XCTAssertEqual(preset.id, "standard")
        XCTAssertEqual(preset.agents.count, 2)
        XCTAssertTrue(preset.agents.allSatisfy { $0.primaryModel == nil && $0.fallbackModel == nil })
    }

    /// An unrecognized top-level field (e.g. added by a newer build) must not
    /// break decoding on this build — the store has to survive a downgrade.
    func testSmartTeamPresetIgnoresUnknownFutureField() throws {
        let json = """
        {
            "id": "standard",
            "name": "Standard",
            "icon": "person.3",
            "description": "General development",
            "leaderMode": "claude",
            "agents": [],
            "futureField": {"nested": true}
        }
        """
        let preset = try iso8601Decoder.decode(SmartTeamPreset.self, from: Data(json.utf8))
        XCTAssertEqual(preset.id, "standard")
        XCTAssertEqual(preset.agents.count, 0)
    }

    /// The tagged-union payload (`type` discriminator + one of
    /// smart/workflow/quick) has a hand-written init/encode — round-trip it
    /// explicitly so a future edit to that pair is caught immediately rather
    /// than only when a saved custom preset silently loses its agents.
    func testTeamTemplatePayloadRoundTripsSmartCase() throws {
        let preset = SmartTeamPreset(
            id: "custom-1", name: "Custom", icon: "person.3", description: "d",
            leaderMode: "claude",
            agents: [
                ProviderPreference(role: "executor", primaryCli: "claude", primaryModel: "sonnet",
                                    fallbackCli: "claude", fallbackModel: "sonnet", reason: "r")
            ]
        )
        let template = TeamTemplate(
            id: TemplateID(category: .smart, slug: "custom-1"),
            origin: .custom,
            name: "Custom",
            createdAt: Date(timeIntervalSince1970: 0),
            payload: .smart(preset)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(template)
        let decoded = try iso8601Decoder.decode(TeamTemplate.self, from: data)

        XCTAssertEqual(decoded, template)
        guard case .smart(let decodedPreset) = decoded.payload else {
            return XCTFail("expected .smart payload")
        }
        XCTAssertEqual(decodedPreset.agents.first?.primaryModel, "sonnet")
    }

    // MARK: - UserCustomTemplateStore (the custom-snapshot store on disk)

    /// A store written before `overrides` existed: no "overrides" key at all,
    /// no "schema" key either (the field itself is newer than schema 1).
    /// `init(from:)` must default schema to 1 → bumped to 2, and overrides to [].
    func testUserCustomTemplateStoreDecodesLegacyJSONMissingSchemaAndOverridesKeys() throws {
        let json = """
        {
            "pinnedId": null,
            "lastSelectedId": null,
            "customs": []
        }
        """
        let store = try iso8601Decoder.decode(UserCustomTemplateStore.self, from: Data(json.utf8))

        XCTAssertEqual(store.schema, 2, "missing schema key must be treated as schema 1, then bumped to 2")
        XCTAssertEqual(store.overrides, [])
        XCTAssertEqual(store.customs, [])
    }

    /// A schema-1 store that does have `customs` populated but still predates
    /// `overrides` — the customs must survive the decode untouched.
    func testUserCustomTemplateStoreDecodesLegacySchema1WithCustomsButNoOverrides() throws {
        let json = """
        {
            "schema": 1,
            "pinnedId": null,
            "lastSelectedId": {"category": "smart", "slug": "legacy-custom"},
            "customs": [
                {
                    "id": {"category": "smart", "slug": "legacy-custom"},
                    "origin": "custom",
                    "name": "Legacy Custom",
                    "createdAt": "2024-01-01T00:00:00Z",
                    "schema": 1,
                    "payload": {
                        "type": "smart",
                        "smart": {
                            "id": "legacy-custom",
                            "name": "Legacy Custom",
                            "icon": "person.3",
                            "description": "",
                            "leaderMode": "claude",
                            "agents": []
                        }
                    }
                }
            ]
        }
        """
        let store = try iso8601Decoder.decode(UserCustomTemplateStore.self, from: Data(json.utf8))

        XCTAssertEqual(store.schema, 2)
        XCTAssertEqual(store.overrides, [])
        XCTAssertEqual(store.customs.count, 1)
        XCTAssertEqual(store.customs.first?.name, "Legacy Custom")
        XCTAssertEqual(store.lastSelectedId, TemplateID(category: .smart, slug: "legacy-custom"))
    }

    // MARK: - TeamTemplateManager (the injectable seam over the store file)

    /// `TeamTemplateManager(catalog:fileURL:)` takes the store location as a
    /// parameter, which is what makes this migration testable at all without
    /// touching the app's real Application Support directory. A legacy file
    /// on disk (schema 1, no "overrides" key) must load with its custom intact
    /// AND get rewritten to schema 2 on init, since `storeNeedsSchema2Rewrite`
    /// gates that migration on exactly those two conditions.
    func testTeamTemplateManagerMigratesLegacyStoreFileOnInit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("team-templates.custom.json")

        let legacyJSON = """
        {
            "schema": 1,
            "pinnedId": null,
            "lastSelectedId": null,
            "customs": [
                {
                    "id": {"category": "smart", "slug": "legacy-custom"},
                    "origin": "custom",
                    "name": "Legacy Custom",
                    "createdAt": "2024-01-01T00:00:00Z",
                    "schema": 1,
                    "payload": {
                        "type": "smart",
                        "smart": {
                            "id": "legacy-custom",
                            "name": "Legacy Custom",
                            "icon": "person.3",
                            "description": "",
                            "leaderMode": "claude",
                            "agents": []
                        }
                    }
                }
            ]
        }
        """
        try Data(legacyJSON.utf8).write(to: fileURL)

        let manager = TeamTemplateManager(catalog: .fallback, fileURL: fileURL)

        XCTAssertEqual(manager.customTemplates.count, 1)
        XCTAssertEqual(manager.customTemplates.first?.name, "Legacy Custom")

        // The migration is expected to have rewritten the file in place.
        let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        XCTAssertEqual(rewritten?["schema"] as? Int, 2)
        XCTAssertNotNil(rewritten?["overrides"], "schema-2 rewrite must add the overrides key")
    }

    /// Round-trip through a fresh manager instance pointed at the same file —
    /// the actual persistence contract behind "custom snapshot storage",
    /// independent of the legacy-migration path above.
    func testTeamTemplateManagerPersistsCustomAcrossInstances() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("team-templates.custom.json")

        let first = TeamTemplateManager(catalog: .fallback, fileURL: fileURL)
        let newId = first.createBlankSmartPreset(name: "My Team")

        let second = TeamTemplateManager(catalog: .fallback, fileURL: fileURL)

        XCTAssertNotNil(second.template(for: newId))
        XCTAssertEqual(second.template(for: newId)?.name, "My Team")
    }
}
