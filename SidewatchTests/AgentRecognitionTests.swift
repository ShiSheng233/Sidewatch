import Foundation
import XCTest

/// Recognition against the executable paths and arguments the kernel actually reports for
/// installed agent CLIs (captured with proc_pidpath / KERN_PROCARGS2 on a real machine).
final class AgentRecognitionTests: XCTestCase {
    private func execution(_ executable: String, _ arguments: [String]) -> ExecutionRecord {
        ExecutionRecord(
            identity: ExecutionIdentity(process: ProcessIdentity(bootID: "boot", pid: 42, startTimeMicros: 1), version: 1),
            parent: nil, responsible: nil, parentPID: 1, userID: 501, executable: executable, arguments: arguments,
            workingDirectory: nil, signingID: nil, teamID: nil, startedAt: Date(), endedAt: nil,
            state: .running, evidence: .observed, auditToken: nil
        )
    }

    private func agentID(_ executable: String, _ arguments: [String]) -> String? {
        AgentRecognizer.recognize(execution(executable, arguments))?.id
    }

    func testCodexInstallations() {
        XCTAssertEqual(agentID("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                               ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "app-server"]), "codex")
        XCTAssertEqual(agentID("/opt/homebrew/Caskroom/codex/0.169.0/bin/codex", ["codex"]), "codex")
        XCTAssertEqual(agentID("/usr/local/bin/node", ["node", "/usr/local/lib/node_modules/@openai/codex/bin/codex.js"]), "codex")
    }

    func testClaudeCodeNativeInstallerVersionedBinary() {
        // `claude` is a symlink; the kernel reports the resolved, version-named binary.
        XCTAssertEqual(agentID("/Users/dev/.local/share/claude/versions/2.1.325", ["claude", "--permission-mode", "bypassPermissions"]), "claude")
        XCTAssertEqual(agentID("/Users/dev/.local/bin/claude", ["claude"]), "claude")
        XCTAssertEqual(agentID("/usr/local/bin/node", ["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"]), "claude")
    }

    func testOmp() {
        XCTAssertEqual(agentID("/opt/homebrew/Cellar/omp/18.20.0/bin/omp", ["omp"]), "omp")
    }

    func testArgumentsAndArgv0NeverIdentifyAnAgent() {
        XCTAssertNil(agentID("/bin/echo", ["echo", "claude"]))
        XCTAssertNil(agentID("/usr/bin/python3", ["claude"]), "argv[0] is chosen by the launcher and is not evidence")
        XCTAssertNil(agentID("/bin/sh", ["sh", "-c", "omp run"]))
    }

    func testInstallDirectoryMustMatchExactTrailingComponents() {
        XCTAssertNil(agentID("/Users/dev/.local/share/claude/2.1.325", ["claude"]), "Missing the versions directory")
        XCTAssertNil(agentID("/Users/dev/claude-versions/2.1.325", ["claude"]))
        XCTAssertNil(agentID("/Users/dev/.local/share/notclaude/versions/2.1.325", ["claude"]), "Components match whole names only")
        XCTAssertNil(agentID("/Users/dev/.local/share/claude/versions/2.1.325/helper/tool", ["tool"]), "Only the executable's own directory counts")
    }

    func testDefinitionsRoundTripThroughConfigurationJSON() throws {
        let roundTrip = try JSONDecoder().decode(AgentDefinition.self, from: JSONEncoder().encode(AgentDefinition.defaults[1]))
        XCTAssertEqual(roundTrip, AgentDefinition.defaults[1])
    }
}
