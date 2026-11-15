import AppKit

/// Localized display text for stable identifiers. Persistence, XPC, and event types keep their
/// raw values; only presentation goes through the String Catalog.
@MainActor
enum DisplayText {
    static func page(_ page: SidewatchPage) -> String {
        switch page {
        case .agents: String(localized: "Agents", comment: "Sidebar page")
        case .timeline: String(localized: "Timeline", comment: "Sidebar page")
        case .ports: String(localized: "Ports & Services", comment: "Sidebar page")
        case .leftovers: String(localized: "Leftover Services", comment: "Sidebar page")
        case .diskAudit: String(localized: "Agent Disk", comment: "Sidebar page")
        case .rules: String(localized: "Protection Rules", comment: "Sidebar page")
        }
    }

    static func pageSymbol(_ page: SidewatchPage) -> String {
        switch page {
        case .agents: "terminal"
        case .timeline: "clock"
        case .ports: "network"
        case .leftovers: "exclamationmark.triangle"
        case .diskAudit: "internaldrive"
        case .rules: "lock.shield"
        }
    }

    static func agentDiskState(_ state: AgentDiskItemState) -> String {
        switch state {
        case .waiting: String(localized: "Waiting", comment: "Disk audit item state")
        case .eligible: String(localized: "Eligible", comment: "Disk audit item state")
        case .review: String(localized: "Review", comment: "Disk audit item state")
        case .removed: String(localized: "Deleted", comment: "Disk audit item state")
        case .failed: String(localized: "Failed", comment: "Disk audit item state")
        }
    }

    /// Stable reason codes from the audit engine. Unknown codes stay reviewable rather than
    /// implying that automatic deletion is safe.
    static func agentDiskReason(_ code: String) -> String {
        switch code {
        case "waiting.session-active": String(localized: "Session hasn't ended or reached the idle timeout", comment: "Disk audit reason")
        case "waiting.quiet-period": String(localized: "Session ended or timed out; waiting a few minutes", comment: "Disk audit reason")
        case "waiting.exit-grace": String(localized: "Agent exited; kept in case the session is resumed", comment: "Disk audit reason")
        case "waiting.file-open": String(localized: "A running process has this file open", comment: "Disk audit reason")
        case "eligible.session-ended": String(localized: "Agent process exited", comment: "Disk audit reason")
        case "eligible.idle-expired": String(localized: "Session reached the idle timeout", comment: "Disk audit reason")
        case "eligible.mixed": String(localized: "Every claiming session exited or reached the idle timeout", comment: "Disk audit reason")
        case "review.project-cwd": String(localized: "Inside a project folder", comment: "Disk audit reason")
        case "review.project-unknown": String(localized: "Session's project folder is unknown", comment: "Disk audit reason")
        case "review.log-incomplete": String(localized: "Session log may be incomplete", comment: "Disk audit reason")
        case "review.session-log": String(localized: "Inside an agent session log folder", comment: "Disk audit reason")
        case "review.symlink": String(localized: "Path contains a symbolic link", comment: "Disk audit reason")
        case "review.hardlink": String(localized: "File has multiple hard links", comment: "Disk audit reason")
        case "review.owner": String(localized: "Owned by another user", comment: "Disk audit reason")
        case "review.unsupported-type": String(localized: "Unsupported file type", comment: "Disk audit reason")
        case "review.directory": String(localized: "Sidewatch doesn't delete folders", comment: "Disk audit reason")
        case "review.preexisting": String(localized: "Timestamps don't match the agent's recorded writes", comment: "Disk audit reason")
        case "review.modified-only": String(localized: "The agent edited this file but may not have created it", comment: "Disk audit reason")
        case "failed.target-changed": String(localized: "File changed during cleanup", comment: "Disk audit reason")
        case "failed.delete": String(localized: "File couldn't be deleted", comment: "Disk audit reason")
        case "removed": String(localized: "Deleted", comment: "Disk audit reason")
        default: String(localized: "Review required", comment: "Disk audit reason fallback")
        }
    }

    static func idleTimeout(hours: Int) -> String {
        switch hours {
        case 1: String(localized: "1 hour", comment: "Disk audit idle timeout")
        case 24: String(localized: "24 hours", comment: "Disk audit idle timeout")
        case 72: String(localized: "3 days", comment: "Disk audit idle timeout")
        case 168: String(localized: "7 days", comment: "Disk audit idle timeout")
        default: String(localized: "\(hours) hours", comment: "Disk audit idle timeout")
        }
    }

    static func mode(_ mode: MonitoringMode) -> String {
        switch mode {
        case .recordOnly: String(localized: "Record Only", comment: "Monitoring mode")
        case .dryRun: String(localized: "Dry Run", comment: "Monitoring mode")
        case .protect: String(localized: "Protect", comment: "Monitoring mode")
        }
    }

    static func modeExplanation(_ mode: MonitoringMode) -> String {
        switch mode {
        case .recordOnly:
            String(localized: "Records process and file activity. Rules aren't evaluated and nothing is blocked.")
        case .dryRun:
            String(localized: "Evaluates enabled rules and records Would Block, but allows every operation.")
        case .protect:
            String(localized: "Denies supported operations (open, delete, rename) that match enabled rules.")
        }
    }

    static func runState(_ state: AgentRunState) -> String {
        switch state {
        case .running: String(localized: "Running", comment: "Agent or process state")
        case .exited: String(localized: "Exited", comment: "Agent or process state")
        case .unknown: String(localized: "Unknown", comment: "Agent or process state")
        }
    }

    static func evidence(_ evidence: EvidenceKind) -> String {
        switch evidence {
        case .observed: String(localized: "Observed", comment: "Attribution evidence")
        case .snapshot: String(localized: "Snapshot", comment: "Attribution evidence: from a process list, not recorded history")
        case .inferred: String(localized: "Inferred", comment: "Attribution evidence")
        case .responsible: String(localized: "Responsible process", comment: "Attribution evidence")
        }
    }

    static func kind(_ kind: ActivityKind) -> String {
        switch kind {
        case .exec: String(localized: "Exec", comment: "Activity kind")
        case .fork: String(localized: "Fork", comment: "Activity kind")
        case .exit: String(localized: "Exit", comment: "Activity kind")
        case .open: String(localized: "Open", comment: "Activity kind")
        case .create: String(localized: "Create", comment: "Activity kind")
        case .write: String(localized: "Write", comment: "Activity kind")
        case .rename: String(localized: "Rename", comment: "Activity kind")
        case .unlink: String(localized: "Delete", comment: "Activity kind (unlink)")
        case .authorization: String(localized: "Authorization", comment: "Activity kind")
        case .modeChange: String(localized: "Mode Change", comment: "Activity kind")
        case .gap: String(localized: "Collection Gap", comment: "Activity kind")
        }
    }

    static func outcome(_ activity: ActivityRecord) -> String {
        switch activity.response {
        case .deny: String(localized: "Blocked", comment: "Actual system response")
        case .failed: String(localized: "Response Failed", comment: "Actual system response")
        case .allow:
            activity.evaluation == .deny
                ? String(localized: "Would Block", comment: "Dry Run match that was allowed")
                : String(localized: "Allowed", comment: "Actual system response")
        case .notApplicable: String(localized: "Recorded", comment: "Activity without an authorization decision")
        }
    }

    static func outcomeColor(_ activity: ActivityRecord) -> NSColor {
        switch activity.response {
        case .deny: .systemRed
        case .failed: .systemOrange
        case .allow: activity.evaluation == .deny ? .systemYellow : .secondaryLabelColor
        case .notApplicable: .secondaryLabelColor
        }
    }

    static func outcomeFilter(_ filter: TimelineOutcomeFilter) -> String {
        switch filter {
        case .all: String(localized: "All Outcomes")
        case .wouldBlock: String(localized: "Would Block", comment: "Dry Run match that was allowed")
        case .blocked: String(localized: "Blocked", comment: "Actual system response")
        case .allowed: String(localized: "Allowed", comment: "Actual system response")
        case .failed: String(localized: "Response Failed", comment: "Actual system response")
        }
    }

    static func operation(_ operation: ProtectedOperation) -> String {
        switch operation {
        case .open: String(localized: "Open", comment: "Protected operation")
        case .delete: String(localized: "Delete", comment: "Protected operation")
        case .rename: String(localized: "Rename or Move", comment: "Protected operation")
        }
    }

    static func operations(_ operations: Set<ProtectedOperation>) -> String {
        ProtectedOperation.allCases.filter(operations.contains).map(operation).formatted(.list(type: .and))
    }

    static func target(_ target: RuleTarget) -> String {
        switch target {
        case .file: String(localized: "File", comment: "Rule target")
        case .directory: String(localized: "Folder", comment: "Rule target")
        }
    }

    static func transport(_ transport: TransportProtocol) -> String {
        switch transport {
        case .tcp: String(localized: "TCP", comment: "Transport protocol")
        case .udp: String(localized: "UDP", comment: "Transport protocol")
        }
    }

    static func runtime(_ runtime: RuntimeKind) -> String {
        switch runtime {
        case .python: String(localized: "Python", comment: "Runtime")
        case .node: String(localized: "Node.js", comment: "Runtime")
        case .bun: String(localized: "Bun", comment: "Runtime")
        case .deno: String(localized: "Deno", comment: "Runtime")
        case .ruby: String(localized: "Ruby", comment: "Runtime")
        case .java: String(localized: "Java", comment: "Runtime")
        case .dotnet: String(localized: ".NET", comment: "Runtime")
        case .unknown: "—"
        }
    }

    static func endReason(_ reason: String?) -> String? {
        switch reason {
        case "processExited": String(localized: "Process exited", comment: "Agent session end reason")
        case "execReplaced": String(localized: "Replaced by another program", comment: "Agent session end reason")
        case nil: nil
        default: String(localized: "Ended", comment: "Agent session end reason")
        }
    }

    static func gapReason(_ reason: String) -> String {
        switch reason {
        case "queueOverflow": String(localized: "Event queue overflow")
        case "sequenceGap": String(localized: "Missed events")
        case "persistenceFailure": String(localized: "Storage failure")
        case "authorizationDeadlineExceeded": String(localized: "Authorization deadline exceeded")
        case "authorizationResponseFailed": String(localized: "Authorization response failed")
        case "truncatedPath": String(localized: "Path too long to record")
        default: String(localized: "Collection interrupted")
        }
    }

    static func attribution(_ attributions: [ServiceAttribution]) -> String {
        guard !attributions.isEmpty else { return String(localized: "Unknown origin") }
        let names = Array(Set(attributions.map(\.agentName))).sorted()
        return names.formatted(.list(type: .and))
    }

    static func project(_ project: ProjectRecord?) -> String {
        project?.name ?? "—"
    }

    /// Executable name plus arguments, without the long launch path. The full command stays
    /// available in tooltips and the inspector.
    static func commandSummary(_ record: ExecutionRecord) -> String {
        let name = executableName(record)
        guard record.arguments.count > 1 else { return name }
        let rest = record.arguments.dropFirst().map { argument in
            argument.rangeOfCharacter(from: .whitespacesAndNewlines) == nil ? argument : "'" + argument + "'"
        }
        return ([name] + rest).joined(separator: " ")
    }

    static func address(_ endpoint: ListeningEndpoint) -> String {
        if endpoint.addressFamily == AF_INET6 {
            let scoped = endpoint.scopeID != 0 ? "\(endpoint.address)%\(endpoint.scopeID)" : endpoint.address
            return "[\(scoped)]"
        }
        return endpoint.address
    }

    static func errno(_ code: Int32) -> String {
        switch code {
        case ESTALE: String(localized: "The process changed or restarted since it was listed. Nothing was sent.")
        case ESRCH: String(localized: "The process is no longer running.")
        case EPERM, EACCES: String(localized: "You don't have permission to signal this process.")
        case ENOTCONN: String(localized: "Stopping a process requires the monitor service connection.")
        case EINVAL: String(localized: "This process can't be signaled.")
        default: String(localized: "The signal couldn't be sent (error \(Int(code))).")
        }
    }

    static func controlFeedback(_ feedback: ControlFeedback) -> String {
        var parts: [String] = []
        if feedback.signalSent {
            if feedback.exitObserved {
                parts.append(String(localized: "The process has exited."))
            } else {
                parts.append(feedback.operation == .stop
                    ? String(localized: "Stop signal sent. Waiting for the process to exit.")
                    : String(localized: "Force Quit signal sent."))
            }
        } else if let code = feedback.errorCode {
            parts.append(errno(code))
        }
        if feedback.auditErrorCode != nil {
            parts.append(String(localized: "The action couldn't be saved to history."))
        }
        return parts.joined(separator: " ")
    }

    // MARK: Formatting

    /// Compact list timestamp: time only for today, otherwise month, day, and time.
    static func dateTime(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .standard)
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func fullDateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, end.timeIntervalSince(start))
        return Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }

    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    static func executableName(_ record: ExecutionRecord?) -> String {
        guard let record else { return String(localized: "Unknown process") }
        let name = (record.executable as NSString).lastPathComponent
        return name.isEmpty ? String(localized: "Unknown process") : name
    }
}
