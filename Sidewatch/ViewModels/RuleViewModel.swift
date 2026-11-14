import Foundation

/// How the selected configuration relates to what the extension has acknowledged as active.
enum ConfigurationActivation: Equatable, Sendable {
    /// No monitor connection; rules are not being enforced or evaluated.
    case unavailable
    /// The extension acknowledged this revision and mode as active.
    case active(revision: Int64, mode: MonitoringMode)
    /// The selected revision has not been acknowledged as active yet.
    case pending(selected: Int64, active: Int64?, activeMode: MonitoringMode?)
}

enum RuleValidationError: Equatable, Sendable {
    case emptyName, relativePath, emptyOperations, tooManyRules, pathTooLong, invalidCharacters
}

/// Draft edited in the rule form. The extension canonicalizes the path and records file identity.
struct RuleDraft: Equatable, Sendable {
    var id: String?
    var name = ""
    var enabled = true
    var target: RuleTarget = .directory
    var path = ""
    var operations: Set<ProtectedOperation> = [.delete, .rename]
    var agentIDs: Set<String> = []

    init() {}

    init(_ rule: ProtectionRule) {
        id = rule.id
        name = rule.name
        enabled = rule.enabled
        target = rule.target
        path = rule.path
        operations = rule.operations
        agentIDs = rule.agentIDs
    }

    func validate(existingRuleCount: Int) -> RuleValidationError? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyName }
        if path.contains("\0") || name.contains("\0") { return .invalidCharacters }
        if !path.hasPrefix("/") { return .relativePath }
        if path.utf8.count > 4096 { return .pathTooLong }
        if operations.isEmpty { return .emptyOperations }
        if id == nil, existingRuleCount >= 512 { return .tooManyRules }
        return nil
    }

    func makeRule() -> ProtectionRule {
        ProtectionRule(
            id: id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: enabled,
            target: target,
            path: path,
            fileIdentity: nil,
            operations: operations,
            agentIDs: agentIDs
        )
    }
}

/// Rule list, mode selection, and configuration submission. Every change submits a complete,
/// immutable configuration with the next revision; only extension acknowledgment makes it active.
@MainActor
final class RuleViewModel {
    private let activity: ActivityViewModel
    private(set) var isSubmitting = false
    private(set) var lastError: String?
    private(set) var selectedRuleID: String?
    /// Recent authorization outcomes for the selected rule (Would Block, Blocked, failures).
    private(set) var ruleMatches: RelatedActivityState = .idle
    private var matchesTask: Task<Void, Never>?
    private var observers: [UUID: () -> Void] = [:]

    init(activity: ActivityViewModel) {
        self.activity = activity
        activity.observe { [weak self] change in
            guard let self, change.contains(.configuration) || change.contains(.status) else { return }
            if let id = selectedRuleID, !rules.contains(where: { $0.id == id }) {
                selectedRuleID = nil
                ruleMatches = .idle
            }
            notify()
        }
    }

    @discardableResult
    func observe(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    private func notify() { for handler in observers.values { handler() } }

    // MARK: State

    var isConnected: Bool { activity.isHistoryAvailable }
    var configuration: MonitorConfiguration? { activity.configuration }
    var rules: [ProtectionRule] {
        let all = configuration?.rules ?? []
        let query = activity.searchText
        return all.filter { ProjectionSearch.matches(query, fields: [$0.name, $0.path]) }
    }
    var allRuleCount: Int { configuration?.rules.count ?? 0 }
    var agentDefinitions: [AgentDefinition] { activity.definitions }
    var selectedMode: MonitoringMode? { configuration?.mode }
    var storageBytes: Int64? { activity.monitorSnapshot?.storageBytes }
    var oldestActivity: Date? { activity.monitorSnapshot?.oldestActivity }
    var retentionDays: Int? { configuration?.retentionDays }
    var selectedRule: ProtectionRule? { configuration?.rules.first { $0.id == selectedRuleID } }

    var activation: ConfigurationActivation {
        guard isConnected, let configuration else { return .unavailable }
        let health = activity.health
        if let revision = health?.activeRevision, let mode = health?.activeMode, revision == configuration.revision {
            return .active(revision: revision, mode: mode)
        }
        return .pending(selected: configuration.revision, active: health?.activeRevision, activeMode: health?.activeMode)
    }

    /// Operations that rules can actually intercept, for truthful coverage text.
    static let supportedOperations: [ProtectedOperation] = [.open, .delete, .rename]

    // MARK: Commands

    func selectRule(_ id: String?) {
        guard id != selectedRuleID else { return }
        selectedRuleID = id
        loadMatches()
        notify()
    }

    func setMode(_ mode: MonitoringMode) async -> Bool {
        await submit { $0.mode = mode }
    }

    func save(_ draft: RuleDraft) async -> Bool {
        if let error = draft.validate(existingRuleCount: allRuleCount) {
            lastError = Self.message(for: error)
            notify()
            return false
        }
        let rule = draft.makeRule()
        return await submit { configuration in
            if let index = configuration.rules.firstIndex(where: { $0.id == rule.id }) {
                configuration.rules[index] = rule
            } else {
                configuration.rules.append(rule)
            }
        }
    }

    func setEnabled(_ enabled: Bool, ruleID: String) async -> Bool {
        await submit { configuration in
            guard let index = configuration.rules.firstIndex(where: { $0.id == ruleID }) else { return }
            configuration.rules[index].enabled = enabled
        }
    }

    func delete(ruleID: String) async -> Bool {
        await submit { $0.rules.removeAll { $0.id == ruleID } }
    }

    func clearError() {
        lastError = nil
        notify()
    }

    private func submit(_ change: (inout MonitorConfiguration) -> Void) async -> Bool {
        guard isConnected, let current = configuration else {
            lastError = String(localized: "Connect to the monitor service to change protection settings.")
            notify()
            return false
        }
        guard !isSubmitting else { return false }
        var next = current
        change(&next)
        guard next != current else { return true }
        next.revision = current.revision + 1
        isSubmitting = true
        lastError = nil
        notify()
        defer {
            isSubmitting = false
            notify()
        }
        do {
            let acknowledged = try await activity.connection.configure(next)
            activity.applyAcknowledgedConfiguration(acknowledged)
            return true
        } catch {
            lastError = Self.configurationMessage(for: error)
            // The persisted selection may differ from what we assumed; reload it.
            activity.refresh()
            return false
        }
    }

    private func loadMatches() {
        matchesTask?.cancel()
        guard let ruleID = selectedRuleID, isConnected else {
            ruleMatches = isConnected ? .idle : .unavailable
            return
        }
        ruleMatches = .loading
        var query = ActivityQuery()
        query.kind = .authorization
        query.limit = 500
        let connection = activity.connection
        matchesTask = Task { [weak self] in
            do {
                let page = try await connection.activities(query)
                guard !Task.isCancelled, let self else { return }
                let matches = page.activities.filter { $0.matchedRuleIDs.contains(ruleID) }
                ruleMatches = .loaded(Array(matches.prefix(50)))
            } catch {
                guard !Task.isCancelled, let self else { return }
                ruleMatches = .failed(ActivityViewModel.message(for: error))
            }
            self?.notify()
        }
    }

    // MARK: Messages

    static func message(for error: RuleValidationError) -> String {
        switch error {
        case .emptyName: return String(localized: "Enter a name for the rule.")
        case .relativePath: return String(localized: "Choose a file or folder with a full path.")
        case .emptyOperations: return String(localized: "Select at least one operation to protect.")
        case .tooManyRules: return String(localized: "You can create up to 512 rules.")
        case .pathTooLong: return String(localized: "The path is too long.")
        case .invalidCharacters: return String(localized: "The name or path contains an invalid character.")
        }
    }

    static func configurationMessage(for error: Error) -> String {
        if case MonitorConnectionError.remote(let code) = error {
            switch code {
            case "configuration_conflict":
                return String(localized: "Protection settings changed elsewhere. The latest settings were reloaded; try again.")
            case "rule_path_unavailable":
                return String(localized: "The rule's file or folder couldn't be found.")
            case "rule_target_mismatch":
                return String(localized: "The rule's target type doesn't match the item on disk.")
            case "monitor_inactive":
                return String(localized: "The monitor isn't collecting activity, so protection settings can't be applied.")
            case "configuration_not_applied":
                return String(localized: "The settings were saved but the monitor didn't confirm them as active. They aren't in effect.")
            case "invalid_configuration":
                return String(localized: "The protection settings are invalid.")
            default:
                break
            }
        }
        return ActivityViewModel.message(for: error)
    }
}
