import XCTest

final class AttributionEngineTests: XCTestCase {
    // MARK: - Helpers

    private func date(_ micros: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(micros) / 1_000_000)
    }

    private func makeExecution(
        pid: Int32,
        start: Int64,
        version: UInt32 = 1,
        bootID: String = "boot",
        executable: String,
        arguments: [String]? = nil,
        workingDirectory: String? = nil,
        parentPID: Int32 = 1,
        state: ExecutionState = .running,
        evidence: EvidenceKind = .observed,
        token: Data? = nil,
        endedAt: Date? = nil
    ) -> ExecutionRecord {
        ExecutionRecord(
            identity: ExecutionIdentity(
                process: ProcessIdentity(bootID: bootID, pid: pid, startTimeMicros: start),
                version: version
            ),
            parent: nil,
            responsible: nil,
            parentPID: parentPID,
            userID: 501,
            executable: executable,
            arguments: arguments ?? [executable],
            workingDirectory: workingDirectory,
            signingID: nil,
            teamID: nil,
            startedAt: date(start),
            endedAt: endedAt,
            state: state,
            evidence: evidence,
            auditToken: token
        )
    }

    private func agent(_ id: String) -> AgentDefinition {
        AgentDefinition.defaults.first { $0.id == id }!
    }

    // MARK: - Fork, reparent and leftovers

    func testForkInheritanceSurvivesParentExitAndBecomesLeftover() {
        let engine = AttributionEngine()
        let parent = makeExecution(pid: 100, start: 1_000_000, executable: "/usr/local/bin/codex")
        let child = makeExecution(pid: 101, start: 2_000_000, executable: "/bin/sh", parentPID: 100, evidence: .observed)

        engine.observe(parent, at: date(1_000_000))
        engine.observe(child, kind: .fork, at: date(2_000_000))

        XCTAssertEqual(engine.agents(for: parent.identity), Set([agent("codex").id]))
        XCTAssertEqual(engine.agents(for: child.identity), Set([agent("codex").id]))
        XCTAssertTrue(engine.isRelated(child.identity))
        XCTAssertEqual(engine.sessionIDs(for: child.identity), engine.sessionIDs(for: parent.identity))

        let forkEdge = engine.snapshot().edges.first { $0.child == child.identity && $0.parent == parent.identity }
        XCTAssertEqual(forkEdge?.kind, .fork)
        XCTAssertEqual(forkEdge?.evidence, .inferred)

        engine.exit(parent.identity, at: date(3_000_000))

        XCTAssertTrue(engine.isRelated(child.identity), "A reparented child keeps its recorded source")
        XCTAssertEqual(engine.agents(for: child.identity), Set([agent("codex").id]))
        XCTAssertEqual(engine.leftovers().map(\.identity), [child.identity])

        let inherited = engine.snapshot().associations.first { $0.execution == child.identity }
        XCTAssertEqual(inherited?.evidence, .inferred, "Inherited attribution is never upgraded to observed")
    }

    func testInferenceRequiresLiveParentAtObservationTime() {
        let engine = AttributionEngine()
        let parent = makeExecution(pid: 110, start: 1_000_000, executable: "/usr/local/bin/codex")
        engine.observe(parent, at: date(1_000_000))
        engine.exit(parent.identity, at: date(1_500_000))

        let child = makeExecution(pid: 111, start: 2_000_000, executable: "/bin/sh", parentPID: 110)
        engine.observe(child, kind: .fork, at: date(2_000_000))

        XCTAssertTrue(engine.snapshot().edges.isEmpty)
        XCTAssertFalse(engine.isRelated(child.identity))
    }

    func testInferredAttributionStaysInferredThroughGrandchildren() {
        let engine = AttributionEngine()
        let parent = makeExecution(pid: 120, start: 1_000_000, executable: "/usr/local/bin/codex")
        let child = makeExecution(pid: 121, start: 2_000_000, executable: "/bin/sh", parentPID: 120)
        let grandchild = makeExecution(pid: 122, start: 3_000_000, executable: "/bin/sh", parentPID: 121)

        engine.observe(parent, at: date(1_000_000))
        engine.observe(child, kind: .fork, at: date(2_000_000))
        engine.observe(grandchild, kind: .fork, at: date(3_000_000))

        XCTAssertEqual(engine.agents(for: grandchild.identity), Set([agent("codex").id]))
        for association in engine.snapshot().associations where association.execution != parent.identity {
            XCTAssertEqual(association.evidence, .inferred)
        }

        engine.exit(parent.identity, at: date(4_000_000))
        XCTAssertEqual(engine.leftovers().map(\.identity), [child.identity, grandchild.identity])
    }

    func testInjectedProjectResolverKeepsObservationInMemory() {
        var lookups: [String] = []
        let project = ProjectRecord(root: "/virtual/project", gitDirectory: "/virtual/project/.git")
        let engine = AttributionEngine { cwd in
            lookups.append(cwd ?? "<nil>")
            return cwd == "/virtual/project" ? project : nil
        }
        let execution = makeExecution(pid: 950, start: 1_000_000, executable: "/usr/local/bin/codex", workingDirectory: "/virtual/project")

        engine.observe(execution, at: date(1_000_000))

        XCTAssertEqual(lookups, ["/virtual/project"])
        XCTAssertEqual(engine.project(for: execution.identity), project)
    }

    func testStartupSnapshotRecognitionStaysSnapshotEvidence() {
        let engine = AttributionEngine()
        let execution = makeExecution(
            pid: 960,
            start: 1_000_000,
            executable: "/usr/local/bin/codex",
            evidence: .snapshot
        )
        engine.observe(execution, at: date(1_000_000))

        let graph = engine.snapshot()
        XCTAssertEqual(graph.sessions.first?.evidence, .snapshot)
        XCTAssertEqual(graph.associations.first?.evidence, .snapshot)

        let child = makeExecution(pid: 961, start: 2_000_000, executable: "/bin/sh", parentPID: 960)
        engine.observe(child, kind: .fork, at: date(2_000_000))
        let childAssociation = engine.snapshot().associations.first { $0.execution == child.identity }
        XCTAssertEqual(childAssociation?.evidence, .inferred)
    }

    // MARK: - Exec and PID reuse

    func testExecKeepsProcessAttributionAndLinksVersions() {
        let engine = AttributionEngine()
        let first = makeExecution(pid: 300, start: 1_000_000, version: 1, executable: "/usr/local/bin/codex")
        engine.observe(first, at: date(1_000_000))

        let second = makeExecution(pid: 300, start: 1_000_000, version: 2, executable: "/bin/bash")
        engine.observe(second, kind: .exec, at: date(2_000_000))

        XCTAssertEqual(engine.sessionIDs(for: second.identity), engine.sessionIDs(for: first.identity))
        XCTAssertTrue(engine.isRelated(second.identity))
        XCTAssertEqual(engine.agents(for: second.identity), Set([agent("codex").id]))

        let execEdge = engine.snapshot().edges.first { $0.child == second.identity && $0.kind == .exec }
        XCTAssertEqual(execEdge?.parent, first.identity)
        XCTAssertEqual(execEdge?.evidence, .observed)
        XCTAssertEqual(engine.snapshot().edges.filter { $0.kind == .fork }.count, 0)
    }

    func testPIDReuseDoesNotInheritPreviousSession() {
        let engine = AttributionEngine()
        let old = makeExecution(pid: 500, start: 1_000_000, executable: "/usr/local/bin/codex")
        engine.observe(old, at: date(1_000_000))
        engine.exit(old.identity, at: date(1_500_000))

        let reused = makeExecution(pid: 500, start: 9_000_000, executable: "/bin/zsh")
        engine.observe(reused, at: date(9_000_000))

        XCTAssertFalse(engine.isRelated(reused.identity))
        XCTAssertTrue(engine.sessionIDs(for: reused.identity).isEmpty)
        XCTAssertTrue(engine.isRelated(old.identity))
        XCTAssertEqual(engine.snapshot().sessions.count, 1)
        XCTAssertTrue(engine.snapshot().edges.isEmpty)

        // A child of the reused PID must attach to the new process, not the exited agent.
        let lateChild = makeExecution(pid: 501, start: 10_000_000, executable: "/bin/sh", parentPID: 500)
        engine.observe(lateChild, kind: .fork, at: date(10_000_000))
        XCTAssertFalse(engine.isRelated(lateChild.identity))
        XCTAssertTrue(engine.leftovers().isEmpty)
    }

    // MARK: - Multiple agents

    func testSimultaneousSessionAndMultipleAssociations() throws {
        let fileManager = FileManager.default
        let repository = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: repository) }

        let engine = AttributionEngine()
        let parent = makeExecution(pid: 600, start: 1_000_000, executable: "/usr/local/bin/codex", workingDirectory: repository.path)
        let child = makeExecution(pid: 601, start: 2_000_000, executable: "/usr/local/bin/claude", workingDirectory: repository.path, parentPID: 600)

        engine.observe(parent, at: date(1_000_000))
        engine.observe(child, kind: .fork, at: date(2_000_000))

        XCTAssertEqual(engine.sessionIDs(for: child.identity).count, 2)
        XCTAssertEqual(engine.agents(for: child.identity), Set([agent("codex").id, agent("claude").id]))
        XCTAssertEqual(engine.project(for: child.identity)?.root, repository.resolvingSymlinksInPath().path)

        engine.exit(parent.identity, at: date(3_000_000))

        // The child still runs its own live agent session, so it is not an orphaned leftover.
        XCTAssertTrue(engine.leftovers().isEmpty)
        XCTAssertEqual(engine.agents(for: child.identity).count, 2)
    }

    // MARK: - Restore

    func testRestoreRemovesTokensMarksUnknownAndDeduplicatesSessions() {
        let root = makeExecution(pid: 700, start: 1_000_000, executable: "/usr/local/bin/codex", token: Data([0x01, 0x02]))
        let session = AgentSession(
            id: "persisted-session",
            agent: agent("codex"),
            root: root.identity,
            project: nil,
            startedAt: root.startedAt,
            endedAt: nil,
            endReason: nil,
            evidence: .observed
        )
        let duplicate = AgentSession(
            id: "duplicate-session",
            agent: agent("codex"),
            root: root.identity,
            project: nil,
            startedAt: root.startedAt,
            endedAt: nil,
            endReason: nil,
            evidence: .observed
        )
        let graph = GraphSnapshot(
            executions: [root],
            edges: [],
            sessions: [session, duplicate],
            associations: [
                ExecutionAssociation(execution: root.identity, sessionID: session.id, evidence: .snapshot),
                ExecutionAssociation(execution: root.identity, sessionID: duplicate.id, evidence: .snapshot)
            ]
        )

        let engine = AttributionEngine()
        engine.restore(graph)

        let restored = engine.snapshot()
        XCTAssertEqual(restored.executions.count, 1)
        XCTAssertEqual(restored.executions.first?.state, .unknown)
        XCTAssertNil(restored.executions.first?.auditToken)
        XCTAssertEqual(restored.sessions.count, 1, "Sessions are keyed by root execution identity")
        XCTAssertEqual(engine.sessionIDs(for: root.identity), ["session:\(root.identity.stableID)"])
        XCTAssertTrue(engine.isRelated(root.identity))
        XCTAssertTrue(engine.leftovers().isEmpty)
    }

    func testUnknownCaptureIntervalIsNotAConfirmedOrphan() {
        let engine = AttributionEngine()
        let parent = makeExecution(pid: 800, start: 1_000_000, executable: "/usr/local/bin/codex")
        let child = makeExecution(pid: 801, start: 2_000_000, executable: "/bin/sh", parentPID: 800)

        engine.observe(parent, at: date(1_000_000))
        engine.observe(child, kind: .fork, at: date(2_000_000))
        engine.markUnknown()

        XCTAssertEqual(engine.snapshot().executions.filter { $0.state == .unknown }.count, 2)
        XCTAssertTrue(engine.leftovers().isEmpty)
        XCTAssertTrue(engine.isRelated(child.identity))
        XCTAssertEqual(engine.agents(for: child.identity), Set([agent("codex").id]))
    }

    func testRestoredLeftoverRequiresALiveObservation() {
        let endedAt = date(3_000_000)
        let parent = makeExecution(pid: 900, start: 1_000_000, executable: "/usr/local/bin/codex", state: .exited, endedAt: endedAt)
        let child = makeExecution(pid: 901, start: 2_000_000, executable: "/bin/sh", parentPID: 900)
        let session = AgentSession(
            id: "persisted",
            agent: agent("codex"),
            root: parent.identity,
            project: nil,
            startedAt: parent.startedAt,
            endedAt: endedAt,
            endReason: "processExited",
            evidence: .observed
        )
        let graph = GraphSnapshot(
            executions: [parent, child],
            edges: [ExecutionEdge(parent: parent.identity, child: child.identity, kind: .fork, evidence: .observed, observedAt: date(2_000_000))],
            sessions: [session],
            associations: [ExecutionAssociation(execution: child.identity, sessionID: session.id, evidence: .inferred)]
        )

        let engine = AttributionEngine()
        engine.restore(graph)
        XCTAssertTrue(engine.leftovers().isEmpty, "Restored running state is unknown, not confirmed alive")

        engine.observe(child, at: date(4_000_000))
        XCTAssertEqual(engine.leftovers().map(\.identity), [child.identity])
    }
}

final class AgentRecognizerTests: XCTestCase {
    private func record(executable: String, arguments: [String]) -> ExecutionRecord {
        ExecutionRecord(
            identity: ExecutionIdentity(process: ProcessIdentity(bootID: "boot", pid: 42, startTimeMicros: 1), version: 1),
            parent: nil,
            responsible: nil,
            parentPID: 1,
            userID: 501,
            executable: executable,
            arguments: arguments,
            workingDirectory: nil,
            signingID: nil,
            teamID: nil,
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: nil,
            state: .running,
            evidence: .observed,
            auditToken: nil
        )
    }

    func testRecognizesExactExecutableAndKnownInterpreterScript() {
        XCTAssertEqual(
            AgentRecognizer.recognize(record(executable: "/usr/local/bin/codex", arguments: ["/usr/local/bin/codex", "exec", "hi"]))?.id,
            "codex"
        )
        XCTAssertEqual(
            AgentRecognizer.recognize(record(
                executable: "/opt/homebrew/bin/node",
                arguments: ["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js", "--resume"]
            ))?.id,
            "claude"
        )
        XCTAssertEqual(
            AgentRecognizer.recognize(record(
                executable: "/usr/local/bin/bun",
                arguments: ["bun", "--smol", "/usr/local/lib/node_modules/@google/gemini-cli/dist/index.js"]
            ))?.id,
            "gemini"
        )
    }

    func testDoesNotRecognizeAgentNamesInArguments() {
        XCTAssertNil(AgentRecognizer.recognize(record(executable: "/bin/echo", arguments: ["echo", "codex"])))
        XCTAssertNil(AgentRecognizer.recognize(record(executable: "/bin/sh", arguments: ["sh", "-c", "claude --dangerously"])))
        XCTAssertNil(AgentRecognizer.recognize(record(executable: "/usr/bin/env", arguments: ["env", "codex"])))
        XCTAssertNil(AgentRecognizer.recognize(record(executable: "/opt/homebrew/bin/node", arguments: ["node", "/tmp/codex.js"])))
        XCTAssertNil(AgentRecognizer.recognize(record(
            executable: "/opt/homebrew/bin/node",
            arguments: ["node", "/tmp/@openai/codex/bin/codex.js.bak"]
        )))
        XCTAssertNil(AgentRecognizer.recognize(record(executable: "/opt/homebrew/bin/node", arguments: ["node", "-e", "codex"])))
    }

    func testRedactsCredentialForms() {
        let redacted = AgentRecognizer.redact([
            "--api-key", "super-secret",
            "--token=abc123",
            "https://user:pass@example.com/path",
            "OPENAI_API_KEY=sk-live",
            "--verbose",
            "--header", "text/plain"
        ])

        XCTAssertEqual(redacted, [
            "--api-key", "<redacted>",
            "--token=<redacted>",
            "https://<redacted>@example.com/path",
            "OPENAI_API_KEY=<redacted>",
            "--verbose",
            "--header", "text/plain"
        ])
    }
}

final class ProjectResolverTests: XCTestCase {
    func testResolvesRepositoryRootFromNestedWorkingDirectory() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = base.appendingPathComponent("repo")
        let nested = repository.appendingPathComponent("Sources").appendingPathComponent("App")
        try fileManager.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }

        let record = ProjectResolver.resolve(nested.path)
        XCTAssertEqual(record?.root, repository.resolvingSymlinksInPath().path)
        XCTAssertEqual(record?.gitDirectory, repository.appendingPathComponent(".git").resolvingSymlinksInPath().path)
        XCTAssertNil(ProjectResolver.resolve(nil))
        XCTAssertNil(ProjectResolver.resolve(""))
    }

    func testResolvesWorktreeGitDirFile() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let worktree = base.appendingPathComponent("worktree")
        let gitDirectory = base.appendingPathComponent("main").appendingPathComponent(".git").appendingPathComponent("worktrees").appendingPathComponent("worktree")
        try fileManager.createDirectory(at: worktree, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try "gitdir: \(gitDirectory.path)\n".write(
            to: worktree.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? fileManager.removeItem(at: base) }

        let record = ProjectResolver.resolve(worktree.path)
        XCTAssertEqual(record?.root, worktree.resolvingSymlinksInPath().path)
        XCTAssertEqual(record?.gitDirectory, gitDirectory.resolvingSymlinksInPath().path)
    }
}
