import XCTest

final class RuleMatcherTests: XCTestCase {
    private func evaluate(
        _ configuration: MonitorConfiguration,
        operation: ProtectedOperation = .open,
        sourcePath: String,
        targetPath: String? = nil,
        fileIdentity: FileIdentity? = nil,
        agentIDs: Set<String> = ["codex"]
    ) -> RuleDecision {
        RuleMatcher.evaluate(
            configuration: configuration,
            operation: operation,
            sourcePath: sourcePath,
            targetPath: targetPath,
            fileIdentity: fileIdentity,
            agentIDs: agentIDs
        )
    }

    // MARK: - prepare

    func testPrepareResolvesSymlinkAndVnodeIdentity() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let target = directory.appendingPathComponent("secret.txt")
        try "secret".write(to: target, atomically: true, encoding: .utf8)
        let link = directory.appendingPathComponent("link.txt")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)

        let targetRule = try RuleMatcher.prepare(ProtectionRule(name: "target", target: .file, path: target.path, operations: [.open]))
        let linkRule = try RuleMatcher.prepare(ProtectionRule(name: "link", target: .file, path: link.path, operations: [.open]))

        XCTAssertEqual(linkRule.path, target.resolvingSymlinksInPath().path)
        XCTAssertEqual(linkRule.fileIdentity, targetRule.fileIdentity)
        XCTAssertNotNil(linkRule.fileIdentity)

        // Event paths may still use the symlink; vnode identity matches without any disk work.
        let decision = evaluate(
            MonitorConfiguration(mode: .protect, rules: [linkRule]),
            sourcePath: link.path,
            fileIdentity: linkRule.fileIdentity
        )
        XCTAssertEqual(decision.evaluation, .deny)
        XCTAssertTrue(decision.shouldDeny)
        XCTAssertEqual(decision.matchedRuleIDs, [linkRule.id])
    }

    func testPrepareRejectsMissingPathAndTargetTypeMismatch() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file.txt")
        try "content".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try RuleMatcher.prepare(ProtectionRule(name: "empty", target: .file, path: "", operations: [.open]))) {
            XCTAssertEqual($0 as? ProtectionRulePreparationError, .emptyPath)
        }
        XCTAssertThrowsError(try RuleMatcher.prepare(ProtectionRule(
            name: "missing",
            target: .file,
            path: directory.appendingPathComponent("nope").path,
            operations: [.open]
        ))) {
            guard let error = $0 as? ProtectionRulePreparationError,
                  case .unresolvablePath = error else {
                XCTFail("Expected unresolvablePath, got \($0)")
                return
            }
        }
        XCTAssertThrowsError(try RuleMatcher.prepare(ProtectionRule(name: "file", target: .file, path: directory.path, operations: [.open]))) {
            XCTAssertEqual($0 as? ProtectionRulePreparationError, .targetTypeMismatch(directory.resolvingSymlinksInPath().path))
        }
        XCTAssertThrowsError(try RuleMatcher.prepare(ProtectionRule(name: "dir", target: .directory, path: file.path, operations: [.delete]))) {
            XCTAssertEqual($0 as? ProtectionRulePreparationError, .targetTypeMismatch(file.resolvingSymlinksInPath().path))
        }
    }

    // MARK: - Path matching

    func testFileRuleMatchesExactPathAndVnodeIdentityOnly() throws {
        let rule = ProtectionRule(name: "file", target: .file, path: "/tmp/sidewatch-matcher/secret.txt", operations: [.open])
        let configuration = MonitorConfiguration(mode: .protect, rules: [rule])

        XCTAssertEqual(evaluate(configuration, sourcePath: "/tmp/sidewatch-matcher/secret.txt").evaluation, .deny)
        XCTAssertEqual(evaluate(configuration, sourcePath: "/tmp/sidewatch-matcher/secret.txt/../secret.txt").evaluation, .deny)
        XCTAssertEqual(evaluate(configuration, sourcePath: "/tmp/sidewatch-matcher/secret.txt.bak").evaluation, .allow)
        XCTAssertEqual(evaluate(configuration, sourcePath: "/tmp/sidewatch-matcher/other.txt").evaluation, .allow)

        let identity = FileIdentity(device: 1, inode: 2)
        XCTAssertEqual(
            evaluate(configuration, sourcePath: "/some/other/path", fileIdentity: identity).evaluation,
            .allow
        )
        var prepared = rule
        prepared.fileIdentity = identity
        let identityConfiguration = MonitorConfiguration(mode: .protect, rules: [prepared])
        XCTAssertEqual(
            evaluate(identityConfiguration, sourcePath: "/some/other/path", fileIdentity: identity).evaluation,
            .deny
        )
    }

    func testDirectoryRuleRespectsPathBoundary() {
        let directory = "/tmp/sidewatch-boundary/project"
        let rule = ProtectionRule(name: "directory", target: .directory, path: directory, operations: [.delete])
        let configuration = MonitorConfiguration(mode: .protect, rules: [rule])

        XCTAssertEqual(evaluate(configuration, operation: .delete, sourcePath: directory).evaluation, .deny)
        XCTAssertEqual(evaluate(configuration, operation: .delete, sourcePath: directory + "/nested/file.txt").evaluation, .deny)
        XCTAssertEqual(evaluate(configuration, operation: .delete, sourcePath: directory + "-old/file.txt").evaluation, .allow)
        XCTAssertEqual(evaluate(configuration, operation: .delete, sourcePath: "/tmp/sidewatch-boundary/other").evaluation, .allow)
    }

    func testRenameChecksBothSourceAndTarget() {
        let rule = ProtectionRule(name: "rename", target: .file, path: "/tmp/sidewatch-rename/secret.txt", operations: [.rename])
        let configuration = MonitorConfiguration(mode: .protect, rules: [rule])

        XCTAssertEqual(
            evaluate(configuration, operation: .rename, sourcePath: "/tmp/sidewatch-rename/other.txt", targetPath: "/tmp/sidewatch-rename/secret.txt").evaluation,
            .deny
        )
        XCTAssertEqual(
            evaluate(configuration, operation: .rename, sourcePath: "/tmp/sidewatch-rename/secret.txt", targetPath: "/tmp/sidewatch-rename/other.txt").evaluation,
            .deny
        )
        XCTAssertEqual(
            evaluate(configuration, operation: .rename, sourcePath: "/tmp/sidewatch-rename/a.txt", targetPath: "/tmp/sidewatch-rename/b.txt").evaluation,
            .allow
        )
        // The rule is bound to rename; the same path is not evaluated for delete.
        XCTAssertEqual(
            evaluate(configuration, operation: .delete, sourcePath: "/tmp/sidewatch-rename/secret.txt").evaluation,
            .allow
        )
    }

    func testAgentScopeAndDisabledRules() {
        let rule = ProtectionRule(
            name: "scoped",
            target: .file,
            path: "/tmp/sidewatch-scope/secret.txt",
            operations: [.open],
            agentIDs: ["claude"]
        )
        let configuration = MonitorConfiguration(mode: .protect, rules: [rule])

        XCTAssertEqual(evaluate(configuration, sourcePath: rule.path, agentIDs: ["claude"]).evaluation, .deny)
        XCTAssertEqual(evaluate(configuration, sourcePath: rule.path, agentIDs: ["codex"]).evaluation, .allow)
        XCTAssertEqual(evaluate(configuration, sourcePath: rule.path, agentIDs: []).evaluation, .allow)

        var openRule = rule
        openRule.agentIDs = []
        let openConfiguration = MonitorConfiguration(mode: .protect, rules: [openRule])
        XCTAssertEqual(evaluate(openConfiguration, sourcePath: rule.path, agentIDs: ["codex"]).evaluation, .deny)
        XCTAssertEqual(evaluate(openConfiguration, sourcePath: rule.path, agentIDs: []).evaluation, .allow)

        var disabled = rule
        disabled.enabled = false
        let disabledConfiguration = MonitorConfiguration(mode: .protect, rules: [disabled])
        XCTAssertEqual(evaluate(disabledConfiguration, sourcePath: rule.path, agentIDs: ["claude"]).evaluation, .allow)
    }
    func testRenameChecksExistingTargetVnodeThroughAlias() {
        let identity = FileIdentity(device: 1, inode: 42)
        let rule = ProtectionRule(name: "secret", target: .file, path: "/protected/secret", fileIdentity: identity, operations: [.rename])
        let decision = RuleMatcher.evaluate(configuration: .init(mode: .protect, rules: [rule]), operation: .rename,
                                            sourcePath: "/tmp/replacement", targetPath: "/other/hardlink",
                                            fileIdentity: .init(device: 1, inode: 99), agentIDs: ["codex"], targetFileIdentity: identity)
        XCTAssertTrue(decision.shouldDeny)
        XCTAssertEqual(decision.matchedRuleIDs, [rule.id])
    }
}
