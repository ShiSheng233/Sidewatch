import Darwin
import Foundation

enum ProtectionRulePreparationError: Error, Equatable {
    case emptyPath
    case unresolvablePath(String, Int32)
    case targetTypeMismatch(String)
}

/// Pure in-memory protection-rule evaluation.
///
/// `prepare` performs all filesystem work (symlink resolution and vnode identity) when the
/// configuration is built. `evaluate` only compares the prepared values, so an authorization
/// callback never waits for disk I/O.
enum RuleMatcher {
    /// Resolves the rule path and records the current vnode identity. A rule whose target no
    /// longer matches the on-disk object is rejected rather than silently widened.
    static func prepare(_ rule: ProtectionRule) throws -> ProtectionRule {
        guard !rule.path.isEmpty else { throw ProtectionRulePreparationError.emptyPath }

        let resolvedURL = URL(fileURLWithPath: rule.path).resolvingSymlinksInPath().standardizedFileURL
        let path = resolvedURL.path
        var information = stat()
        let status = path.withCString { stat($0, &information) }
        guard status == 0 else {
            throw ProtectionRulePreparationError.unresolvablePath(path, errno)
        }

        let isDirectory = (UInt32(information.st_mode) & 0o170000) == 0o040000
        switch rule.target {
        case .directory where !isDirectory:
            throw ProtectionRulePreparationError.targetTypeMismatch(path)
        case .file where isDirectory:
            throw ProtectionRulePreparationError.targetTypeMismatch(path)
        default:
            break
        }

        var prepared = rule
        prepared.path = path
        prepared.fileIdentity = FileIdentity(device: UInt64(UInt32(bitPattern: information.st_dev)), inode: UInt64(information.st_ino))
        return prepared
    }

    static func evaluate(
        configuration: MonitorConfiguration,
        operation: ProtectedOperation,
        sourcePath: String,
        targetPath: String?,
        fileIdentity: FileIdentity?,
        agentIDs: Set<String>,
        targetFileIdentity: FileIdentity? = nil
    ) -> RuleDecision {
        // Record Only never subscribes to authorization events, but keep the evaluator honest
        // if it is called: no rule is evaluated and nothing can be denied.
        guard configuration.mode != .recordOnly else {
            return RuleDecision(evaluation: .notEvaluated, matchedRuleIDs: [], shouldDeny: false)
        }
        // Rules only apply to recognized agents. Unattributed processes never match.
        guard !agentIDs.isEmpty else {
            return RuleDecision(evaluation: .allow, matchedRuleIDs: [], shouldDeny: false)
        }

        let source = lexicalPath(sourcePath)
        let destination = targetPath.map(lexicalPath)

        var matchedRuleIDs: [String] = []
        for rule in configuration.rules where rule.enabled && rule.operations.contains(operation) {
            guard rule.agentIDs.isEmpty || !rule.agentIDs.isDisjoint(with: agentIDs) else { continue }

            var matched = false
            if let ruleIdentity = rule.fileIdentity,
               ruleIdentity == fileIdentity || (operation == .rename && ruleIdentity == targetFileIdentity) {
                matched = true
            }
            if !matched && !source.isEmpty { matched = matches(rule: rule, canonicalPath: source) }
            if !matched, let destination, !destination.isEmpty {
                matched = matches(rule: rule, canonicalPath: destination)
            }
            if matched { matchedRuleIDs.append(rule.id) }
        }

        guard !matchedRuleIDs.isEmpty else {
            return RuleDecision(evaluation: .allow, matchedRuleIDs: [], shouldDeny: false)
        }

        switch configuration.mode {
        case .protect:
            return RuleDecision(evaluation: .deny, matchedRuleIDs: matchedRuleIDs, shouldDeny: true)
        case .dryRun:
            // Would Block: evaluated as denied, but the system response remains allow.
            return RuleDecision(evaluation: .deny, matchedRuleIDs: matchedRuleIDs, shouldDeny: false)
        case .recordOnly:
            return RuleDecision(evaluation: .notEvaluated, matchedRuleIDs: [], shouldDeny: false)
        }
    }

    // MARK: - Matching

    private static func matches(rule: ProtectionRule, canonicalPath path: String) -> Bool {
        let rulePath = lexicalPath(rule.path)
        switch rule.target {
        case .file:
            return path == rulePath
        case .directory:
            if rulePath == "/" { return true }
            return path == rulePath || path.hasPrefix(rulePath + "/")
        }
    }

    /// Lexical normalization only: collapses `.`/`..` and duplicate separators without touching
    /// the filesystem. Symlinked rule paths were resolved by `prepare`; event paths that alias
    /// them are caught by vnode identity, not by a second disk lookup here.
    private static func lexicalPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return "" }
        if path == "/" || (!path.contains("/./") && !path.contains("/../") && !path.contains("//") && !path.hasSuffix("/") && !path.hasSuffix("/.") && !path.hasSuffix("/..")) { return path }
        let absolute = path
        var components: [String] = []
        for rawComponent in absolute.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(rawComponent)
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }
}
