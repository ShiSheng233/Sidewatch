import Foundation

/// A JSONL tool invocation that names an output. Presence in a log is evidence of
/// intent; the filesystem creation time and a successful result must corroborate it.
struct AgentArtifactClaim: Hashable, Sendable {
    var path: String
    var tool: String
    var recordedAt: Date
    var succeeded: Bool
    /// An edit identifies an artifact but cannot establish that the agent created it.
    var creationEvidence: Bool = true
    var completedAt: Date? = nil
}

struct AgentArtifactSession: Sendable {
    var id: String
    var agent: String
    var logPath: String
    var projectRoot: String?
    var lastActivityAt: Date
    /// Set only by independently observed process exit; completing a turn is not exit.
    var endedAt: Date?
    var claims: [AgentArtifactClaim]
}

/// A session folder the user added because Sidewatch can't see the provider's
/// configuration (for example `CLAUDE_CONFIG_DIR` set only in a shell profile).
struct AgentSessionFolder: Codable, Hashable, Sendable {
    /// `AgentLogProvider` raw value.
    var provider: String
    var path: String
}

struct AgentDiskPolicy: Codable, Equatable, Sendable {
    var automaticCleanup = false
    /// A session without an explicit shutdown becomes eligible after this idle lease.
    var idleHours: Int = 72
    /// Extra provider folders to scan in addition to the discovered defaults.
    var sessionFolders: [AgentSessionFolder] = []
}

/// A directory the audit read session logs from, shown so the user can see what was covered.
struct AgentDiskSessionRoot: Hashable, Sendable {
    var provider: String
    var path: String
    /// The user-added folder this root came from; nil for discovered defaults.
    var folder: AgentSessionFolder?
    var exists: Bool

    var isCustom: Bool { folder != nil }
}

enum AgentDiskItemState: String, Sendable {
    case waiting, eligible, review, removed, failed
}

struct AgentDiskItem: Identifiable, Sendable {
    var id: String { path }
    var path: String
    var bytes: Int64
    var sessionIDs: [String]
    var agents: [String]
    var logPaths: [String]
    var tools: [String]
    var lastActivityAt: Date
    var eligibleAt: Date?
    var state: AgentDiskItemState
    /// A stable reason code translated by the host interface.
    var reason: String
}

/// A session log that claimed at least one audited item. Items refer to it by `logPath`;
/// leases are per log, so the log path identifies the session in the interface.
struct AgentDiskSession: Identifiable, Sendable {
    var id: String { logPath }
    var logPath: String
    var sessionID: String
    var agent: String
    var projectRoot: String?
    var lastActivityAt: Date
    /// Observed process exit, when Sidewatch saw the writer end.
    var endedAt: Date?
}

struct AgentDiskReport: Sendable {
    var scannedAt = Date()
    var sessionCount = 0
    var items: [AgentDiskItem] = []
    /// Sessions referenced by `items`, for grouping files under the session that wrote them.
    var sessions: [AgentDiskSession] = []
    var issues: [String] = []
    /// Every directory searched for session logs, in discovery order.
    var sessionRoots: [AgentDiskSessionRoot] = []
    var reclaimedBytes: Int64 = 0
    var removedCount = 0
    /// True when the scan stopped early. A cancelled report is never published.
    var cancelled = false

    var totalBytes: Int64 { items.reduce(0) { $1.state == .removed ? $0 : $0 + $1.bytes } }
    var eligibleBytes: Int64 { items.reduce(0) { $1.state == .eligible ? $0 + $1.bytes : $0 } }
}
