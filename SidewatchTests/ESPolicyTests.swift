import XCTest

final class ESPolicyTests: XCTestCase {
    func testTruncatedPathNeedsVerifiedVnodeIdentity() {
        let identity = FileIdentity(device: 7, inode: 42)
        let rule = ProtectionRule(id: "secret", name: "Secret", target: .file,
                                  path: "/private/secret", fileIdentity: identity, operations: [.open])
        let policy = ESPreparedPolicy(configuration: .init(mode: .protect, rules: [rule]))
        let unverified = policy.decide(operation: .open, sourcePath: rule.path, sourceTruncated: true,
                                       targetPath: nil, targetTruncated: false, fileIdentity: nil,
                                       targetFileIdentity: nil, agentIDs: ["codex"])
        XCTAssertFalse(unverified.shouldDeny)
        let verified = policy.decide(operation: .open, sourcePath: "truncated", sourceTruncated: true,
                                     targetPath: nil, targetTruncated: false, fileIdentity: identity,
                                     targetFileIdentity: nil, agentIDs: ["codex"])
        XCTAssertTrue(verified.shouldDeny)
        XCTAssertEqual(verified.matchedRuleIDs, [rule.id])
    }

    func testSharedProtectResponseNeverBecomesADryRunBlock() {
        let decisions = [
            ESAuthScopeDecision(userID: 501, mode: .dryRun, evaluation: .deny, shouldDeny: false, matchedRuleIDs: ["simulation"]),
            ESAuthScopeDecision(userID: 502, mode: .protect, evaluation: .deny, shouldDeny: true, matchedRuleIDs: ["protection"]),
            ESAuthScopeDecision(userID: 503, mode: .recordOnly, evaluation: .notEvaluated, shouldDeny: false, matchedRuleIDs: []),
        ]
        let applied = ESAuthPlanner.resolve(decisions, responseSucceeded: true)
        XCTAssertEqual(applied.response, .deny)
        XCTAssertTrue(applied.records.contains { $0.userID == 502 && $0.response == .deny })
        XCTAssertFalse(applied.records.contains { $0.mode == .dryRun && $0.response == .deny })
        XCTAssertFalse(applied.records.contains { $0.userID == 503 })

        let failed = ESAuthPlanner.resolve(decisions, responseSucceeded: false)
        XCTAssertEqual(Set(failed.records.map(\.userID)), [501, 502])
        XCTAssertTrue(failed.records.allSatisfy { $0.response == .failed })
    }

    func testAuthUnionExcludesRecordOnlyAndDisabledRules() {
        let recordOnly = ESPreparedPolicy(configuration: .init(mode: .recordOnly, rules: [
            .init(name: "Delete", target: .directory, path: "/project", operations: [.delete]),
        ]))
        let dryRun = ESPreparedPolicy(configuration: .init(mode: .dryRun, rules: [
            .init(name: "Read", target: .file, path: "/project/key", operations: [.open]),
        ]))
        let disabled = ESPreparedPolicy(configuration: .init(mode: .protect, rules: [
            .init(name: "Rename", enabled: false, target: .directory, path: "/project", operations: [.rename]),
        ]))
        XCTAssertEqual(ESPreparedPolicy.requiredOperations(for: [recordOnly, dryRun, disabled]), [.open])
    }
}
