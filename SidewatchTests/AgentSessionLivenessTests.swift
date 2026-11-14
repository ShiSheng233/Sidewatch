import Foundation
import XCTest

final class AgentSessionLivenessTests: XCTestCase {
    func testObservedWriterProtectsIdleSessionUntilExactProcessExits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidewatchWriterProof-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("session.jsonl")
        let child = Process()
        let output = Pipe()
        let input = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "exec 3>>\"$1\"; printf READY; IFS= read -r hold; exec 3>&-; printf CLOSED; IFS= read -r hold", "writer", log.path]
        child.standardOutput = output
        child.standardInput = input
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            if child.isRunning { child.terminate(); child.waitUntilExit() }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 5), Data("READY".utf8))
        let now = Date()
        let session = AgentArtifactSession(id: "omp:writer", agent: "omp", logPath: log.path,
            projectRoot: root.path, lastActivityAt: now.addingTimeInterval(-96 * 3600),
            endedAt: nil, claims: [])
        var liveness = AgentSessionLiveness()
        let active = liveness.observe([session], now: now)
        XCTAssertNil(liveness.issue)
        XCTAssertNil(active[0].endedAt)
        XCTAssertGreaterThanOrEqual(active[0].lastActivityAt, now)
        try input.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 6), Data("CLOSED".utf8))
        let closed = liveness.observe([session], now: now.addingTimeInterval(0.5))
        XCTAssertNil(closed[0].endedAt, "Closing a log descriptor does not establish process exit")
        XCTAssertEqual(closed[0].lastActivityAt, session.lastActivityAt,
                       "A server without this session's log open must not renew its idle lease forever")
        child.terminate()
        child.waitUntilExit()
        let afterExit = now.addingTimeInterval(1)
        let ended = liveness.observe([session], now: afterExit)
        XCTAssertEqual(ended[0].endedAt, afterExit)
        let resumed = AgentArtifactSession(id: session.id, agent: session.agent, logPath: log.path,
            projectRoot: root.path, lastActivityAt: afterExit.addingTimeInterval(1), endedAt: nil, claims: [])
        let reopened = liveness.observe([resumed], now: afterExit.addingTimeInterval(2))
        XCTAssertNil(reopened[0].endedAt, "New log activity invalidates a previous process exit")
    }

    func testUnobservedSessionCannotInventAnExit() {
        let now = Date()
        let session = AgentArtifactSession(id: "omp:unknown", agent: "omp",
            logPath: "/nonexistent-sidewatch-session-\(UUID().uuidString).jsonl",
            projectRoot: "/project", lastActivityAt: now.addingTimeInterval(-96 * 3600),
            endedAt: nil, claims: [])
        var liveness = AgentSessionLiveness()
        let result = liveness.observe([session], now: now)
        XCTAssertNil(result[0].endedAt)
        XCTAssertEqual(result[0].lastActivityAt, session.lastActivityAt)
    }
}
