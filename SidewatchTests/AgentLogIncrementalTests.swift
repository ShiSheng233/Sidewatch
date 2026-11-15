import Foundation
import XCTest

/// A log that only grew is parsed from where the previous read stopped, and the result must
/// match a full parse of the same bytes.
final class AgentLogIncrementalTests: XCTestCase {
    private let stamp = "2026-11-14T10:00:00.000Z"
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidewatchIncremental-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func line(_ record: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func parsed(_ reader: inout AgentSessionLogReader, _ url: URL,
                        _ provider: AgentLogProvider) throws -> AgentLogParse {
        guard case .parsed(let parse) = reader.read(logURL: url, provider: provider, home: root) else {
            throw NSError(domain: "AgentLogIncrementalTests", code: 1)
        }
        return parse
    }

    private func fresh(_ url: URL, _ provider: AgentLogProvider) throws -> AgentLogParse {
        var reader = AgentSessionLogReader()
        return try parsed(&reader, url, provider)
    }

    private func claimPaths(_ parse: AgentLogParse) -> Set<String> {
        Set(parse.session.claims.map(\.path))
    }

    func testCodexCallCompletedInALaterAppendMatchesFullParse() throws {
        let url = root.appendingPathComponent("rollout.jsonl")
        var data = try line(["type": "session_meta", "timestamp": stamp, "payload": ["id": "codex", "cwd": "/work/project"]])
        data.append(try line(["type": "response_item", "timestamp": stamp, "payload": [
            "type": "custom_tool_call", "call_id": "patch", "name": "apply_patch",
            "input": "*** Begin Patch\n*** Add File: /tmp/incremental.txt\n+x\n*** End Patch"]]))
        try data.write(to: url)

        var reader = AgentSessionLogReader()
        XCTAssertTrue(claimPaths(try parsed(&reader, url, .codex)).isEmpty, "The call has no result yet")

        try append(try line(["type": "response_item", "timestamp": stamp, "payload": [
            "type": "custom_tool_call_output", "call_id": "patch", "output": "Success"]]), to: url)
        let resumed = try parsed(&reader, url, .codex)
        XCTAssertEqual(claimPaths(resumed), ["/tmp/incremental.txt"])
        XCTAssertEqual(claimPaths(resumed), claimPaths(try fresh(url, .codex)))
        XCTAssertTrue(resumed.complete)

        // A later failure override still applies to a call read in an earlier pass.
        try append(try line(["type": "event_msg", "timestamp": stamp, "payload": ["type": "item_completed",
            "item": ["id": "patch", "type": "FileChange", "status": "failed", "exit_code": 1]]]), to: url)
        XCTAssertTrue(claimPaths(try parsed(&reader, url, .codex)).isEmpty)
        XCTAssertTrue(claimPaths(try fresh(url, .codex)).isEmpty)
    }

    func testPartialRecordIsCompletedByTheNextAppend() throws {
        let url = root.appendingPathComponent("claude.jsonl")
        let call = try line(["type": "assistant", "sessionId": "claude", "cwd": "/work/project", "timestamp": stamp,
            "message": ["content": [["type": "tool_use", "id": "write", "name": "Write",
                                     "input": ["file_path": "/tmp/partial.txt", "content": "x"]]]]])
        let result = try line(["type": "user", "timestamp": stamp, "message": ["content": [
            ["type": "tool_result", "tool_use_id": "write", "is_error": false, "content": "done"]]]])
        var data = call
        data.append(result.prefix(20))
        try data.write(to: url)

        var reader = AgentSessionLogReader()
        let partial = try parsed(&reader, url, .claude)
        XCTAssertFalse(partial.complete, "A truncated final record is never complete")
        XCTAssertTrue(claimPaths(partial).isEmpty)

        try append(result.dropFirst(20), to: url)
        let completed = try parsed(&reader, url, .claude)
        XCTAssertTrue(completed.complete)
        XCTAssertEqual(claimPaths(completed), ["/tmp/partial.txt"])
        XCTAssertEqual(claimPaths(completed), claimPaths(try fresh(url, .claude)))
    }

    func testRewrittenLogIsParsedFromTheStart() throws {
        let url = root.appendingPathComponent("claude.jsonl")
        func session(_ path: String) throws -> Data {
            var data = try line(["type": "assistant", "sessionId": "claude", "cwd": "/work/project", "timestamp": stamp,
                "message": ["content": [["type": "tool_use", "id": "write", "name": "Write",
                                         "input": ["file_path": path, "content": "x"]]]]])
            data.append(try line(["type": "user", "timestamp": stamp, "message": ["content": [
                ["type": "tool_result", "tool_use_id": "write", "is_error": false, "content": "done"]]]]))
            return data
        }
        try session("/tmp/a.txt").write(to: url)
        var reader = AgentSessionLogReader()
        XCTAssertEqual(claimPaths(try parsed(&reader, url, .claude)), ["/tmp/a.txt"])

        // Same inode, longer content, different prefix: a resume would keep the stale claim.
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: try session("/tmp/bbbbbbbbbb.txt"))
        try handle.close()
        XCTAssertEqual(claimPaths(try parsed(&reader, url, .claude)), ["/tmp/bbbbbbbbbb.txt"])
    }

    func testCacheDropsLogsThatAreNoLongerDiscovered() throws {
        let first = root.appendingPathComponent("one.jsonl")
        let second = root.appendingPathComponent("two.jsonl")
        for url in [first, second] {
            try line(["type": "session", "id": url.lastPathComponent, "timestamp": stamp, "cwd": "/work"]).write(to: url)
        }
        var reader = AgentSessionLogReader()
        _ = try parsed(&reader, first, .omp)
        _ = try parsed(&reader, second, .omp)
        XCTAssertEqual(reader.cachedLogCount, 2)
        reader.retainOnly([first.standardizedFileURL.path])
        XCTAssertEqual(reader.cachedLogCount, 1)
    }

    func testCustomConfigurationFolderMapsToItsSessionFolder() throws {
        let config = root.appendingPathComponent("work-agent-config", isDirectory: true)
        let projects = config.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let roots = AgentSessionRoots.discover(home: root, environment: [:],
                                               customFolders: [AgentSessionFolder(provider: "claude", path: config.path)])
        let custom = roots.filter { $0.folder != nil }
        XCTAssertEqual(custom.map(\.directory.path), [projects.resolvingSymlinksInPath().path])
        XCTAssertEqual(custom.first?.provider, "claude")
    }
}
