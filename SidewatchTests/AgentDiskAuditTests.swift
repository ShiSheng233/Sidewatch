import Foundation
import XCTest

final class AgentDiskAuditTests: XCTestCase {
    private let stamp = "2026-11-14T10:00:00.000Z"

    private func parse(_ provider: AgentLogProvider, _ records: [[String: Any]],
                       tail: String = "", maxLineBytes: Int = 32 * 1024 * 1024) throws -> AgentLogParse {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SidewatchLogParser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("test.jsonl")
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            data.append(0x0A)
        }
        data.append(contentsOf: tail.utf8)
        try data.write(to: file)
        var reader = AgentSessionLogReader(maxLineBytes: maxLineBytes)
        guard case .parsed(let result) = reader.read(logURL: file, provider: provider, home: root) else {
            throw NSError(domain: "AgentDiskAuditTests.Unparsed", code: 1)
        }
        return result
    }

    private func omp(_ tool: String, _ arguments: [String: Any], error: Bool = false,
                     output: String = "done") -> [[String: Any]] {
        [
            ["type": "session", "id": "session", "timestamp": stamp, "cwd": "/work/project"],
            ["type": "message", "timestamp": stamp, "message": ["role": "assistant", "content": [
                ["type": "toolCall", "id": "call", "name": tool, "arguments": arguments]
            ]]],
            ["type": "message", "timestamp": stamp, "message": ["role": "toolResult", "toolCallId": "call",
                "isError": error, "content": [["type": "text", "text": output]]]]
        ]
    }

    func testCodexPatchAndNativeFailureOverride() throws {
        var records: [[String: Any]] = [
            ["type": "session_meta", "timestamp": stamp, "payload": ["id": "child", "cwd": "/work/child"]],
            ["type": "session_meta", "timestamp": stamp, "payload": ["id": "parent", "cwd": "/work/parent"]],
            ["type": "response_item", "timestamp": stamp, "payload": ["type": "custom_tool_call", "call_id": "patch", "name": "apply_patch",
                "input": "*** Begin Patch\n*** Add File: /tmp/new.txt\n+new\n*** Update File: /tmp/old.txt\n@@\n-old\n+new\n*** End Patch"]],
            ["type": "response_item", "timestamp": stamp, "payload": ["type": "custom_tool_call_output", "call_id": "patch", "output": "Success"]],
            ["type": "event_msg", "timestamp": stamp, "payload": ["type": "task_complete"]]
        ]
        let success = try parse(.codex, records)
        XCTAssertEqual(success.session.id, "child")
        XCTAssertNil(success.session.endedAt)
        XCTAssertEqual(Set(success.observedProjectRoots), ["/work/child", "/work/parent"])
        XCTAssertEqual(success.session.claims.first { $0.path == "/tmp/new.txt" }?.creationEvidence, true)
        XCTAssertEqual(success.session.claims.first { $0.path == "/tmp/old.txt" }?.creationEvidence, false)
        records.append(["type": "event_msg", "timestamp": stamp, "payload": ["type": "item_completed",
            "item": ["id": "patch", "type": "FileChange", "status": "failed", "exit_code": 1]]])
        XCTAssertTrue(try parse(.codex, records).session.claims.isEmpty)
    }

    func testClaudeOnlyPairsSuccessfulResultsAndRetainsRelocations() throws {
        let records: [[String: Any]] = [
            ["type": "assistant", "sessionId": "claude", "cwd": "/work/old", "timestamp": stamp, "message": ["content": [
                ["type": "tool_use", "id": "write", "name": "Write", "input": ["file_path": "/tmp/created.txt", "content": "x"]],
                ["type": "tool_use", "id": "edit", "name": "Edit", "input": ["file_path": "/tmp/edited.txt", "old_string": "x", "new_string": "y"]],
                ["type": "tool_use", "id": "failed", "name": "Write", "input": ["file_path": "/tmp/failed.txt"]],
                ["type": "tool_use", "id": "unpaired", "name": "Write", "input": ["file_path": "/tmp/unpaired.txt"]]
            ]]],
            ["type": "user", "timestamp": stamp, "message": ["content": [
                ["type": "tool_result", "tool_use_id": "write", "is_error": false, "content": "done"],
                ["type": "tool_result", "tool_use_id": "edit", "is_error": false, "content": "done"],
                ["type": "tool_result", "tool_use_id": "failed", "is_error": true, "content": "failed"]
            ]]],
            ["type": "relocated", "relocatedCwd": "/work/new", "timestamp": stamp]
        ]
        let result = try parse(.claude, records)
        XCTAssertEqual(Set(result.session.claims.map(\.path)), ["/tmp/created.txt", "/tmp/edited.txt"])
        XCTAssertEqual(result.session.claims.first { $0.path == "/tmp/edited.txt" }?.creationEvidence, false)
        XCTAssertEqual(Set(result.observedProjectRoots), ["/work/old", "/work/new"])
    }

    func testHashlineEditAndPiFailure() throws {
        let records = omp("edit", ["input": "[/tmp/edited.py#A1B2]\nPUT 1.=1:\n+print(1)"])
        let edit = try parse(.omp, records)
        XCTAssertEqual(edit.session.claims.map(\.path), ["/tmp/edited.py"])
        XCTAssertFalse(try XCTUnwrap(edit.session.claims.first).creationEvidence)
        XCTAssertTrue(try parse(.pi, omp("write", ["path": "/tmp/failed"], error: true)).session.claims.isEmpty)
    }

    func testMalformedOversizedAndUnterminatedRecordsCannotGrantCompleteEvidence() throws {
        let records = omp("write", ["path": "/tmp/created"])
        let bad = try parse(.omp, records, tail: "not-json\n{\"type\":\"message\"}")
        XCTAssertFalse(bad.complete)
        XCTAssertEqual(bad.session.claims.count, 1)
        XCTAssertFalse(bad.issues.isEmpty)
        let oversized = try parse(.omp, records, tail: String(repeating: "x", count: 2048) + "\n", maxLineBytes: 1024)
        XCTAssertFalse(oversized.complete)
        XCTAssertFalse(oversized.issues.isEmpty)
    }

    func testReadOnlyShellPathsAreNotArtifacts() throws {
        let result = try parse(.omp, omp("bash", ["command": "cat /tmp/input.txt; printf '/tmp/prose.txt'"]))
        XCTAssertTrue(result.session.claims.isEmpty)
    }

    func testLiteralShellOutputsResolveAtTheirWorkingDirectory() throws {
        let command = "cd /tmp/subdir && printf x > output.txt; /usr/bin/clang -o /tmp/program source.c; cp source /tmp/copied; tee /tmp/tee-output"
        let result = try parse(.omp, omp("bash", ["command": command]))
        XCTAssertEqual(Set(result.session.claims.map(\.path)), ["/tmp/subdir/output.txt", "/tmp/program", "/tmp/copied", "/tmp/tee-output"])
    }

    func testMktempUsesPairedOutputMatchingItsTemplate() throws {
        let command = "mktemp -d /tmp/sidewatch.XXXXXX"
        let result = try parse(.omp, omp("bash", ["command": command], output: "/tmp/sidewatch.A1b2C3\n/tmp/unrelated\n"))
        XCTAssertEqual(result.session.claims.map(\.path), ["/tmp/sidewatch.A1b2C3"])
    }

    // MARK: - Shell working directory and tokenizer

    private let shellHome = URL(fileURLWithPath: "/Users/tester")

    private func shellPaths(_ command: String, cwd: String? = "/tmp") -> Set<String> {
        Set(ShellCreationScanner.scan(command: command, cwd: cwd, home: shellHome).paths)
    }

    func testPipelinesAndSubshellsStartAtTheDirectoryInEffect() {
        XCTAssertEqual(shellPaths("cd ~/proj && git log | tee log.txt"), ["/Users/tester/proj/log.txt"])
        XCTAssertEqual(shellPaths("cd ~/proj || exit 1; echo > out.txt"), ["/Users/tester/proj/out.txt"])
        XCTAssertEqual(shellPaths("cd ~/proj && (echo > x)"), ["/Users/tester/proj/x"])
        XCTAssertEqual(shellPaths("(cd /work && echo > inner); echo > outer"), ["/work/inner", "/tmp/outer"])
        XCTAssertEqual(shellPaths("cd /work && echo | (cd sub; cat > piped) | tee teed"),
                       ["/work/sub/piped", "/work/teed"])
        XCTAssertEqual(shellPaths("cd /work | cat; echo > after"), ["/tmp/after"],
                       "A cd in a non-final pipeline segment is a subshell in every shell")
        XCTAssertEqual(shellPaths("cd /work && sleep 1 & echo > after"), ["/tmp/after"],
                       "A backgrounded list runs in a subshell")
    }

    func testUnknownOrConditionalDirectoryChangesLeaveRelativeOutputsUnresolved() {
        for command in [
            "cd \"$DIR\" && echo > out.txt",
            "false || cd /work; echo > out.txt",
            "if test -d /work; then cd /work; fi; echo > out.txt",
            "cd /work | cd /other; echo > out.txt",
            "source env.sh; echo > out.txt",
        ] {
            let scan = ShellCreationScanner.scan(command: command, cwd: "/tmp", home: shellHome)
            XCTAssertTrue(scan.paths.isEmpty, command)
            XCTAssertFalse(scan.issues.isEmpty, command)
        }
        XCTAssertEqual(shellPaths("cd \"$DIR\" && echo > /tmp/absolute"), ["/tmp/absolute"])
    }

    func testEmptyQuotedWordsAndCombinedRedirectsKeepScanning() {
        XCTAssertEqual(shellPaths("echo \"\" > /tmp/a; echo hi > /tmp/b"), ["/tmp/a", "/tmp/b"])
        XCTAssertEqual(shellPaths("printf '' > /tmp/c; touch /tmp/d"), ["/tmp/c", "/tmp/d"])
        XCTAssertEqual(shellPaths("make >& /tmp/both.log; make >&2; make >&-; make >& 2; make 2>&1 > /tmp/out"),
                       ["/tmp/both.log", "/tmp/out"])
    }

    func testRelativeWorkingDirectoryIsUnknownRatherThanProcessRelative() {
        let extractor = ToolExtractor(provider: .codex, home: shellHome, defaultCWD: "/work/project")
        let relative = extractor.extract(name: "exec_command",
            arguments: ["cmd": "echo hi > out.txt", "workdir": "build"], rawInput: nil, at: Date())
        XCTAssertTrue(relative.claims.isEmpty)
        XCTAssertFalse(relative.issues.isEmpty)
        let absolute = extractor.extract(name: "exec_command",
            arguments: ["cmd": "echo hi > out.txt", "workdir": "/tmp/build"], rawInput: nil, at: Date())
        XCTAssertEqual(absolute.claims.map(\.path), ["/tmp/build/out.txt"])
        XCTAssertNil(ToolExtractor.normalize(path: "out.txt", cwd: "relative", home: shellHome))
        XCTAssertEqual(ToolExtractor.normalize(path: "out.txt", cwd: "~/proj", home: shellHome),
                       "/Users/tester/proj/out.txt")
    }

    func testCodexNestedMetadataExitCodeIsAFailure() {
        XCTAssertFalse(ToolExtractor.outputSucceeded(#"{"output":"boom","metadata":{"exit_code":1,"duration_seconds":0.1}}"#))
        XCTAssertTrue(ToolExtractor.outputSucceeded(#"{"output":"ok","metadata":{"exit_code":0,"duration_seconds":0.1}}"#))
        let records: [[String: Any]] = [
            ["type": "session_meta", "timestamp": stamp, "payload": ["id": "codex", "cwd": "/work/project"]],
            ["type": "response_item", "timestamp": stamp, "payload": ["type": "function_call", "call_id": "shell",
                "name": "shell", "arguments": #"{"command":["bash","-lc","echo hi > /tmp/failed.txt"]}"#]],
            ["type": "response_item", "timestamp": stamp, "payload": ["type": "function_call_output", "call_id": "shell",
                "output": #"{"output":"","metadata":{"exit_code":1,"duration_seconds":0.1}}"#]]
        ]
        XCTAssertTrue(try parse(.codex, records).session.claims.isEmpty)
    }
}
