import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// `TeamTask.route` and `TeamTask.waveId` are measurement-only fields: nothing
/// validates a value and no behaviour depends on one. What must hold is that
/// they are honest — a stated value survives persistence verbatim, and an
/// unstated one stays distinguishable from a guess. The 33 boards already on
/// disk were written without either field, so a decode that invented a value
/// for them would poison the very distribution the fields exist to measure.
final class RoutingInstrumentationTests: XCTestCase {
    private let store = TeamDataStore.shared
    private var teamNames: [String] = []

    override func tearDown() {
        for teamName in teamNames {
            store.unregisterTeam(teamName)
        }
        teamNames.removeAll()
        super.tearDown()
    }

    private func registerTeam() -> String {
        let name = "routing-instr-\(UUID().uuidString)"
        store.registerTeam(name, agentNames: ["executor", "reviewer"])
        teamNames.append(name)
        return name
    }

    // MARK: - Stated values round-trip

    func testStatedRouteAndWaveSurviveCreateAndDictionary() throws {
        let team = registerTeam()
        let wave = "wave-\(UUID().uuidString)"

        let task = try XCTUnwrap(store.createTask(
            teamName: team, title: "owned lane A", assignee: "executor",
            route: "parallel", waveId: wave
        ))

        XCTAssertEqual(task.route, "parallel")
        XCTAssertEqual(task.waveId, wave)

        let dict = store.taskDictionary(task)
        XCTAssertEqual(dict["route"] as? String, "parallel")
        XCTAssertEqual(dict["wave_id"] as? String, wave)
    }

    func testTasksOfOneWaveShareTheWaveIdSoSizeIsAGroupBy() throws {
        let team = registerTeam()
        let wave = "wave-\(UUID().uuidString)"

        _ = try XCTUnwrap(store.createTask(
            teamName: team, title: "lane A", assignee: "executor",
            route: "parallel", waveId: wave
        ))
        _ = try XCTUnwrap(store.createTask(
            teamName: team, title: "lane B", assignee: "reviewer",
            route: "parallel", waveId: wave
        ))
        // A second, unrelated dispatch. Clock proximity would fold this into
        // the first wave; a stated id must not.
        _ = try XCTUnwrap(store.createTask(
            teamName: team, title: "later single", assignee: "executor",
            route: "direct", waveId: "wave-\(UUID().uuidString)"
        ))

        let grouped = Dictionary(grouping: store.listTasks(teamName: team)) { $0.waveId }
        XCTAssertEqual(grouped[wave]?.count, 2)
        XCTAssertEqual(grouped.count, 2)
    }

    // MARK: - Unstated stays unstated

    func testUnstatedFieldsAreNilAndTelemetryMarksThemUnstated() throws {
        let team = registerTeam()

        let task = try XCTUnwrap(store.createTask(
            teamName: team, title: "no route stated", assignee: "executor"
        ))

        XCTAssertNil(task.route)
        XCTAssertNil(task.waveId)

        let dict = store.taskDictionary(task)
        XCTAssertTrue(dict["route"] is NSNull)
        XCTAssertTrue(dict["wave_id"] is NSNull)

        // `parallel_telemetry.wave_id` falls back to a task identity so the
        // field is always answerable, which is exactly why the reader needs the
        // companion flag to know it is not a wave.
        let telemetry = try XCTUnwrap(dict["parallel_telemetry"] as? [String: Any])
        XCTAssertEqual(telemetry["wave_id"] as? String, task.id)
        XCTAssertEqual(telemetry["wave_id_stated"] as? Bool, false)
    }

    func testStatedWaveIsReportedAsStatedInTelemetry() throws {
        let team = registerTeam()
        let wave = "wave-\(UUID().uuidString)"

        let task = try XCTUnwrap(store.createTask(
            teamName: team, title: "stated", assignee: "executor",
            route: "probe", waveId: wave
        ))

        let telemetry = try XCTUnwrap(
            store.taskDictionary(task)["parallel_telemetry"] as? [String: Any]
        )
        XCTAssertEqual(telemetry["wave_id"] as? String, wave)
        XCTAssertEqual(telemetry["wave_id_stated"] as? Bool, true)
    }

    func testBlankStringsNormalizeToNilRatherThanAnEmptyRoute() throws {
        let team = registerTeam()

        let task = try XCTUnwrap(store.createTask(
            teamName: team, title: "blank", assignee: "executor",
            route: "   ", waveId: ""
        ))

        XCTAssertNil(task.route)
        XCTAssertNil(task.waveId)
    }

    func testRouteIsRecordedVerbatimWithoutValidation() throws {
        let team = registerTeam()

        // Deliberately not one of direct/probe/parallel. The store is a
        // recorder, not a gate: rejecting here would silently drop the exact
        // anomalies worth seeing in the data.
        let task = try XCTUnwrap(store.createTask(
            teamName: team, title: "unknown route", assignee: "executor",
            route: "hybrid-experiment"
        ))

        XCTAssertEqual(task.route, "hybrid-experiment")
    }

    // MARK: - RPC wire boundary

    /// All three task-create/delegate handlers read these two fields through
    /// one helper, so the wire contract is pinned here rather than by reading it
    /// off a running app — the control socket refuses connections from processes
    /// that are not term-mesh descendants, which makes a live probe unavailable
    /// from a test.
    func testWireFieldsAreReadVerbatimAndBlankBecomesUnstated() {
        let stated = TerminalController.routingMeasurement(
            from: ["route": "parallel", "wave_id": "wave-9"]
        )
        XCTAssertEqual(stated.route, "parallel")
        XCTAssertEqual(stated.waveId, "wave-9")

        let absent = TerminalController.routingMeasurement(from: [:])
        XCTAssertNil(absent.route)
        XCTAssertNil(absent.waveId)

        let blank = TerminalController.routingMeasurement(
            from: ["route": "   ", "wave_id": ""]
        )
        XCTAssertNil(blank.route, "a blank route must not read as a stated classification")
        XCTAssertNil(blank.waveId)

        let wrongType = TerminalController.routingMeasurement(
            from: ["route": 42, "wave_id": ["nope"]]
        )
        XCTAssertNil(wrongType.route)
        XCTAssertNil(wrongType.waveId)
    }

    func testOneFieldMayBeStatedWithoutTheOther() {
        let routeOnly = TerminalController.routingMeasurement(from: ["route": "direct"])
        XCTAssertEqual(routeOnly.route, "direct")
        XCTAssertNil(routeOnly.waveId)

        let waveOnly = TerminalController.routingMeasurement(from: ["wave_id": "wave-3"])
        XCTAssertNil(waveOnly.route)
        XCTAssertEqual(waveOnly.waveId, "wave-3")
    }

    // MARK: - Backward compatibility with boards written before these fields

    func testLegacyBoardTaskJSONWithoutTheFieldsDecodesWithNil() throws {
        // A trimmed but structurally real task as written before `route` and
        // `waveId` existed. Absence must decode, and must decode to nil.
        let legacy = """
        {
          "id": "task-legacy-1",
          "title": "written before routing instrumentation",
          "acceptanceCriteria": [],
          "labels": [],
          "status": "completed",
          "priority": 2,
          "dependsOn": [],
          "childTaskIds": [],
          "reassignmentCount": 0,
          "createdBy": "leader",
          "createdAt": "2026-08-01T10:00:00Z",
          "updatedAt": "2026-08-01T10:05:00Z"
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let task = try decoder.decode(
            TeamOrchestrator.TeamTask.self, from: Data(legacy.utf8)
        )

        XCTAssertEqual(task.id, "task-legacy-1")
        XCTAssertNil(task.route)
        XCTAssertNil(task.waveId)
    }

    func testStatedFieldsSurviveAnEncodeDecodeRoundTrip() throws {
        let team = registerTeam()
        let wave = "wave-\(UUID().uuidString)"
        let task = try XCTUnwrap(store.createTask(
            teamName: team, title: "roundtrip", assignee: "executor",
            route: "parallel", waveId: wave
        ))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(
            TeamOrchestrator.TeamTask.self, from: try encoder.encode(task)
        )

        XCTAssertEqual(restored.route, "parallel")
        XCTAssertEqual(restored.waveId, wave)
    }

    /// There are TWO task serializers: `TeamDataStore.taskDictionary`, which the
    /// v2 RPC handlers return, and `TeamOrchestrator.taskDictionary`, which
    /// `daemonPayload` uses for `fleet.state`, `/api/fleet` and every daemon
    /// team sync. The routing fields were originally added to only the first,
    /// so a route the leader actually stated reached board.json but was missing
    /// from the surface analysis reads — and an absent field reads exactly like
    /// "the leader stated nothing", which is the one distinction these fields
    /// exist to make. Assert both dictionaries agree.
    @MainActor
    func testBothTaskSerializersCarryTheRoutingFields() throws {
        let team = registerTeam()
        let wave = "wave-\(UUID().uuidString)"
        let task = try XCTUnwrap(store.createTask(
            teamName: team, title: "two serializers", assignee: "executor",
            route: "parallel", waveId: wave
        ))

        let storeDict = store.taskDictionary(task)
        let orchestratorDict = TeamOrchestrator.shared.taskDictionary(task)

        for (label, dict) in [("store", storeDict), ("orchestrator", orchestratorDict)] {
            XCTAssertEqual(
                dict["route"] as? String, "parallel",
                "\(label) serializer dropped the stated route"
            )
            XCTAssertEqual(
                dict["wave_id"] as? String, wave,
                "\(label) serializer dropped the stated wave"
            )
        }
    }

    /// An unstated route must be present-and-null in both serializers, not
    /// absent from one of them: a reader cannot tell an omitted key from a
    /// task that predates the field, so "not stated" has to be explicit.
    @MainActor
    func testUnstatedRoutingFieldsArePresentAndNullInBothSerializers() throws {
        let team = registerTeam()
        let task = try XCTUnwrap(store.createTask(
            teamName: team, title: "unstated", assignee: "executor"
        ))

        for (label, dict) in [
            ("store", store.taskDictionary(task)),
            ("orchestrator", TeamOrchestrator.shared.taskDictionary(task)),
        ] {
            XCTAssertTrue(
                dict.keys.contains("route"), "\(label) serializer omitted the route key"
            )
            XCTAssertTrue(
                dict.keys.contains("wave_id"), "\(label) serializer omitted the wave_id key"
            )
            XCTAssertTrue(dict["route"] is NSNull, "\(label) route should be null")
            XCTAssertTrue(dict["wave_id"] is NSNull, "\(label) wave_id should be null")
        }
    }
}
