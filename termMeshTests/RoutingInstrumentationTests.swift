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

    func testProjectRoutingDecisionMatrixIsDeterministic() {
        XCTAssertEqual(
            ProjectRoutingDecision.decide(
                level: .leaderFirst, taskShape: .singleUnit, risks: [], availableWorkers: 2
            ),
            .init(route: .direct, reasons: ["leader_first"], workerCount: 0)
        )
        XCTAssertEqual(
            ProjectRoutingDecision.decide(
                level: .guarded, taskShape: .singleUnit,
                risks: [.protocolOrPersistence], availableWorkers: 2
            ),
            .init(route: .probe, reasons: ["protocol_or_persistence"], workerCount: 1)
        )
        XCTAssertEqual(
            ProjectRoutingDecision.decide(
                level: .delegated, taskShape: .singleUnit, risks: [], availableWorkers: 1
            ),
            .init(route: .delegated, reasons: ["delegated_serial_work"], workerCount: 1)
        )
        XCTAssertEqual(
            ProjectRoutingDecision.decide(
                level: .guarded, taskShape: .multiUnit,
                risks: [.irreversibleOrRelease], availableWorkers: 3
            ),
            .init(route: .parallel, reasons: ["parallel_ready"], workerCount: 3)
        )
    }

    /// The turn hook is the only request boundary a directly typed prompt
    /// crosses, and it sees the prompt before any classification exists. An
    /// unstated shape used to arrive as `single_unit`, which closes the
    /// parallel gate and pinned those turns to `direct` no matter what the
    /// Project was configured to do.
    func testUnstatedTaskShapeDoesNotReadAsSingleUnit() {
        XCTAssertEqual(
            ProjectRoutingDecision.decide(
                level: .leaderFirst, taskShape: nil, risks: [], availableWorkers: 3
            ),
            .init(route: .direct, reasons: ["shape_unstated"], workerCount: 0),
            "a roster of three with no stated shape is not evidence of serial work"
        )
        XCTAssertEqual(
            ProjectRoutingDecision.decide(
                level: .leaderFirst, taskShape: nil, risks: [], availableWorkers: 1
            ),
            .init(route: .direct, reasons: ["leader_first"], workerCount: 0),
            "one worker cannot form a wave, so leader-first is the honest reason"
        )
        XCTAssertEqual(
            ProjectRoutingDecision.decide(
                level: .delegated, taskShape: nil, risks: [], availableWorkers: 1
            ),
            .init(route: .delegated, reasons: ["delegated_serial_work"], workerCount: 1),
            "delegated must not need a stated shape to hand work over"
        )
        XCTAssertEqual(
            ProjectRoutingDecision.decide(
                level: .guarded, taskShape: nil,
                risks: [.repeatedFailure], availableWorkers: 2
            ),
            .init(route: .probe, reasons: ["repeated_failure"], workerCount: 1)
        )
        XCTAssertEqual(
            ProjectRoutingDecision.decide(
                level: .delegated, taskShape: nil, risks: [], availableWorkers: 0
            ),
            .init(route: .direct, reasons: ["no_available_workers"], workerCount: 0),
            "an empty roster still outranks every level"
        )
    }

    /// A cap of one is "never fan out", not "fan out to one": two is the
    /// smallest wave the policy recognises, so the gate has to close rather
    /// than emit a one-worker parallel run.
    func testParallelCapClosesTheGateRatherThanShrinkingTheWave() {
        XCTAssertEqual(
            ProjectRoutingDecision.decide(
                level: .leaderFirst, taskShape: .multiUnit, risks: [],
                availableWorkers: 4, maxParallelWorkers: 1
            ),
            .init(route: .direct, reasons: ["limited_capacity"], workerCount: 0)
        )
        XCTAssertEqual(
            ProjectRoutingDecision.decide(
                level: .leaderFirst, taskShape: .multiUnit, risks: [],
                availableWorkers: 4, maxParallelWorkers: 2
            ),
            .init(route: .parallel, reasons: ["parallel_ready"], workerCount: 2)
        )
        XCTAssertEqual(
            ProjectRoutingDecision.decide(
                level: .leaderFirst, taskShape: .multiUnit, risks: [],
                availableWorkers: 2, maxParallelWorkers: 5
            ),
            .init(route: .parallel, reasons: ["parallel_ready"], workerCount: 2),
            "the roster still bounds the wave when the cap is higher"
        )
    }

    func testExecutionOptionsRoundTripAndClampOutOfRangeValues() throws {
        let suite = "exec-options.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(
            ProjectExecutionOptions.load(teamName: "fresh", from: defaults),
            .default,
            "an unset Project has to read as the shipped default, not as zero"
        )

        ProjectExecutionOptions(maxParallelWorkers: 99, injectDirective: false)
            .save(teamName: "capped", to: defaults)
        let loaded = ProjectExecutionOptions.load(teamName: "capped", from: defaults)
        XCTAssertEqual(loaded.maxParallelWorkers, ProjectExecutionOptions.workerBounds.upperBound)
        XCTAssertFalse(loaded.injectDirective)

        ProjectExecutionOptions(maxParallelWorkers: 0, injectDirective: true)
            .save(teamName: "floored", to: defaults)
        XCTAssertEqual(
            ProjectExecutionOptions.load(teamName: "floored", from: defaults).maxParallelWorkers,
            ProjectExecutionOptions.workerBounds.lowerBound
        )

        // Two Projects must not share one setting.
        XCTAssertEqual(
            ProjectExecutionOptions.load(teamName: "capped", from: defaults).maxParallelWorkers,
            ProjectExecutionOptions.workerBounds.upperBound
        )
    }

    func testEnqueueWithoutTaskShapeStoresNilRatherThanSingleUnit() throws {
        let team = registerTeam()
        _ = store.configureProjectDelegation(teamName: team, level: .delegated)
        guard case .created(let request, _) = store.enqueueLeaderRequest(
            teamName: team, content: "unclassified request", requestId: "shape-unstated"
        ) else {
            return XCTFail("expected the request to be created")
        }
        XCTAssertNil(request.taskShape, "an omitted shape must stay unstated")
        XCTAssertEqual(request.selectedRoute, .delegated)
        XCTAssertEqual(request.selectedWorkerCount, 1)
    }

    func testLeaderRequestSnapshotsEffectiveDelegationAndEngineRoute() throws {
        let team = registerTeam()
        _ = store.configureProjectDelegation(teamName: team, level: .guarded)
        guard case .created(let request, _) = store.enqueueLeaderRequest(
            teamName: team, content: "change protocol storage", requestId: "route-snapshot",
            taskShape: .singleUnit, riskReasons: [.protocolOrPersistence]
        ) else { return XCTFail("request was not created") }

        XCTAssertEqual(request.delegationLevel, .guarded)
        XCTAssertEqual(request.selectedRoute, .probe)
        XCTAssertEqual(request.riskReasons, [.protocolOrPersistence])
        let dictionary = store.leaderRequestDictionary(request, includeContent: false)
        XCTAssertEqual(dictionary["selected_route"] as? String, "probe")
        XCTAssertEqual(dictionary["delegation_level"] as? String, "guarded")
    }

    func testDelegationChangeDuringClaimBecomesNextRequestSnapshot() throws {
        let team = registerTeam()
        store.updateBoardUuids([team: UUID().uuidString])
        guard case .created(let first, _) = store.enqueueLeaderRequest(
            teamName: team, content: "first", requestId: "first"
        ) else { return XCTFail("first request missing") }
        guard case .succeeded = store.takeLeaderRequest(teamName: team, requestId: first.id) else {
            return XCTFail("first request was not claimed")
        }

        let pending = try XCTUnwrap(
            store.configureProjectDelegation(teamName: team, level: .delegated)
        )
        XCTAssertEqual(pending.effective, .leaderFirst)
        XCTAssertEqual(pending.pending, .delegated)

        guard case .created(let second, _) = store.enqueueLeaderRequest(
            teamName: team, content: "second", requestId: "second"
        ) else { return XCTFail("second request missing") }
        XCTAssertEqual(second.delegationLevel, .leaderFirst)

        guard case .succeeded = store.completeLeaderRequest(teamName: team, requestId: first.id) else {
            return XCTFail("first request was not completed")
        }
        guard case .created(let third, _) = store.enqueueLeaderRequest(
            teamName: team, content: "third", requestId: "third"
        ) else { return XCTFail("third request missing") }
        XCTAssertEqual(third.delegationLevel, .delegated)
        XCTAssertEqual(third.selectedRoute, .delegated)
    }

    func testMembershipReregistrationPreservesConfiguredDelegation() throws {
        let team = registerTeam()
        let configured = try XCTUnwrap(
            store.configureProjectDelegation(teamName: team, level: .delegated)
        )
        XCTAssertEqual(configured.effective, .delegated)

        // Adding or restarting an agent re-registers the roster without a
        // delegation argument; the configured level must survive.
        store.registerTeam(team, agentNames: ["executor", "reviewer"])
        XCTAssertEqual(store.projectDelegationState(teamName: team), configured)

        // An explicit state (create/resume) still replaces it.
        store.registerTeam(team, agentNames: ["executor"], delegationState: .default)
        XCTAssertEqual(store.projectDelegationState(teamName: team), .default)
    }

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

    func testMeasurementHealthPayloadKeepsCapabilityCohortsOutsideDenominator() throws {
        let log = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("measurement-health-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let lines = [
            #"{"event":"turn_start","turn_id":"a","ts":"2026-08-24T00:00:00Z","team":"t","surface_id":"s"}"#,
            #"{"event":"turn_route","turn_id":"a","ts":"2026-08-24T00:00:01Z","team":"t"}"#,
            #"{"event":"turn_end","turn_id":"a","ts":"2026-08-24T00:00:02Z","team":"t","route_status":"stated"}"#,
        ].joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: log)

        let health = LeaderTurnLog.health(
            from: log, capabilities: [.supported, .unsupported, .degraded]
        )
        XCTAssertEqual(health.supportedTurns, 1)
        XCTAssertEqual(health.linkedTurns, 1)
        XCTAssertEqual(health.unsupportedTurns, 1)
        XCTAssertEqual(health.degradedTurns, 1)
        XCTAssertEqual(health.coverage, 1)
        XCTAssertEqual(health.linkage, 1)
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
