import XCTest

final class ExecutionTransitionTests: XCTestCase {
    private func execution(pid: Int32, version: UInt32 = 1, executable: String = "/usr/local/bin/codex", parent: ExecutionIdentity? = nil) -> ExecutionRecord {
        let identity = ExecutionIdentity(process: .init(bootID: "transition-boot", pid: pid, startTimeMicros: Int64(pid) * 1_000), version: version)
        return .init(identity: identity, parent: parent, responsible: nil, parentPID: parent?.process.pid ?? 1,
                     userID: 501, executable: executable, arguments: [executable], workingDirectory: nil,
                     signingID: nil, teamID: nil, startedAt: Date(timeIntervalSince1970: Double(pid)), endedAt: nil,
                     state: .running, evidence: .observed, auditToken: nil)
    }

    func testObservedForkRetainsExactParentInsteadOfPIDGuess() {
        let engine = AttributionEngine(projectResolver: { _ in nil })
        let root = execution(pid: 100)
        var child = execution(pid: 200, executable: "/usr/bin/python3", parent: root.identity)
        child.parentPID = 999 // The audit-token identity takes precedence over a mutable ppid.
        engine.observe(root)
        engine.observe(child, kind: .fork)
        let graph = engine.snapshot()
        XCTAssertEqual(graph.edges.first?.parent, root.identity)
        XCTAssertEqual(graph.edges.first?.evidence, .observed)
        XCTAssertEqual(engine.sessionIDs(for: child.identity), engine.sessionIDs(for: root.identity))
        engine.exit(root.identity, at: Date())
        XCTAssertEqual(engine.leftovers().map(\.identity), [child.identity])
    }

    func testExecReplacementEndsAgentAndDoesNotLeaveTwoLiveExecutions() {
        let engine = AttributionEngine(projectResolver: { _ in nil })
        let root = execution(pid: 100)
        let service = execution(pid: 100, version: 2, executable: "/usr/bin/python3")
        engine.observe(root)
        engine.observe(service, kind: .exec)
        let graph = engine.snapshot()
        XCTAssertEqual(graph.executions.first(where: { $0.identity == root.identity })?.state, .exited)
        XCTAssertEqual(graph.executions.filter { $0.state == .running }.map(\.identity), [service.identity])
        XCTAssertEqual(graph.sessions.first?.endReason, "execReplaced")
        XCTAssertEqual(engine.leftovers().map(\.identity), [service.identity])
    }

    func testConfiguredAgentDefinitionIsUsedForExistingAndFutureProcesses() {
        let engine = AttributionEngine(projectResolver: { _ in nil }, definitions: [])
        let custom = execution(pid: 100, executable: "/opt/acme/custom-agent")
        engine.observe(custom)
        XCTAssertFalse(engine.isRelated(custom.identity))
        engine.configure(definitions: [.init(id: "custom", name: "Custom", executableNames: ["custom-agent"], scriptPathComponents: [])])
        XCTAssertEqual(engine.agents(for: custom.identity), ["custom"])
        let child = execution(pid: 200, executable: "/opt/acme/custom-agent")
        engine.observe(child)
        XCTAssertEqual(engine.agents(for: child.identity), ["custom"])
    }
    func testSharedServiceDoesNotClaimOneOfTwoProjects() {
        let engine = AttributionEngine(projectResolver: { cwd in cwd.map { .init(root: $0, gitDirectory: nil) } })
        var first = execution(pid: 100)
        first.workingDirectory = "/projects/first"
        var second = execution(pid: 101)
        second.workingDirectory = "/projects/second"
        let service = execution(pid: 200, executable: "/usr/bin/python3", parent: first.identity)
        engine.observe(first)
        engine.observe(second)
        engine.observe(service, kind: .fork)
        var graph = engine.snapshot()
        let secondSession = graph.sessions.first { $0.root == second.identity }!
        graph.associations.append(.init(execution: service.identity, sessionID: secondSession.id, evidence: .observed))
        engine.restore(graph)
        XCTAssertEqual(engine.sessionIDs(for: service.identity).count, 2)
        XCTAssertNil(engine.project(for: service.identity))
    }
    func testProcessOnlyRefreshRetainsLaunchArgumentsAndDirectory() {
        let engine = AttributionEngine(projectResolver: { _ in nil })
        var launched = execution(pid: 100, executable: "/usr/local/bin/node")
        launched.arguments = ["node", "/opt/@openai/codex/bin/codex.js", "--project", "/projects/demo"]
        launched.workingDirectory = "/projects/demo"
        engine.observe(launched, kind: .exec)
        var metadataOnly = launched
        metadataOnly.arguments = []
        metadataOnly.workingDirectory = nil
        engine.observe(metadataOnly)
        XCTAssertEqual(engine.execution(for: launched.identity)?.arguments, launched.arguments)
        XCTAssertEqual(engine.execution(for: launched.identity)?.workingDirectory, launched.workingDirectory)
        XCTAssertEqual(engine.agents(for: launched.identity), ["codex"])
    }

    func testCaptureGapRevokesLiveTokenAndPreservesUnknownState() {
        let engine = AttributionEngine(projectResolver: { _ in nil })
        var launched = execution(pid: 100)
        launched.auditToken = Data(repeating: 1, count: 32)
        engine.observe(launched)
        engine.markUnknown()
        XCTAssertEqual(engine.execution(for: launched.identity)?.state, .unknown)
        XCTAssertNil(engine.execution(for: launched.identity)?.auditToken)
        XCTAssertTrue(engine.leftovers().isEmpty)
    }
}
