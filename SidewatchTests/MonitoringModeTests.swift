import XCTest

final class MonitoringModeTests: XCTestCase {
    private let protectedPath = "/tmp/sidewatch-mode/secret.txt"

    private var matchedRule: ProtectionRule {
        ProtectionRule(id: "mode-rule", name: "mode-rule", target: .file, path: protectedPath, operations: [.open])
    }

    private func evaluate(mode: MonitoringMode, path: String) -> RuleDecision {
        RuleMatcher.evaluate(
            configuration: MonitorConfiguration(mode: mode, rules: [matchedRule]),
            operation: .open,
            sourcePath: path,
            targetPath: nil,
            fileIdentity: nil,
            agentIDs: ["codex"]
        )
    }

    func testRecordOnlyNeverEvaluatesOrDenies() {
        let matched = evaluate(mode: .recordOnly, path: protectedPath)
        XCTAssertEqual(matched.evaluation, .notEvaluated)
        XCTAssertFalse(matched.shouldDeny)
        XCTAssertTrue(matched.matchedRuleIDs.isEmpty)

        let unmatched = evaluate(mode: .recordOnly, path: "/tmp/sidewatch-mode/other.txt")
        XCTAssertEqual(unmatched.evaluation, .notEvaluated)
        XCTAssertFalse(unmatched.shouldDeny)
    }

    func testDryRunRecordsWouldBlockButAllowsTheOperation() {
        let decision = evaluate(mode: .dryRun, path: protectedPath)
        XCTAssertEqual(decision.evaluation, .deny, "Dry Run records the evaluation as a would-block")
        XCTAssertFalse(decision.shouldDeny, "Dry Run never denies the system operation")
        XCTAssertEqual(decision.matchedRuleIDs, [matchedRule.id])

        let unmatched = evaluate(mode: .dryRun, path: "/tmp/sidewatch-mode/other.txt")
        XCTAssertEqual(unmatched.evaluation, .allow)
        XCTAssertFalse(unmatched.shouldDeny)
        XCTAssertTrue(unmatched.matchedRuleIDs.isEmpty)
    }

    func testProtectDeniesOnlyMatchedRules() {
        let matched = evaluate(mode: .protect, path: protectedPath)
        XCTAssertEqual(matched.evaluation, .deny)
        XCTAssertTrue(matched.shouldDeny)
        XCTAssertEqual(matched.matchedRuleIDs, [matchedRule.id])

        let unmatched = evaluate(mode: .protect, path: "/tmp/sidewatch-mode/other.txt")
        XCTAssertEqual(unmatched.evaluation, .allow)
        XCTAssertFalse(unmatched.shouldDeny)
        XCTAssertTrue(unmatched.matchedRuleIDs.isEmpty)
    }

    func testModeSwitchStopsNewDenials() {
        var configuration = MonitorConfiguration(mode: .protect, rules: [matchedRule])
        var decision = RuleMatcher.evaluate(
            configuration: configuration,
            operation: .open,
            sourcePath: protectedPath,
            targetPath: nil,
            fileIdentity: nil,
            agentIDs: ["codex"]
        )
        XCTAssertTrue(decision.shouldDeny)

        configuration.mode = .dryRun
        decision = RuleMatcher.evaluate(
            configuration: configuration,
            operation: .open,
            sourcePath: protectedPath,
            targetPath: nil,
            fileIdentity: nil,
            agentIDs: ["codex"]
        )
        XCTAssertEqual(decision.evaluation, .deny)
        XCTAssertFalse(decision.shouldDeny, "A new request under Dry Run must not inherit the old Protect response")

        configuration.mode = .recordOnly
        decision = RuleMatcher.evaluate(
            configuration: configuration,
            operation: .open,
            sourcePath: protectedPath,
            targetPath: nil,
            fileIdentity: nil,
            agentIDs: ["codex"]
        )
        XCTAssertEqual(decision.evaluation, .notEvaluated)
        XCTAssertFalse(decision.shouldDeny)
    }

    func testUnattributedProcessIsNeverDeniedInAnyMode() {
        for mode in MonitoringMode.allCases {
            let decision = RuleMatcher.evaluate(
                configuration: MonitorConfiguration(mode: mode, rules: [matchedRule]),
                operation: .open,
                sourcePath: protectedPath,
                targetPath: nil,
                fileIdentity: nil,
                agentIDs: []
            )
            XCTAssertFalse(decision.shouldDeny, "Unattributed processes must not be denied in \(mode)")
            if mode == .recordOnly {
                XCTAssertEqual(decision.evaluation, .notEvaluated)
            } else {
                XCTAssertEqual(decision.evaluation, .allow)
            }
        }
    }
}
