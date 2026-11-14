import Foundation
import XCTest

/// End-to-end deletion boundaries using disposable files and synthetic omp records.
@MainActor
final class AgentDiskSafetyTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let home: URL
        let temporary: URL
        let project: URL
        let createdAt = Date()
        var expiredAt: Date { createdAt.addingTimeInterval(96 * 3600) }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("SidewatchDiskSafety-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            home = root.appendingPathComponent("home", isDirectory: true)
            temporary = root.appendingPathComponent("temp", isDirectory: true)
            project = home.appendingPathComponent("project", isDirectory: true)
            for directory in [temporary, project] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }

        func file(_ name: String) throws -> URL {
            let url = temporary.appendingPathComponent(name)
            try Data(repeating: 0x61, count: 16_384).write(to: url)
            return url
        }

        @discardableResult
        func session(_ id: String, paths: [URL], cwd: URL? = nil, activeAt: Date? = nil,
                     tool: String = "write", command: String? = nil) throws -> URL {
            let directory = home.appendingPathComponent(".omp/agent/sessions", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let stamp = formatter.string(from: createdAt)
            var records: [[String: Any]] = [[
                "type": "session", "version": 3, "id": id,
                "timestamp": stamp, "cwd": (cwd ?? project).path
            ]]
            for (index, path) in paths.enumerated() {
                let callID = "call-\(index)"
                let arguments: [String: String]
                if tool == "edit" {
                    arguments = ["path": path.path, "old_string": "a", "new_string": "b"]
                } else if let command {
                    arguments = ["command": command]
                } else {
                    arguments = ["path": path.path, "content": "disposable test artifact"]
                }
                records.append([
                    "type": "message", "id": "assistant-\(index)", "timestamp": stamp,
                    "message": ["role": "assistant", "content": [[
                        "type": "toolCall", "id": callID, "name": tool,
                        "arguments": arguments
                    ]]]
                ])
                records.append([
                    "type": "message", "id": "result-\(index)", "timestamp": stamp,
                    "message": ["role": "toolResult", "toolCallId": callID,
                                "toolName": tool, "isError": false,
                                "content": [["type": "text", "text": "Tool completed successfully"]]]
                ])
            }
            var data = Data()
            for record in records {
                data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
                data.append(0x0A)
            }
            let url = directory.appendingPathComponent("\(id).jsonl")
            try data.write(to: url)
            if let activeAt {
                try FileManager.default.setAttributes([.modificationDate: activeAt], ofItemAtPath: url.path)
            }
            return url
        }

        func service() -> AgentDiskAuditService {
            AgentDiskAuditService(home: home, temporaryRoots: [temporary])
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    func testCancelledCleanupPreservesEligibleArtifacts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = try fixture.file("cancelled.txt")
        try fixture.session("expired", paths: [path])
        let service = fixture.service()
        let task = Task { await service.audit(policy: .init(), cleanup: true, now: fixture.expiredAt) }
        task.cancel()
        let report = await task.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(report.removedCount, 0)
    }

    func testReplacementAfterReviewIsPreserved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = try fixture.file("replaced.txt")
        try fixture.session("expired", paths: [path])
        let service = fixture.service()
        _ = await service.audit(policy: .init(), now: fixture.expiredAt)
        try FileManager.default.removeItem(at: path)
        let replacement = Data("new content belonging to someone else".utf8)
        try replacement.write(to: path)
        let report = await service.audit(policy: .init(), cleanup: true, now: fixture.expiredAt, allowedPaths: [path.path])
        XCTAssertEqual(try Data(contentsOf: path), replacement)
        XCTAssertEqual(report.removedCount, 0)
        XCTAssertEqual(report.items.first(where: { $0.path == path.path })?.state, .failed)
    }

    func testTemporaryWorkingDirectoryDoesNotExcludeEveryTemporaryFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = try fixture.file("temporary-cwd.txt")
        try fixture.session("temporary-work", paths: [path], cwd: fixture.temporary)
        let report = await fixture.service().audit(policy: .init(), cleanup: true, now: fixture.expiredAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(report.removedCount, 1)
    }

    func testRepositoryAtTemporaryRootRemainsProtected() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.temporary.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let path = try fixture.file("source.txt")
        try fixture.session("repository", paths: [path], cwd: fixture.temporary)
        let report = await fixture.service().audit(policy: .init(), cleanup: true, now: fixture.expiredAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(report.items.first(where: { $0.path == path.path })?.reason, "review.project-cwd")
    }

    func testEditOnlyTempArtifactIsAuditedButPreserved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = try fixture.file("edited.txt")
        try fixture.session("editor", paths: [path], tool: "edit")
        let report = await fixture.service().audit(policy: .init(), cleanup: true, now: fixture.expiredAt)
        let item = try XCTUnwrap(report.items.first { $0.path == path.path })
        XCTAssertEqual(item.state, .review)
        XCTAssertEqual(item.reason, "review.modified-only")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(report.removedCount, 0)
    }

    func testCreationFollowedByEditCanBeCleanedAfterBothSessionsExpire() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = try fixture.file("created-and-edited.txt")
        try fixture.session("creator", paths: [path])
        try fixture.session("editor", paths: [path], tool: "edit")
        let report = await fixture.service().audit(policy: .init(), cleanup: true, now: fixture.expiredAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(report.removedCount, 1)
    }

    func testLiteralHeredocOutputIsAuditedAndCleaned() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = try fixture.file("shell output.txt")
        let command = "cat <<'EOF' > '\(path.path)'\ndisposable content\nEOF\n"
        try fixture.session("shell", paths: [path], tool: "bash", command: command)
        let report = await fixture.service().audit(policy: .init(), cleanup: true, now: fixture.expiredAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(report.removedCount, 1)
    }

    func testReadOnlyAuditNeverDeletesExpiredFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = try fixture.file("expired.txt")
        try fixture.session("expired", paths: [path])
        let service = fixture.service()
        let report = await service.audit(policy: .init(), cleanup: false, now: fixture.expiredAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(report.removedCount, 0)
        XCTAssertEqual(report.reclaimedBytes, 0)
        XCTAssertEqual(report.items.first(where: { $0.path == path.path })?.state, .eligible)
        XCTAssertGreaterThan(report.eligibleBytes, 0)
    }

    func testCleanupOnlyDeletesReviewedPaths() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let reviewed = try fixture.file("reviewed.txt")
        let unreviewed = try fixture.file("unreviewed.txt")
        try fixture.session("expired", paths: [reviewed, unreviewed])
        let service = fixture.service()
        let report = await service.audit(policy: .init(), cleanup: true, now: fixture.expiredAt,
                                         allowedPaths: [reviewed.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: reviewed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unreviewed.path))
        XCTAssertEqual(report.removedCount, 1)
        XCTAssertGreaterThan(report.reclaimedBytes, 0)
        XCTAssertEqual(report.items.first(where: { $0.path == unreviewed.path })?.state, .eligible)
    }

    func testAnyActiveClaimantProtectsSharedArtifact() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = try fixture.file("shared.txt")
        try fixture.session("expired", paths: [path])
        try fixture.session("active", paths: [path], activeAt: fixture.expiredAt.addingTimeInterval(-30))
        let service = fixture.service()
        let report = await service.audit(policy: .init(), cleanup: true, now: fixture.expiredAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(report.removedCount, 0)
        XCTAssertNotEqual(report.items.first(where: { $0.path == path.path })?.state, .eligible)
    }

    func testProjectInsideTemporaryRootIsPreservedAcrossClaimants() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let project = fixture.temporary.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let path = project.appendingPathComponent("source.swift")
        try Data("let important = true".utf8).write(to: path)
        try fixture.session("project-owner", paths: [path], cwd: project)
        try fixture.session("other-session", paths: [path])
        let service = fixture.service()
        let report = await service.audit(policy: .init(), cleanup: true, now: fixture.expiredAt)
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "let important = true")
        XCTAssertEqual(report.removedCount, 0)
        XCTAssertNotEqual(report.items.first(where: { $0.path == path.path })?.state, .eligible)
    }

    func testSymlinkCannotDeleteOutsideTemporaryRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.home.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: outside)
        let link = fixture.temporary.appendingPathComponent("output.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try fixture.session("expired", paths: [link])
        let service = fixture.service()
        let report = await service.audit(policy: .init(), cleanup: true, now: fixture.expiredAt)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), outside.path)
        XCTAssertEqual(report.removedCount, 0)
    }

    func testSymlinkParentCannotEscapeTemporaryRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outsideDirectory = fixture.home.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let outside = outsideDirectory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: outside)
        let link = fixture.temporary.appendingPathComponent("linked-parent", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDirectory)
        try fixture.session("expired", paths: [link.appendingPathComponent("keep.txt")])
        let service = fixture.service()
        let report = await service.audit(policy: .init(), cleanup: true, now: fixture.expiredAt)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
        XCTAssertEqual(report.removedCount, 0)
    }

    func testHardlinkPreservesBothNames() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = try fixture.file("linked.txt")
        let second = fixture.temporary.appendingPathComponent("second.txt")
        try FileManager.default.linkItem(at: path, to: second)
        try fixture.session("expired", paths: [path, second])
        let service = fixture.service()
        let report = await service.audit(policy: .init(), cleanup: true, now: fixture.expiredAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(report.removedCount, 0)
        XCTAssertEqual(report.eligibleBytes, 0)
    }

    func testCaseVariantClaimsShareOneLease() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = try fixture.file("Out.log")
        let variant = fixture.temporary.appendingPathComponent("out.log")
        guard FileManager.default.fileExists(atPath: variant.path) else {
            throw XCTSkip("The temporary volume is case-sensitive.")
        }
        try fixture.session("expired", paths: [path])
        try fixture.session("active", paths: [variant], activeAt: fixture.expiredAt.addingTimeInterval(-30))
        let report = await fixture.service().audit(policy: .init(), cleanup: true, now: fixture.expiredAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(report.removedCount, 0)
        XCTAssertEqual(report.items.count, 1, "Both spellings name one directory entry")
        XCTAssertEqual(report.items.first?.sessionIDs, ["active", "expired"])
        XCTAssertNotEqual(report.items.first?.state, .eligible)
    }

    func testUnicodeNormalizationVariantClaimsShareOneLease() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let composed = "caf\u{E9}.log"
        let decomposed = "cafe\u{301}.log"
        let path = try fixture.file(composed)
        let variant = URL(fileURLWithPath: fixture.temporary.path + "/" + decomposed)
        try fixture.session("expired", paths: [path])
        try fixture.session("active", paths: [variant], activeAt: fixture.expiredAt.addingTimeInterval(-30))
        let report = await fixture.service().audit(policy: .init(), cleanup: true, now: fixture.expiredAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(report.removedCount, 0)
        XCTAssertEqual(report.items.count, 1)
        XCTAssertNotEqual(report.items.first?.state, .eligible)
    }

    func testSessionLogDirectoryInsideTemporaryRootIsNeverEligible() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sessions = fixture.home.appendingPathComponent(".omp/agent/sessions", isDirectory: true)
        let victimLog = try fixture.session("victim", paths: [])
        let scratch = sessions.appendingPathComponent("scratch.txt")
        try Data(repeating: 0x61, count: 16_384).write(to: scratch)
        try fixture.session("expired", paths: [scratch, victimLog])
        // The session directory itself lies under a temporary root, as it does
        // when CLAUDE_CONFIG_DIR or PI_CODING_AGENT_SESSION_DIR points into /tmp.
        let service = AgentDiskAuditService(home: fixture.home, temporaryRoots: [fixture.root])
        let report = await service.audit(policy: .init(), cleanup: true, now: fixture.expiredAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: victimLog.path))
        XCTAssertEqual(report.removedCount, 0)
        for path in [scratch.path, victimLog.path] {
            XCTAssertEqual(report.items.first(where: { $0.path == path })?.reason, "review.session-log", path)
        }
    }
}
