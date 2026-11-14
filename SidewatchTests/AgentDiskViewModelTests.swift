import Foundation
import XCTest

@MainActor
final class AgentDiskViewModelTests: XCTestCase {
    func testExtendingIdleTimeoutCancelsAutomaticCleanupUsingOldPolicy() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("SidewatchRetentionChange-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let temporary = root.appendingPathComponent("temp")
        let project = home.appendingPathComponent("project")
        let logs = home.appendingPathComponent(".omp/agent/sessions")
        for directory in [temporary, project, logs] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? manager.removeItem(at: root) }

        let file = temporary.appendingPathComponent("keep-after-timeout-change.txt")
        let content = Data("retain this file under the new seven-day policy".utf8)
        try content.write(to: file)
        let old = Date().addingTimeInterval(-2 * 3600)
        try manager.setAttributes([.creationDate: old, .modificationDate: old], ofItemAtPath: file.path)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: old)
        let records: [[String: Any]] = [
            ["type": "session", "id": "expired-at-one-hour", "cwd": project.path, "timestamp": timestamp],
            ["type": "message", "timestamp": timestamp, "message": ["role": "assistant", "content": [[
                "type": "toolCall", "id": "write", "name": "write", "arguments": ["path": file.path]
            ]]]],
            ["type": "message", "timestamp": timestamp, "message": ["role": "toolResult", "toolCallId": "write",
                "isError": false, "content": [["type": "text", "text": "done"]]]]
        ]
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record))
            data.append(10)
        }
        let log = logs.appendingPathComponent("session.jsonl")
        try data.write(to: log)
        try manager.setAttributes([.modificationDate: old], ofItemAtPath: log.path)

        let service = AgentDiskAuditService(home: home, temporaryRoots: [temporary])
        let eligible = await service.audit(policy: AgentDiskPolicy(idleHours: 1))
        XCTAssertEqual(eligible.items.first(where: { $0.path == file.path })?.state, .eligible)

        let suite = "SidewatchRetentionChange-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AgentDiskViewModel(service: service, defaults: defaults)
        model.setIdleHours(1)
        // Changing the timeout rescans read-only; let that finish before the cleanup tick.
        await model.activeScan?.value
        model.setAutomaticCleanup(true)
        // Both operations run on the main actor before yielding to the captured
        // scan task. Await that exact task, without sleeps or timer deadlines.
        let cleanup = try XCTUnwrap(model.timerFired())
        model.setIdleHours(168)
        // The change cancels the cleanup and starts a read-only scan under the new policy.
        let rescan = try XCTUnwrap(model.activeScan)
        await cleanup.value
        await rescan.value

        XCTAssertEqual(try Data(contentsOf: file), content)
        XCTAssertEqual(model.policy.idleHours, 168)
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.report?.removedCount, 0, "The cancelled scan must not publish its result")
        XCTAssertEqual(model.items.first(where: { $0.path == file.path })?.state, .waiting,
                       "The rescan must show eligibility under the new seven-day policy")
    }

    func testCleanConfirmedDuringScanIsQueuedNotDropped() async throws {
        let fixture = try Self.expiredSessionFixture(name: "SidewatchQueuedClean")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let suite = "SidewatchQueuedClean-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AgentDiskViewModel(service: fixture.service, defaults: defaults)
        // Changing the timeout starts a read-only refresh; the user confirms the sheet while
        // it is still running.
        model.setIdleHours(1)
        let refresh = try XCTUnwrap(model.activeScan)
        model.cleanEligible(allowedPaths: [fixture.file.path])
        XCTAssertFalse(model.canClean, "A queued cleanup must not be confirmed twice")
        await refresh.value
        let cleanup = try XCTUnwrap(model.activeScan, "The queued cleanup starts when the refresh finishes")
        await cleanup.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        XCTAssertEqual(model.report?.removedCount, 1)
        XCTAssertEqual(model.cleanupMessage?.deletedFiles, true)
    }

    func testVisibleGroupsPlaceFilesUnderTheSessionThatWroteThem() async throws {
        let fixture = try Self.expiredSessionFixture(name: "SidewatchSessionTree")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let suite = "SidewatchSessionTree-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AgentDiskViewModel(service: fixture.service, defaults: defaults)
        model.scan()
        await model.activeScan?.value

        let groups = model.visibleGroups
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.session.sessionID, "expired")
        XCTAssertEqual(group.session.agent, model.items.first?.agents.first)
        XCTAssertEqual(group.items.map(\.path), [fixture.file.path])
        XCTAssertEqual(group.bytes, group.items.first?.bytes)

        model.setSearchText("no-such-file")
        XCTAssertTrue(model.visibleGroups.isEmpty, "Search filters files before grouping")
    }

    private struct Fixture {
        var root: URL
        var file: URL
        var service: AgentDiskAuditService
    }

    /// One temp file written two hours ago by an omp session that has been idle since.
    private static func expiredSessionFixture(name: String) throws -> Fixture {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let temporary = root.appendingPathComponent("temp")
        let project = home.appendingPathComponent("project")
        let logs = home.appendingPathComponent(".omp/agent/sessions")
        for directory in [temporary, project, logs] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let file = temporary.appendingPathComponent("expired.txt")
        try Data("scratch".utf8).write(to: file)
        let old = Date().addingTimeInterval(-2 * 3600)
        try manager.setAttributes([.creationDate: old, .modificationDate: old], ofItemAtPath: file.path)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: old)
        let records: [[String: Any]] = [
            ["type": "session", "id": "expired", "cwd": project.path, "timestamp": timestamp],
            ["type": "message", "timestamp": timestamp, "message": ["role": "assistant", "content": [[
                "type": "toolCall", "id": "write", "name": "write", "arguments": ["path": file.path]
            ]]]],
            ["type": "message", "timestamp": timestamp, "message": ["role": "toolResult", "toolCallId": "write",
                "isError": false, "content": [["type": "text", "text": "done"]]]]
        ]
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record))
            data.append(10)
        }
        let log = logs.appendingPathComponent("session.jsonl")
        try data.write(to: log)
        try manager.setAttributes([.modificationDate: old], ofItemAtPath: log.path)
        return Fixture(root: root, file: file,
                       service: AgentDiskAuditService(home: home, temporaryRoots: [temporary]))
    }
}
