import Foundation
import XCTest

final class AgentSessionDiscoveryTests: XCTestCase {
    private func withHome(_ body: (URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidewatchSessionDiscovery-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(home)
    }

    @MainActor
    func testAccountHomesIncludeArchivedRollouts() async throws {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appendingPathComponent("SidewatchArchivedAccount-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: home) }
        let archive = home.appendingPathComponent(".codex-profiles/work/archived_sessions")
        let temporary = home.appendingPathComponent("temporary")
        for directory in [archive, temporary] { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
        let artifact = temporary.appendingPathComponent("output.txt")
        try Data("created by archived agent".utf8).write(to: artifact)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["path": artifact.path]), as: UTF8.self)
        let records: [[String: Any]] = [
            ["type": "session_meta", "timestamp": timestamp, "payload": ["id": "archived", "cwd": "/work/project"]],
            ["type": "response_item", "timestamp": timestamp, "payload": ["type": "function_call", "call_id": "write", "name": "write", "arguments": arguments]],
            ["type": "response_item", "timestamp": timestamp, "payload": ["type": "function_call_output", "call_id": "write", "output": "ok"]]
        ]
        var data = Data()
        for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
        try data.write(to: archive.appendingPathComponent("rollout.jsonl"))
        let service = AgentDiskAuditService(home: home, temporaryRoots: [temporary])
        let report = await service.audit(policy: .init())
        XCTAssertEqual(report.sessionCount, 1)
        XCTAssertEqual(report.items.map(\.path), [artifact.path])
        XCTAssertTrue(manager.fileExists(atPath: artifact.path))
    }

    func testExplicitProviderHomesAndPiJSONCSessionDirectory() throws {
        try withHome { home in
            let pi = home.appendingPathComponent("pi-custom")
            let flat = home.appendingPathComponent("flat-records")
            try FileManager.default.createDirectory(at: pi, withIntermediateDirectories: true)
            let settings = """
            {
              // Pi supports comments and trailing commas.
              "sessionDir": "\(flat.path)",
            }
            """
            try Data(settings.utf8).write(to: pi.appendingPathComponent("settings.json"))
            let codex = home.appendingPathComponent("custom-codex")
            let claude = home.appendingPathComponent("custom-claude")
            let roots = AgentSessionRoots.discover(home: home, environment: [
                "CODEX_HOME": codex.path,
                "CLAUDE_CONFIG_DIR": claude.path,
                "PI_CODING_AGENT_DIR": pi.path
            ])
            XCTAssertTrue(roots.contains { $0.provider == "codex" && $0.directory == codex.appendingPathComponent("archived_sessions") })
            XCTAssertTrue(roots.contains { $0.provider == "claude" && $0.directory == claude.appendingPathComponent("projects") })
            XCTAssertTrue(roots.contains { $0.provider == "pi" && $0.directory.path == flat.path })
            let overridden = AgentSessionRoots.discover(home: home, environment: [
                "PI_CODING_AGENT_DIR": pi.path,
                "PI_CODING_AGENT_SESSION_DIR": home.appendingPathComponent("override").path
            ])
            XCTAssertFalse(overridden.contains { $0.provider == "pi" && $0.directory == flat })
            XCTAssertTrue(overridden.contains { $0.provider == "pi" && $0.directory.lastPathComponent == "override" })
        }
    }

    func testRelativeEnvironmentPathsCannotScanWorkingDirectory() throws {
        try withHome { home in
            let roots = AgentSessionRoots.discover(home: home, environment: [
                "CODEX_HOME": "relative-codex", "CLAUDE_CONFIG_DIR": "relative-claude",
                "PI_CODING_AGENT_SESSION_DIR": "relative-sessions"
            ])
            XCTAssertTrue(roots.allSatisfy { $0.directory.path.hasPrefix(home.path + "/") })
            XCTAssertFalse(roots.contains { $0.directory.path.contains("relative-") })
        }
    }
}
