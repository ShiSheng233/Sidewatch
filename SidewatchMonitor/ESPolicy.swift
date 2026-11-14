import Foundation

/// Immutable protection policy for one owner scope.
///
/// Rules are prepared by the extension's configuration worker before they reach this value.
/// `decide` only compares copied memory state, so it is safe on the authorization path.
struct ESPreparedPolicy: Sendable, Equatable {
    let configuration: MonitorConfiguration

    init(configuration: MonitorConfiguration) {
        self.configuration = configuration
    }

    var mode: MonitoringMode { configuration.mode }
    var revision: Int64 { configuration.revision }

    /// AUTH event operations required by this policy. Record Only never needs an AUTH
    /// subscription, and disabled rules cannot match anything.
    var requiredOperations: Set<ProtectedOperation> {
        guard configuration.mode != .recordOnly else { return [] }
        var operations: Set<ProtectedOperation> = []
        for rule in configuration.rules where rule.enabled {
            operations.formUnion(rule.operations)
        }
        return operations
    }

    /// Evaluates one authorization request. A truncated endpoint cannot establish a
    /// path-only match, but its verified vnode identity can still match a prepared rule.
    func decide(
        operation: ProtectedOperation,
        sourcePath: String,
        sourceTruncated: Bool,
        targetPath: String?,
        targetTruncated: Bool,
        fileIdentity: FileIdentity?,
        targetFileIdentity: FileIdentity?,
        agentIDs: Set<String>
    ) -> RuleDecision {
        RuleMatcher.evaluate(
            configuration: configuration,
            operation: operation,
            sourcePath: sourceTruncated ? "" : sourcePath,
            targetPath: targetTruncated ? nil : targetPath,
            fileIdentity: fileIdentity,
            agentIDs: agentIDs,
            targetFileIdentity: targetFileIdentity
        )
    }

    static func requiredOperations(for policies: [ESPreparedPolicy]) -> Set<ProtectedOperation> {
        policies.reduce(into: Set<ProtectedOperation>()) { result, policy in
            result.formUnion(policy.requiredOperations)
        }
    }
}

/// One user's evaluation of a shared authorization event.
struct ESAuthScopeDecision: Sendable, Equatable {
    var userID: UInt32
    var mode: MonitoringMode
    var evaluation: RuleEvaluation
    var shouldDeny: Bool
    var matchedRuleIDs: [String]
}

/// One truthful, persistable authorization outcome for a user's own scope.
struct ESAuthScopeRecord: Sendable, Equatable {
    var userID: UInt32
    var mode: MonitoringMode
    var evaluation: RuleEvaluation
    var response: SystemResponse
    var matchedRuleIDs: [String]
}

/// The kernel response and the per-user records for a shared authorization event.
struct ESAuthResolution: Sendable, Equatable {
    /// The response the client asked Endpoint Security to apply.
    var response: SystemResponse
    /// Only outcomes whose evaluation and actual response agree with storage invariants.
    var records: [ESAuthScopeRecord]
}

/// Pure arbitration for a process owned by more than one user scope.
///
/// The kernel receives one response. Any Protect scope that matched must deny. Dry Run
/// never causes a denial on its own, and a Dry Run Would Block is recorded as an attempted
/// Allow. If another scope's Protect decision denies the shared event, Dry Run cannot
/// truthfully record a successful Allow or a denial, so that Would Block is omitted; the
/// Protect scope records the actual denial.
enum ESAuthPlanner {
    static func requestedResponse(_ decisions: [ESAuthScopeDecision]) -> SystemResponse {
        decisions.contains(where: \.shouldDeny) ? .deny : .allow
    }

    static func resolve(
        _ decisions: [ESAuthScopeDecision],
        responseSucceeded: Bool
    ) -> ESAuthResolution {
        let requested = requestedResponse(decisions)
        var records: [ESAuthScopeRecord] = []

        for decision in decisions.sorted(by: { $0.userID < $1.userID }) {
            // Only a matched ruleset produces an authorization record. An Allow carries no
            // rule history and would otherwise record every open in a user's session.
            guard decision.evaluation == .deny else { continue }

            switch decision.mode {
            case .recordOnly:
                // Record Only users are never evaluated or recorded for AUTH.
                continue

            case .dryRun:
                if !responseSucceeded {
                    // Dry Run storage permits a truthful failed response.
                    records.append(ESAuthScopeRecord(
                        userID: decision.userID,
                        mode: .dryRun,
                        evaluation: .deny,
                        response: .failed,
                        matchedRuleIDs: decision.matchedRuleIDs
                    ))
                } else if requested == .allow {
                    records.append(ESAuthScopeRecord(
                        userID: decision.userID,
                        mode: .dryRun,
                        evaluation: .deny,
                        response: .allow,
                        matchedRuleIDs: decision.matchedRuleIDs
                    ))
                }

            case .protect:
                if decision.shouldDeny {
                    records.append(ESAuthScopeRecord(
                        userID: decision.userID,
                        mode: .protect,
                        evaluation: .deny,
                        response: responseSucceeded ? .deny : .failed,
                        matchedRuleIDs: decision.matchedRuleIDs
                    ))
                }
            }
        }

        return ESAuthResolution(response: requested, records: records)
    }
}
