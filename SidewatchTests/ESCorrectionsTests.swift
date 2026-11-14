import Darwin
import EndpointSecurity
import XCTest

final class ESCorrectionsTests: XCTestCase {
    // MARK: - Helpers

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func execution(
        pid: Int32,
        start: Int64,
        version: UInt32 = 1,
        executable: String,
        arguments: [String] = [],
        parentPID: Int32 = 1,
        userID: UInt32 = 501,
        state: ExecutionState = .running,
        evidence: EvidenceKind = .observed,
        token: Data? = nil,
        bootID: String = "boot-es-corrections"
    ) -> ExecutionRecord {
        let identity = ExecutionIdentity(
            process: ProcessIdentity(
                bootID: bootID,
                pid: pid,
                startTimeMicros: start
            ),
            version: version
        )
        return ExecutionRecord(
            identity: identity,
            parent: nil,
            responsible: nil,
            parentPID: parentPID,
            userID: userID,
            executable: executable,
            arguments: arguments,
            workingDirectory: nil,
            signingID: nil,
            teamID: nil,
            startedAt: date(TimeInterval(start) / 1_000_000),
            endedAt: nil,
            state: state,
            evidence: evidence,
            auditToken: token
        )
    }


    // MARK: - Owner routing

    func testSystemAncestorDoesNotPoisonUserProcessOwnership() {
        let index = ESProvenanceIndex()
        let launchd = ProcessIdentity(
            bootID: "boot-es-corrections", pid: 1, startTimeMicros: 1
        )
        XCTAssertEqual(index.owners(for: launchd, userID: 0, parent: nil), [0])

        // A per-user launchd is spawned by the system launchd but runs as its own user. The
        // parent's dispatch-only scope must not be inherited.
        let userLaunchd = ProcessIdentity(
            bootID: "boot-es-corrections", pid: 200, startTimeMicros: 200
        )
        let owners = index.owners(
            for: userLaunchd,
            userID: 501,
            parent: ExecutionIdentity(process: launchd, version: 0)
        )
        XCTAssertEqual(owners, [501])
    }

    func testAgentProvenanceSurvivesEffectiveUIDChange() {
        let index = ESProvenanceIndex()
        let agent = ProcessIdentity(
            bootID: "boot-es-corrections", pid: 300, startTimeMicros: 300
        )
        XCTAssertEqual(index.owners(for: agent, userID: 501, parent: nil), [501])
        index.markProvenance(501, for: agent)

        // sudo/exec changes the effective UID but the process lineage remains the user's agent.
        let elevated = ProcessIdentity(
            bootID: "boot-es-corrections", pid: 301, startTimeMicros: 301
        )
        let inherited = index.owners(
            for: elevated,
            userID: 0,
            parent: ExecutionIdentity(process: agent, version: 1)
        )
        XCTAssertEqual(inherited, [501])
    }

    func testProvenanceFromMultipleUsersIsInheritedWithoutExposingOthers() {
        let index = ESProvenanceIndex()
        let shared = ProcessIdentity(
            bootID: "boot-es-corrections", pid: 400, startTimeMicros: 400
        )
        _ = index.owners(for: shared, userID: 501, parent: nil)
        index.markProvenance(501, for: shared)
        index.markProvenance(502, for: shared)

        let child = ProcessIdentity(
            bootID: "boot-es-corrections", pid: 401, startTimeMicros: 401
        )
        let owners = index.owners(
            for: child,
            userID: 0,
            parent: ExecutionIdentity(process: shared, version: 1)
        )
        XCTAssertEqual(owners, [501, 502])
    }

    // MARK: - Startup promotion

    func testStartupNodeScriptPromotionKeepsSnapshotAttributionWithoutFakeEdges() {
        let engine = AttributionEngine(projectResolver: { _ in nil })
        let nodeArguments = [
            "node",
            "/usr/local/lib/node_modules/@openai/codex/bin/codex.js"
        ]
        let snapshot = execution(
            pid: 900,
            start: 1_000,
            version: 0,
            executable: "/usr/local/bin/node",
            arguments: nodeArguments,
            evidence: .snapshot
        )
        engine.observe(snapshot, at: date(1))

        XCTAssertEqual(engine.agents(for: snapshot.identity), ["codex"])
        let sessionID = try! XCTUnwrap(engine.sessionIDs(for: snapshot.identity).first)

        // The first live ES message carries the real pidversion and the only fresh token.
        let token = Data([9, 9, 9])
        let observed = execution(
            pid: 900,
            start: 1_000,
            version: 7,
            executable: "/usr/local/bin/node",
            arguments: [],
            token: token
        )
        XCTAssertTrue(engine.adoptObserved(observed))
        XCTAssertEqual(engine.sessionIDs(for: observed.identity), [sessionID])
        XCTAssertEqual(engine.agents(for: observed.identity), ["codex"])
        XCTAssertEqual(engine.execution(for: observed.identity)?.arguments, nodeArguments)
        XCTAssertEqual(engine.execution(for: observed.identity)?.auditToken, token)
        XCTAssertNil(engine.execution(for: snapshot.identity)?.auditToken)
        XCTAssertEqual(
            engine.currentExecution(for: observed.identity.process)?.identity,
            observed.identity
        )

        let graph = engine.snapshot()
        XCTAssertEqual(graph.sessions.count, 1)
        XCTAssertEqual(graph.sessions.first?.root, snapshot.identity)
        XCTAssertTrue(graph.edges.isEmpty, "Reconciling a snapshot identity is not an exec/fork")
        XCTAssertEqual(
            graph.associations.first { $0.execution == observed.identity }?.evidence,
            .snapshot
        )

        engine.exit(observed.identity, at: date(2))
        let exited = engine.snapshot()
        XCTAssertNotNil(exited.sessions.first?.endedAt)
        XCTAssertEqual(exited.executions.first { $0.identity == observed.identity }?.state, .exited)
        XCTAssertEqual(exited.executions.first { $0.identity == snapshot.identity }?.state, .exited)
    }

    func testStartupPromotionSurvivesPersistenceReopenWithoutDuplicateRoots() {
        let engine = AttributionEngine(projectResolver: { _ in nil })
        let snapshot = execution(
            pid: 901,
            start: 2_000,
            version: 0,
            executable: "/usr/local/bin/node",
            arguments: ["node", "/opt/node_modules/@anthropic-ai/claude-code/cli.js"],
            evidence: .snapshot
        )
        engine.observe(snapshot, at: date(2))
        let observed = execution(
            pid: 901,
            start: 2_000,
            version: 3,
            executable: "/usr/local/bin/node",
            token: Data([1, 2, 3])
        )
        XCTAssertTrue(engine.adoptObserved(observed))
        let sessionID = try! XCTUnwrap(engine.sessionIDs(for: observed.identity).first)

        let reopened = AttributionEngine(projectResolver: { _ in nil })
        reopened.restore(engine.snapshot())
        XCTAssertEqual(reopened.snapshot().sessions.count, 1)
        XCTAssertEqual(reopened.sessionIDs(for: observed.identity), [sessionID])
        XCTAssertEqual(reopened.agents(for: observed.identity), ["claude"])

        // Simulate the first live message after reopening.
        XCTAssertTrue(reopened.adoptObserved(observed))
        XCTAssertEqual(reopened.snapshot().sessions.count, 1)
        XCTAssertEqual(reopened.sessionIDs(for: observed.identity), [sessionID])

        reopened.exit(observed.identity, at: date(3))
        XCTAssertNotNil(reopened.snapshot().sessions.first?.endedAt)
        XCTAssertEqual(reopened.snapshot().sessions.count, 1)

        // A retention pass after the real exit removes the reconciled roots, so a later full
        // graph snapshot cannot resurrect them.
        reopened.retain(GraphSnapshot(), since: date(4))
        let pruned = reopened.snapshot()
        XCTAssertTrue(pruned.sessions.isEmpty)
        XCTAssertTrue(pruned.executions.isEmpty)
    }

    func testObservedExecStartsAgentSessionAtEventTimeNotFoundProcessCreation() {
        let engine = AttributionEngine(projectResolver: { _ in nil })
        let processStart = date(1)
        let execTime = date(50)
        let shell = execution(pid: 500, start: 1_000_000, executable: "/bin/zsh")
        engine.observe(shell, at: processStart)

        // A NOTIFY_EXEC target carries the process creation time in `start_time`; the client
        // replaces it with the observed event time for the new execution.
        var target = execution(
            pid: 500,
            start: 1_000_000,
            version: 2,
            executable: "/usr/local/bin/codex"
        )
        target.startedAt = execTime
        engine.observe(target, kind: .exec, at: execTime)

        XCTAssertEqual(engine.execution(for: target.identity)?.startedAt, execTime)
        XCTAssertEqual(engine.snapshot().sessions.first?.startedAt, execTime)

        // A later metadata-only refresh keeps the known exec time instead of regressing to
        // the process creation baseline.
        var refresh = execution(
            pid: 500,
            start: 1_000_000,
            version: 2,
            executable: "/usr/local/bin/codex"
        )
        refresh.startedAt = processStart
        engine.observe(refresh, kind: nil, at: date(60))
        XCTAssertEqual(engine.execution(for: target.identity)?.startedAt, execTime)
    }

    func testExecAfterStartupPromotionLeavesOnlyOneActiveAgentRoot() {
        let engine = AttributionEngine(projectResolver: { _ in nil })
        let snapshot = execution(
            pid: 902,
            start: 2_500,
            version: 0,
            executable: "/usr/local/bin/codex",
            evidence: .snapshot
        )
        engine.observe(snapshot, at: date(2.5))
        let firstLive = execution(
            pid: 902,
            start: 2_500,
            version: 2,
            executable: "/usr/local/bin/codex"
        )
        XCTAssertTrue(engine.adoptObserved(firstLive))

        let replacement = execution(
            pid: 902,
            start: 2_500,
            version: 3,
            executable: "/usr/local/bin/codex"
        )
        engine.observe(replacement, kind: .exec, at: date(70))

        let sessions = engine.snapshot().sessions
        XCTAssertEqual(sessions.filter { $0.endedAt == nil }.count, 1)
        XCTAssertEqual(sessions.first { $0.root == snapshot.identity }?.endReason, "execReplaced")
        XCTAssertEqual(engine.snapshot().sessions.first { $0.root == replacement.identity }?.endedAt, nil)
    }

    func testNativeSnapshotEnrichesObservedNodeAgentWithoutDuplicateRoot() {
        let engine = AttributionEngine(projectResolver: { _ in nil })
        // ES process data has no argv, so the script agent is not recognizable yet.
        let observed = execution(
            pid: 903,
            start: 3_000,
            version: 5,
            executable: "/usr/local/bin/node"
        )
        engine.observe(observed, at: date(3))
        XCTAssertFalse(engine.isRelated(observed.identity))

        let snapshot = execution(
            pid: 903,
            start: 3_000,
            version: 0,
            executable: "/usr/local/bin/node",
            arguments: ["node", "/usr/local/lib/node_modules/@openai/codex/bin/codex.js"],
            evidence: .snapshot
        )
        engine.observe(snapshot, at: date(3.5))
        XCTAssertEqual(engine.agents(for: snapshot.identity), ["codex"])

        XCTAssertTrue(engine.adoptObserved(observed))
        XCTAssertEqual(
            engine.sessionIDs(for: observed.identity),
            engine.sessionIDs(for: snapshot.identity)
        )
        XCTAssertEqual(engine.agents(for: observed.identity), ["codex"])
        XCTAssertEqual(engine.snapshot().sessions.filter { $0.endedAt == nil }.count, 1)
    }

    func testDefinitionRefreshDoesNotDuplicateReconciledStartupRoot() {
        let engine = AttributionEngine(projectResolver: { _ in nil })
        let snapshot = execution(
            pid: 904,
            start: 4_000,
            version: 0,
            executable: "/usr/local/bin/codex",
            evidence: .snapshot
        )
        engine.observe(snapshot, at: date(4))
        let observed = execution(
            pid: 904,
            start: 4_000,
            version: 6,
            executable: "/usr/local/bin/codex"
        )
        XCTAssertTrue(engine.adoptObserved(observed))

        engine.configure(definitions: AgentDefinition.defaults)
        let sessions = engine.snapshot().sessions
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.filter { $0.endedAt == nil }.count, 1)
        XCTAssertEqual(engine.agents(for: observed.identity), ["codex"])
    }

    // MARK: - Decoder

    func testInvalidUTF8PathTokenIsRejectedInsteadOfRepaired() {
        XCTAssertEqual(decode("/tmp/file"), "/tmp/file")
        XCTAssertNil(decode(""))
        // Truncated multi-byte sequence is not valid UTF-8.
        XCTAssertNil(decodeBytes([0x2F, 0x74, 0x6D, 0x70, 0xC3]))
        // Lone continuation byte.
        XCTAssertNil(decodeBytes([0x2F, 0x74, 0x6D, 0x70, 0x80]))
    }

    private func decode(_ value: String) -> String? {
        decodeBytes(Array(value.utf8))
    }

    private func decodeBytes(_ bytes: [UInt8]) -> String? {
        let characters = bytes.map { Int8(bitPattern: $0) }
        return characters.withUnsafeBufferPointer { buffer in
            var token = es_string_token_t()
            token.length = buffer.count
            token.data = buffer.baseAddress
            return ESMessageDecoder.string(token)
        }
    }

    // MARK: - Execution index

    func testReplacingExecutionVersionRetiresOldPIDVersionKey() {
        var index = ESExecutionIndex()
        let first = execution(pid: 10, start: 100_000, version: 1, executable: "/bin/sh")
        let second = execution(pid: 10, start: 100_000, version: 2, executable: "/bin/zsh")
        index.store(first)
        XCTAssertNotNil(index.identity(pid: 10, version: 1))

        index.store(second)
        XCTAssertNil(index.identity(pid: 10, version: 1))
        XCTAssertNotNil(index.identity(pid: 10, version: 2))
        XCTAssertEqual(index.latest.count, 1)
        XCTAssertEqual(index.byPIDVersion.count, 1)
    }

    func testObservedExitRetiresPIDVersionKey() {
        var index = ESExecutionIndex()
        let record = execution(pid: 11, start: 200_000, version: 4, executable: "/bin/sh")
        index.store(record)
        XCTAssertNotNil(index.identity(pid: 11, version: 4))
        index.markExited(record.identity, at: date(1))
        XCTAssertNil(index.identity(pid: 11, version: 4))
        XCTAssertEqual(index.latest[record.identity.process]?.state, .exited)
    }

    func testIndexTrimRetiresEveryMappingForEvictedProcesses() {
        var index = ESExecutionIndex()
        let processes: [ProcessIdentity] = (0..<6).map { value in
            ProcessIdentity(
                bootID: "boot-es-corrections",
                pid: Int32(20 + value),
                startTimeMicros: Int64(300_000 + value)
            )
        }
        for process in processes {
            let record = execution(
                pid: process.pid,
                start: process.startTimeMicros,
                executable: "/bin/sh",
                state: .exited
            )
            index.store(record)
        }
        index.trim(maximum: 4, target: 2)
        XCTAssertLessThanOrEqual(index.latest.count, 2)
        XCTAssertEqual(index.byPIDVersion.count, index.latest.count)
        for identity in index.byPIDVersion.values {
            XCTAssertNotNil(index.latest[identity.process])
        }
    }

    func testRepeatedExecChurnDoesNotGrowIndex() {
        var index = ESExecutionIndex()
        for version in 1...200 {
            index.store(execution(
                pid: 50,
                start: 400_000,
                version: UInt32(version),
                executable: "/bin/sh"
            ))
        }
        XCTAssertEqual(index.latest.count, 1)
        XCTAssertEqual(index.byPIDVersion.count, 1)
        XCTAssertNotNil(index.identity(pid: 50, version: 200))
    }

    // MARK: - Retention

    func testRetainDropsOldEndedHistoryAndKeepsLiveGraph() {
        let engine = AttributionEngine(projectResolver: { _ in nil })
        let old = execution(pid: 100, start: 1_000_000, executable: "/usr/local/bin/codex")
        let oldChild = execution(
            pid: 101, start: 2_000_000, executable: "/bin/sh", parentPID: 100
        )
        engine.observe(old, at: date(1))
        engine.observe(oldChild, kind: .fork, at: date(2))
        engine.exit(oldChild.identity, at: date(3))
        engine.exit(old.identity, at: date(4))

        let live = execution(pid: 200, start: 5_000_000, executable: "/usr/local/bin/codex")
        let liveChild = execution(
            pid: 201, start: 6_000_000, executable: "/bin/sh", parentPID: 200
        )
        engine.observe(live, at: date(5))
        engine.observe(liveChild, kind: .fork, at: date(6))

        let before = engine.snapshot()
        var retained = GraphSnapshot()
        let keptIdentities: Set<ExecutionIdentity> = [live.identity, liveChild.identity]
        retained.executions = before.executions.filter { keptIdentities.contains($0.identity) }
        retained.sessions = before.sessions.filter { $0.root == live.identity }
        retained.associations = before.associations.filter {
            keptIdentities.contains($0.execution)
        }
        retained.edges = before.edges.filter {
            keptIdentities.contains($0.parent) && keptIdentities.contains($0.child)
        }

        engine.retain(retained, since: date(4.5))
        let after = engine.snapshot()
        XCTAssertNil(after.executions.first { $0.identity == old.identity })
        XCTAssertNil(after.executions.first { $0.identity == oldChild.identity })
        XCTAssertNotNil(after.executions.first { $0.identity == live.identity })
        XCTAssertNotNil(after.executions.first { $0.identity == liveChild.identity })
        XCTAssertEqual(after.sessions.count, 1)
        XCTAssertEqual(after.sessions.first?.root, live.identity)
        XCTAssertTrue(engine.isRelated(liveChild.identity))

        // A later full snapshot can no longer resurrect the deleted session graph.
        XCTAssertFalse(after.sessions.contains { $0.root == old.identity })
    }

    func testRetainKeepsObservationsThatEndedAfterBoundary() {
        let engine = AttributionEngine(projectResolver: { _ in nil })
        let recent = execution(pid: 300, start: 7_000_000, executable: "/usr/local/bin/codex")
        engine.observe(recent, at: date(7))
        engine.exit(recent.identity, at: date(8))

        engine.retain(GraphSnapshot(), since: date(7.5))
        let graph = engine.snapshot()
        XCTAssertNotNil(graph.executions.first { $0.identity == recent.identity })
        XCTAssertEqual(graph.sessions.first?.endedAt, date(8))
    }

    func testRetainPreservesLineageAndAttributionOfLiveDescendant() {
        let engine = AttributionEngine(projectResolver: { _ in nil })
        let agent = execution(pid: 400, start: 10_000_000, executable: "/usr/local/bin/codex")
        let child = execution(pid: 401, start: 11_000_000, executable: "/bin/sh", parentPID: 400)
        engine.observe(agent, at: date(10))
        engine.observe(child, kind: .fork, at: date(11))
        engine.exit(agent.identity, at: date(12))

        engine.retain(GraphSnapshot(), since: date(13))
        let graph = engine.snapshot()
        XCTAssertNotNil(graph.executions.first { $0.identity == agent.identity })
        XCTAssertNotNil(graph.executions.first { $0.identity == child.identity })
        XCTAssertTrue(engine.isRelated(child.identity))
        XCTAssertFalse(graph.sessions.isEmpty, "The live child's attribution context remains")
    }

    func testClientRetainGraphDropsRestoredHistoryAndKeepsLiveGraph() throws {
        let capture = CaptureRecord(
            id: "retain-graph",
            bootID: "boot-es-corrections",
            startedAt: date(0)
        )
        let client = EndpointSecurityClient(capture: capture)
        defer { client.stop() }
        let userID = geteuid()

        var old = execution(pid: 700, start: 1_000_000, executable: "/usr/local/bin/codex")
        old.state = .exited
        old.endedAt = date(1)
        let oldSession = AgentSession(
            id: "session:\(old.identity.stableID)",
            agent: AgentDefinition.defaults[0],
            root: old.identity,
            project: nil,
            startedAt: date(1),
            endedAt: date(1),
            endReason: "processExited",
            evidence: .observed
        )
        var live = execution(pid: 701, start: 5_000_000, executable: "/usr/local/bin/codex")
        live.state = .running
        let liveSession = AgentSession(
            id: "session:\(live.identity.stableID)",
            agent: AgentDefinition.defaults[0],
            root: live.identity,
            project: nil,
            startedAt: date(5),
            endedAt: nil,
            endReason: nil,
            evidence: .observed
        )
        let graph = GraphSnapshot(
            executions: [old, live],
            edges: [],
            sessions: [oldSession, liveSession],
            associations: [
                .init(execution: old.identity, sessionID: oldSession.id, evidence: .observed),
                .init(execution: live.identity, sessionID: liveSession.id, evidence: .observed)
            ]
        )
        client.restore(graph, configuration: .init(mode: .recordOnly), userID: userID)
        client.retainGraph(GraphSnapshot(), userID: userID, since: date(4))

        let after = client.graph(userID: userID)
        XCTAssertNil(after.executions.first { $0.identity == old.identity })
        XCTAssertNil(after.sessions.first { $0.id == oldSession.id })
        XCTAssertEqual(after.sessions.map(\.id), [liveSession.id])
        XCTAssertEqual(after.executions.map(\.identity), [live.identity])
    }

    func testLiveExecutionsFiltersCurrentUIDBootStateAndStripsTokens() {
        let token = Data(repeating: 7, count: MemoryLayout<audit_token_t>.size)
        let running = execution(
            pid: 800,
            start: 1_000_000,
            executable: "/usr/local/bin/codex",
            token: token
        )
        let wrongUID = execution(
            pid: 801,
            start: 1_100_000,
            executable: "/usr/local/bin/codex",
            userID: 502,
            token: token
        )
        let snapshot = execution(
            pid: 802,
            start: 1_200_000,
            executable: "/usr/local/bin/codex",
            evidence: .snapshot,
            token: token
        )
        let exited = execution(
            pid: 803,
            start: 1_300_000,
            executable: "/usr/local/bin/codex",
            state: .exited,
            token: token
        )
        let tokenless = execution(
            pid: 804,
            start: 1_400_000,
            executable: "/usr/local/bin/codex"
        )
        let wrongBoot = execution(
            pid: 805,
            start: 1_500_000,
            executable: "/usr/local/bin/codex",
            token: token,
            bootID: "other-boot"
        )

        let live = EndpointSecurityClient.currentLiveExecutions(
            [running, wrongUID, snapshot, exited, tokenless, wrongBoot],
            userID: 501,
            bootID: "boot-es-corrections"
        )
        XCTAssertEqual(live.map(\.identity), [running.identity])
        XCTAssertNil(live.first?.auditToken)
        XCTAssertEqual(live.first?.userID, 501)
    }

    // MARK: - Response and error outcomes

    func testFailedResponseWithoutMatchNeverFabricatesARecord() {
        let resolution = ESAuthPlanner.resolve([], responseSucceeded: false)
        XCTAssertEqual(resolution.response, .allow)
        XCTAssertTrue(resolution.records.isEmpty)
    }

    func testEndpointSecurityErrorCodesAreStable() {
        XCTAssertEqual(
            EndpointSecurityClientError.endpointSecurityInactive.code,
            "es_inactive"
        )
        XCTAssertEqual(
            EndpointSecurityClientError.invalidConfiguration.code,
            "es_invalid_configuration"
        )
        XCTAssertEqual(
            EndpointSecurityClientError.subscriptionFailed.code,
            "es_subscription_failed"
        )
    }
}
