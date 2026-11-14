import Foundation
import XCTest

final class ActivityProjectionTests: XCTestCase {
    private let boot = "boot-A"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Builders

    private func identity(_ pid: Int32, version: UInt32 = 1, startOffset: Int64 = 0) -> ExecutionIdentity {
        ExecutionIdentity(process: ProcessIdentity(bootID: boot, pid: pid, startTimeMicros: 1_000_000 + Int64(pid) * 10 + startOffset), version: version)
    }

    private func record(_ id: ExecutionIdentity, executable: String = "/usr/bin/python3", arguments: [String] = [],
                        parent: ExecutionIdentity? = nil, state: ExecutionState = .running,
                        evidence: EvidenceKind = .observed, cwd: String? = nil) -> ExecutionRecord {
        ExecutionRecord(
            identity: id, parent: parent, responsible: nil, parentPID: parent?.process.pid ?? 1, userID: 501,
            executable: executable, arguments: arguments, workingDirectory: cwd, signingID: nil, teamID: nil,
            startedAt: start, endedAt: state == .exited ? start.addingTimeInterval(5) : nil,
            state: state, evidence: evidence, auditToken: nil
        )
    }

    private func session(_ id: String, root: ExecutionIdentity, agent: AgentDefinition = AgentDefinition.defaults[0],
                         ended: Bool, project: ProjectRecord? = nil) -> AgentSession {
        AgentSession(id: id, agent: agent, root: root, project: project, startedAt: start,
                     endedAt: ended ? start.addingTimeInterval(60) : nil, endReason: ended ? "processExited" : nil, evidence: .observed)
    }

    private func native(_ records: [ExecutionRecord], endpoints: [ListeningEndpoint] = [], inspected: Set<ProcessIdentity>? = nil) -> NativeProcessSnapshot {
        NativeProcessSnapshot(
            capturedAt: start, executions: records, endpoints: endpoints, issues: [],
            socketInspectedProcesses: inspected ?? Set(records.map(\.identity.process))
        )
    }

    private func nativeCopy(of record: ExecutionRecord) -> ExecutionRecord {
        var copy = record
        copy.identity.version = 0
        copy.evidence = .snapshot
        copy.parent = nil
        return copy
    }

    private func endpoint(_ id: ExecutionIdentity, port: UInt16, transport: TransportProtocol = .tcp, endedAt: Date? = nil) -> ListeningEndpoint {
        ListeningEndpoint(execution: id, transport: transport, address: "127.0.0.1", addressFamily: AF_INET, scopeID: 0,
                          port: port, firstObservedAt: start, lastObservedAt: start, endedAt: endedAt)
    }

    private func make(_ input: ProjectionInput) -> ActivityProjection {
        ActivityProjection.make(input, resolveProject: { _ in nil })
    }

    // MARK: Leftovers

    func testChildAliveAfterConfirmedAgentExitIsLeftover() {
        let agent = identity(100)
        let child = identity(200)
        var input = ProjectionInput()
        input.graph = GraphSnapshot(
            executions: [record(agent, executable: "/opt/bin/codex", state: .exited), record(child, parent: agent)],
            edges: [ExecutionEdge(parent: agent, child: child, kind: .fork, evidence: .observed, observedAt: start)],
            sessions: [session("s1", root: agent, ended: true)],
            associations: [.init(execution: agent, sessionID: "s1", evidence: .observed),
                           .init(execution: child, sessionID: "s1", evidence: .observed)]
        )
        input.liveExecutions = [record(child, parent: agent)]
        input.native = native([nativeCopy(of: record(child))], endpoints: [endpoint(ExecutionIdentity(process: child.process, version: 0), port: 8080)])
        input.historyAvailable = true

        let projection = make(input)
        XCTAssertEqual(projection.leftovers.map(\.id), [child.process.stableID])
        let leftover = projection.leftovers[0]
        XCTAssertEqual(leftover.controlTarget, child, "Only the live ES identity may be signaled")
        XCTAssertEqual(leftover.endpoints.map(\.port), [8080])
        XCTAssertFalse(leftover.isShared)
        XCTAssertFalse(leftover.isUncertain)
    }

    func testProcessWithLiveAgentSessionIsNotLeftover() {
        let agent = identity(100)
        let child = identity(200)
        var input = ProjectionInput()
        input.graph = GraphSnapshot(
            executions: [record(agent, executable: "/opt/bin/codex"), record(child, parent: agent)],
            sessions: [session("s1", root: agent, ended: false)],
            associations: [.init(execution: child, sessionID: "s1", evidence: .observed)]
        )
        input.liveExecutions = [record(agent), record(child)]
        input.historyAvailable = true
        XCTAssertTrue(make(input).leftovers.isEmpty)
    }

    func testSharedWithStillRunningAgentIsNotLeftover() {
        let first = identity(100)
        let second = identity(101)
        let service = identity(200)
        var input = ProjectionInput()
        input.graph = GraphSnapshot(
            executions: [record(first, state: .exited), record(second), record(service)],
            sessions: [session("s1", root: first, ended: true), session("s2", root: second, ended: false)],
            associations: [.init(execution: service, sessionID: "s1", evidence: .observed),
                           .init(execution: service, sessionID: "s2", evidence: .inferred)]
        )
        input.liveExecutions = [record(second), record(service)]
        input.historyAvailable = true
        XCTAssertTrue(make(input).leftovers.isEmpty, "An active association blocks leftover classification")
    }

    func testUnobservedProcessIsNotConfirmedLeftover() {
        let agent = identity(100)
        let child = identity(200)
        var input = ProjectionInput()
        input.graph = GraphSnapshot(
            executions: [record(agent, state: .exited), record(child, state: .unknown)],
            sessions: [session("s1", root: agent, ended: true)],
            associations: [.init(execution: child, sessionID: "s1", evidence: .observed)]
        )
        input.native = native([])
        input.historyAvailable = true
        XCTAssertTrue(make(input).leftovers.isEmpty, "Persisted state alone does not prove the process is alive")
    }

    func testSharedAndInferredLeftoverIsFlagged() {
        let first = identity(100)
        let second = identity(101)
        let service = identity(200)
        var input = ProjectionInput()
        input.graph = GraphSnapshot(
            executions: [record(first, state: .exited), record(second, state: .exited), record(service)],
            sessions: [session("s1", root: first, ended: true), session("s2", root: second, agent: AgentDefinition.defaults[1], ended: true)],
            associations: [.init(execution: service, sessionID: "s1", evidence: .observed),
                           .init(execution: service, sessionID: "s2", evidence: .inferred)]
        )
        input.liveExecutions = [record(service)]
        input.historyAvailable = true
        let leftovers = make(input).leftovers
        XCTAssertEqual(leftovers.count, 1)
        XCTAssertTrue(leftovers[0].isShared)
        XCTAssertTrue(leftovers[0].isUncertain)
        XCTAssertEqual(Set(leftovers[0].attributions.map(\.agentID)), ["codex", "claude"])
    }

    func testNoLeftoversWithoutHistory() {
        let agent = identity(100)
        let child = identity(200)
        var input = ProjectionInput()
        input.graph = GraphSnapshot(
            executions: [record(agent, state: .exited), record(child)],
            sessions: [session("s1", root: agent, ended: true)],
            associations: [.init(execution: child, sessionID: "s1", evidence: .observed)]
        )
        input.liveExecutions = [record(child)]
        input.historyAvailable = false
        XCTAssertTrue(make(input).leftovers.isEmpty)
    }

    func testExecReplacedImageIsNotTheLeftoverRecord() {
        let agent = identity(100)
        let old = identity(200, version: 1)
        let new = identity(200, version: 2)
        var input = ProjectionInput()
        input.graph = GraphSnapshot(
            executions: [record(agent, state: .exited), record(old, executable: "/bin/sh"), record(new, executable: "/usr/bin/node")],
            sessions: [session("s1", root: agent, ended: true)],
            associations: [.init(execution: old, sessionID: "s1", evidence: .observed),
                           .init(execution: new, sessionID: "s1", evidence: .observed)]
        )
        input.liveExecutions = [record(new, executable: "/usr/bin/node")]
        input.historyAvailable = true
        let projection = make(input)
        XCTAssertEqual(projection.leftovers.count, 1, "One process instance, not one row per exec image")
        XCTAssertEqual(projection.leftovers[0].execution.identity, new)
        XCTAssertEqual(projection.leftovers[0].controlTarget, new)
        XCTAssertEqual(projection.index.runState(of: record(old)), .exited, "A replaced image is no longer running")
    }

    // MARK: Endpoints

    func testMonitorEndpointHiddenWhenNativeScanCompletedForHolder() {
        let service = identity(300)
        var input = ProjectionInput()
        input.monitorEndpoints = [endpoint(service, port: 5000)]
        input.native = native([nativeCopy(of: record(service))], endpoints: [])
        XCTAssertTrue(ActivityProjection.currentEndpoints(input).isEmpty, "A completed scan without the socket means it closed")

        input.native = native([nativeCopy(of: record(service))], endpoints: [], inspected: [])
        XCTAssertEqual(ActivityProjection.currentEndpoints(input).map(\.port), [5000], "An incomplete scan cannot establish closure")
    }

    func testNativeAndMonitorObservationsOfSameSocketMerge() {
        let service = identity(300, version: 4)
        let nativeID = ExecutionIdentity(process: service.process, version: 0)
        var input = ProjectionInput()
        input.monitorEndpoints = [endpoint(service, port: 5000)]
        input.native = native([nativeCopy(of: record(service))], endpoints: [endpoint(nativeID, port: 5000)], inspected: [])
        XCTAssertEqual(ActivityProjection.currentEndpoints(input).count, 1)
    }

    func testDistinctHoldersAndProtocolsStayDistinct() {
        let a = identity(300)
        let b = identity(301)
        var input = ProjectionInput()
        input.native = native(
            [nativeCopy(of: record(a)), nativeCopy(of: record(b))],
            endpoints: [endpoint(ExecutionIdentity(process: a.process, version: 0), port: 5353, transport: .udp),
                        endpoint(ExecutionIdentity(process: b.process, version: 0), port: 5353, transport: .udp),
                        endpoint(ExecutionIdentity(process: a.process, version: 0), port: 5353, transport: .tcp)]
        )
        XCTAssertEqual(make(input).ports.count, 3)
    }

    func testNativeOnlyPortHasNoControlTarget() {
        let service = identity(300)
        let nativeID = ExecutionIdentity(process: service.process, version: 0)
        var input = ProjectionInput()
        input.native = native([nativeCopy(of: record(service))], endpoints: [endpoint(nativeID, port: 3000)])
        let port = make(input).ports.first
        XCTAssertNotNil(port)
        XCTAssertNil(port?.controlTarget, "Native version-0 identities never authorize a signal")
    }

    // MARK: Launch chain

    func testLaunchChainIsOldestFirstAndIgnoresResponsibleEdges() {
        let agent = identity(100)
        let shell = identity(110)
        let server = identity(120)
        let unrelated = identity(130)
        let edges = [
            ExecutionEdge(parent: agent, child: shell, kind: .fork, evidence: .observed, observedAt: start),
            ExecutionEdge(parent: shell, child: server, kind: .fork, evidence: .observed, observedAt: start),
            ExecutionEdge(parent: unrelated, child: server, kind: .responsible, evidence: .responsible, observedAt: start)
        ]
        var input = ProjectionInput()
        input.graph = GraphSnapshot(
            executions: [record(agent, executable: "/opt/bin/codex"), record(shell, executable: "/bin/zsh"), record(server), record(unrelated)],
            edges: edges,
            sessions: [session("s1", root: agent, ended: false)],
            associations: []
        )
        let chain = make(input).index.launchChain(for: server)
        XCTAssertEqual(chain.map(\.identity), [agent, shell, server])
        XCTAssertEqual(chain.first?.agentName, "Codex")
        XCTAssertNil(chain.first?.link, "The oldest node has no parent link")
        XCTAssertEqual(chain.map(\.link), [nil, .fork, .fork])
        XCTAssertEqual(chain.last?.linkEvidence, .observed)
    }

    func testLaunchChainStopsOnCycle() {
        let a = identity(100)
        let b = identity(110)
        var input = ProjectionInput()
        input.graph = GraphSnapshot(
            executions: [record(a), record(b)],
            edges: [ExecutionEdge(parent: a, child: b, kind: .fork, evidence: .observed, observedAt: start),
                    ExecutionEdge(parent: b, child: a, kind: .fork, evidence: .observed, observedAt: start)]
        )
        XCTAssertEqual(make(input).index.launchChain(for: b).count, 2)
    }

    // MARK: Snapshot-only agents

    func testRunningAgentRecognizedFromNativeSnapshotIsLabeledSnapshot() {
        let agent = identity(100)
        let child = identity(110)
        var agentRecord = nativeCopy(of: record(agent, executable: "/opt/homebrew/bin/codex"))
        agentRecord.parent = nil
        var childRecord = nativeCopy(of: record(child))
        childRecord.parent = agentRecord.identity
        var input = ProjectionInput()
        input.native = native([agentRecord, childRecord], endpoints: [endpoint(childRecord.identity, port: 4000)])

        let projection = make(input)
        XCTAssertEqual(projection.agents.count, 1)
        XCTAssertNil(projection.agents[0].sessionID)
        XCTAssertEqual(projection.agents[0].evidence, .snapshot)
        XCTAssertEqual(projection.agents[0].descendantCount, 1)
        XCTAssertEqual(projection.agents[0].endpointCount, 1)
        XCTAssertEqual(projection.ports.first?.attributions.first?.evidence, .snapshot)
    }

    func testArgumentSubstringDoesNotCreateAgent() {
        var input = ProjectionInput()
        input.native = native([nativeCopy(of: record(identity(100), executable: "/bin/echo", arguments: ["echo", "codex"]))])
        XCTAssertTrue(make(input).agents.isEmpty)
    }

    // MARK: Projects and search

    func testRootAndHomeAreNotProjects() {
        XCTAssertFalse(ActivityProjection.isMeaningfulProject(ProjectRecord(root: "/", gitDirectory: nil)))
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        XCTAssertFalse(ActivityProjection.isMeaningfulProject(ProjectRecord(root: home, gitDirectory: nil)))
        XCTAssertTrue(ActivityProjection.isMeaningfulProject(ProjectRecord(root: home, gitDirectory: home + "/.git")))
        XCTAssertTrue(ActivityProjection.isMeaningfulProject(ProjectRecord(root: "/Users/dev/app", gitDirectory: nil)))
    }

    func testServicesOnlyGetGitProjectsFromWorkingDirectory() {
        let service = identity(300)
        let nativeID = ExecutionIdentity(process: service.process, version: 0)
        var input = ProjectionInput()
        input.native = native([nativeCopy(of: record(service, cwd: "/Users/dev/scratch"))], endpoints: [endpoint(nativeID, port: 3000)])
        let plain = ActivityProjection.make(input, resolveProject: { ProjectRecord(root: $0 ?? "/", gitDirectory: nil) })
        XCTAssertNil(plain.ports.first?.project)
        let git = ActivityProjection.make(input, resolveProject: { ProjectRecord(root: $0 ?? "/", gitDirectory: ($0 ?? "") + "/.git") })
        XCTAssertEqual(git.ports.first?.project?.root, "/Users/dev/scratch")
    }

    func testSearchMatchesPortExactlyAndTextLiterally() {
        XCTAssertTrue(ProjectionSearch.matches("8080", fields: [], port: 8080))
        XCTAssertFalse(ProjectionSearch.matches("808", fields: [], port: 8080))
        XCTAssertTrue(ProjectionSearch.matches("NPM run", fields: ["npm run dev"]))
        XCTAssertFalse(ProjectionSearch.matches("n.m", fields: ["npm"]), "Search is literal, not a pattern")
        XCTAssertTrue(ProjectionSearch.matches("  ", fields: []))
    }

    // MARK: Rule drafts

    func testRuleDraftValidation() {
        var draft = RuleDraft()
        XCTAssertEqual(draft.validate(existingRuleCount: 0), .emptyName)
        draft.name = "Secrets"
        draft.path = "relative/.env"
        XCTAssertEqual(draft.validate(existingRuleCount: 0), .relativePath)
        draft.path = "/Users/dev/app/.env"
        draft.operations = []
        XCTAssertEqual(draft.validate(existingRuleCount: 0), .emptyOperations)
        draft.operations = [.open]
        XCTAssertNil(draft.validate(existingRuleCount: 0))
        XCTAssertEqual(draft.validate(existingRuleCount: 512), .tooManyRules)
        draft.id = "existing"
        XCTAssertNil(draft.validate(existingRuleCount: 512), "Editing an existing rule doesn't add one")
        draft.path = "/" + String(repeating: "a", count: 4096)
        XCTAssertEqual(draft.validate(existingRuleCount: 0), .pathTooLong)
    }

    func testRuleDraftRoundTripsRule() {
        let rule = ProtectionRule(id: "r1", name: "Keys", enabled: false, target: .file, path: "/Users/dev/.ssh/id_ed25519",
                                  fileIdentity: FileIdentity(device: 1, inode: 2), operations: [.open, .delete], agentIDs: ["codex"])
        let made = RuleDraft(rule).makeRule()
        XCTAssertEqual(made.id, rule.id)
        XCTAssertEqual(made.operations, rule.operations)
        XCTAssertEqual(made.agentIDs, rule.agentIDs)
        XCTAssertNil(made.fileIdentity, "The extension prepares file identity; the client never asserts it")
    }
}

final class GitDiffServiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SidewatchGitDiff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private func git(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "-c", "user.name=Sidewatch Tests", "-c", "user.email=tests@example.invalid", "-c", "commit.gpgsign=false"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func requireGit() throws {
        guard (try? git(["--version"])) == 0 else { throw XCTSkip("git is unavailable") }
    }

    func testOutsideRepositoryHasNoDiff() async throws {
        try requireGit()
        let file = directory.appendingPathComponent("note.txt")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)
        let result = await GitDiffService().diff(forFile: file.path)
        XCTAssertEqual(result, .notInRepository)
    }

    func testTrackedModifiedUntrackedAndCleanFiles() async throws {
        try requireGit()
        XCTAssertEqual(try git(["init", "-q"]), 0)
        let tracked = directory.appendingPathComponent("src/app.txt")
        try FileManager.default.createDirectory(at: tracked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "one\n".write(to: tracked, atomically: true, encoding: .utf8)

        let untracked = directory.appendingPathComponent("new [draft].txt")
        try "draft\n".write(to: untracked, atomically: true, encoding: .utf8)

        // No commits yet: nothing has a baseline.
        if case .noBaseline = await GitDiffService().diff(forFile: tracked.path) {} else { XCTFail("Expected no baseline before the first commit") }

        XCTAssertEqual(try git(["add", "src/app.txt"]), 0)
        XCTAssertEqual(try git(["commit", "-q", "-m", "initial"]), 0)

        if case .noChanges = await GitDiffService().diff(forFile: tracked.path) {} else { XCTFail("Expected a clean file") }

        try "one\ntwo\n".write(to: tracked, atomically: true, encoding: .utf8)
        guard case .diff(_, let text, let truncated) = await GitDiffService().diff(forFile: tracked.path) else {
            return XCTFail("Expected a diff for the modified file")
        }
        XCTAssertTrue(text.contains("+two"))
        XCTAssertFalse(truncated)

        // Bracket characters must be treated literally, not as a pathspec pattern.
        if case .noBaseline = await GitDiffService().diff(forFile: untracked.path) {} else { XCTFail("Expected no baseline for an untracked file") }
    }

    func testOutputLimitTruncates() async throws {
        try requireGit()
        XCTAssertEqual(try git(["init", "-q"]), 0)
        let file = directory.appendingPathComponent("big.txt")
        try "start\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try git(["add", "big.txt"]), 0)
        XCTAssertEqual(try git(["commit", "-q", "-m", "initial"]), 0)
        try String(repeating: "line of text\n", count: 2_000).write(to: file, atomically: true, encoding: .utf8)
        var service = GitDiffService()
        service.outputLimit = 1_024
        guard case .diff(_, let text, let truncated) = await service.diff(forFile: file.path) else {
            return XCTFail("Expected a diff")
        }
        XCTAssertTrue(truncated)
        XCTAssertLessThanOrEqual(text.utf8.count, 1_024)
    }
}
