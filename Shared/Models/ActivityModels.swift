import Foundation

struct ProcessIdentity: Hashable, Codable, Sendable {
    var bootID: String
    var pid: Int32
    var startTimeMicros: Int64
    var stableID: String { "\(bootID):\(pid):\(startTimeMicros)" }
}

struct ExecutionIdentity: Hashable, Codable, Sendable {
    var process: ProcessIdentity
    var version: UInt32
    var stableID: String { "\(process.stableID):\(version)" }
}

enum EvidenceKind: String, Codable, Sendable {
    case observed, snapshot, inferred, responsible
}

enum ExecutionState: String, Codable, Sendable {
    case running, exited, unknown
}

struct ExecutionRecord: Hashable, Codable, Sendable {
    var identity: ExecutionIdentity
    var parent: ExecutionIdentity?
    var responsible: ExecutionIdentity?
    var parentPID: Int32
    var userID: UInt32
    var executable: String
    var arguments: [String]
    var workingDirectory: String?
    var signingID: String?
    var teamID: String?
    var startedAt: Date
    var endedAt: Date?
    var state: ExecutionState
    var evidence: EvidenceKind
    // Tokens are supplied only from a current live observation, never restored from disk.
    var auditToken: Data?
    var command: String { arguments.isEmpty ? executable : arguments.map(Self.quote).joined(separator: " ") }
    private static func quote(_ argument: String) -> String {
        argument.rangeOfCharacter(from: .whitespacesAndNewlines) == nil ? argument : "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum EdgeKind: String, Codable, Sendable { case fork, exec, responsible }
struct ExecutionEdge: Hashable, Codable, Sendable {
    var parent: ExecutionIdentity
    var child: ExecutionIdentity
    var kind: EdgeKind
    var evidence: EvidenceKind
    var observedAt: Date
}

struct ProjectRecord: Hashable, Codable, Sendable {
    var root: String
    var gitDirectory: String?
    var name: String { URL(fileURLWithPath: root).lastPathComponent }
}

struct AgentDefinition: Hashable, Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var executableNames: [String]
    var scriptPathComponents: [String]
    static let defaults: [Self] = [
        .init(id: "codex", name: "Codex", executableNames: ["codex"], scriptPathComponents: ["@openai/codex/bin/codex.js"]),
        .init(id: "claude", name: "Claude Code", executableNames: ["claude"], scriptPathComponents: ["@anthropic-ai/claude-code/cli.js"]),
        .init(id: "gemini", name: "Gemini CLI", executableNames: ["gemini"], scriptPathComponents: ["@google/gemini-cli/dist/index.js"]),
        .init(id: "opencode", name: "OpenCode", executableNames: ["opencode"], scriptPathComponents: [])
    ]
}

struct AgentSession: Hashable, Codable, Sendable, Identifiable {
    var id: String
    var agent: AgentDefinition
    var root: ExecutionIdentity
    var project: ProjectRecord?
    var startedAt: Date
    var endedAt: Date?
    var endReason: String?
    var evidence: EvidenceKind
}

struct ExecutionAssociation: Hashable, Codable, Sendable {
    var execution: ExecutionIdentity
    var sessionID: String
    var evidence: EvidenceKind
}

enum ActivityKind: String, Codable, Sendable, CaseIterable {
    case exec, fork, exit, open, create, write, rename, unlink, authorization, modeChange, gap
}

enum MonitoringMode: String, Codable, Sendable, CaseIterable {
    case recordOnly, dryRun, protect
}
enum RuleEvaluation: String, Codable, Sendable { case notEvaluated, allow, deny }
enum SystemResponse: String, Codable, Sendable { case notApplicable, allow, deny, failed }
enum ProtectedOperation: String, Codable, Sendable, CaseIterable { case open, delete, rename }
enum RuleTarget: String, Codable, Sendable { case file, directory }

struct FileIdentity: Hashable, Codable, Sendable {
    var device: UInt64
    var inode: UInt64
}
struct ProtectionRule: Hashable, Codable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var enabled: Bool = true
    var target: RuleTarget
    var path: String
    var fileIdentity: FileIdentity?
    var operations: Set<ProtectedOperation>
    // Empty means all recognized agents. Unattributed processes do not match.
    var agentIDs: Set<String> = []
}

struct MonitorConfiguration: Hashable, Codable, Sendable {
    var revision: Int64 = 1
    var mode: MonitoringMode = .recordOnly
    var rules: [ProtectionRule] = []
    var agentDefinitions: [AgentDefinition] = AgentDefinition.defaults
    var retentionDays: Int = 7
    var storageBudgetBytes: Int64 = 512 * 1024 * 1024
}

struct RuleDecision: Hashable, Codable, Sendable {
    var evaluation: RuleEvaluation
    var matchedRuleIDs: [String]
    var shouldDeny: Bool
}

struct ActivityRecord: Hashable, Codable, Sendable, Identifiable {
    // Assigned by the store's AUTOINCREMENT, never an ES source sequence.
    var id: Int64 = 0
    var captureID: String
    var sourceSequence: UInt64?
    var execution: ExecutionIdentity?
    var occurredAt: Date
    var kind: ActivityKind
    var sourcePath: String?
    var targetPath: String?
    var fileIdentity: FileIdentity?
    var projectRoot: String?
    var sessionIDs: [String]
    var evidence: EvidenceKind
    var configurationRevision: Int64
    var mode: MonitoringMode
    var evaluation: RuleEvaluation = .notEvaluated
    var response: SystemResponse = .notApplicable
    var matchedRuleIDs: [String] = []
    var detail: String?
}

enum TransportProtocol: String, Codable, Sendable { case tcp, udp }
struct ListeningEndpoint: Hashable, Codable, Sendable, Identifiable {
    var execution: ExecutionIdentity
    var transport: TransportProtocol
    var address: String
    var addressFamily: Int32
    var scopeID: UInt32
    var port: UInt16
    var firstObservedAt: Date
    var lastObservedAt: Date
    var endedAt: Date?
    var id: String { "\(execution.stableID)|\(transport.rawValue)|\(addressFamily)|\(address)|\(scopeID)|\(port)" }
}

struct CollectionGap: Hashable, Codable, Sendable {
    var captureID: String
    var occurredAt: Date
    var reason: String
    var missingCount: UInt64?
}

struct CaptureRecord: Hashable, Codable, Sendable {
    var id: String
    var bootID: String
    var startedAt: Date
    var endedAt: Date?
}

struct GraphSnapshot: Codable, Sendable {
    var executions: [ExecutionRecord] = []
    var edges: [ExecutionEdge] = []
    var sessions: [AgentSession] = []
    var associations: [ExecutionAssociation] = []
}

struct IngestionBatch: Codable, Sendable {
    var capture: CaptureRecord
    var graph: GraphSnapshot
    var activities: [ActivityRecord] = []
    var endpoints: [ListeningEndpoint] = []
    var gaps: [CollectionGap] = []
}

struct ActivityQuery: Codable, Sendable {
    var text: String = ""
    var sessionID: String?
    var projectRoot: String?
    var execution: ExecutionIdentity?
    var kind: ActivityKind?
    var outcome: String?
    var beforeID: Int64?
    var afterID: Int64?
    var watermark: Int64?
    var storeID: String?
    var limit: Int = 100
}
struct ActivityPage: Codable, Sendable {
    var storeID: String
    var watermark: Int64
    var activities: [ActivityRecord]
    var nextBeforeID: Int64?
}

enum MonitorAvailability: String, Codable, Sendable {
    case connecting, active, awaitingApproval, needsRestart, notInstalled, notEntitled, fullDiskAccessRequired, unavailable
}
struct MonitorHealth: Codable, Sendable {
    var availability: MonitorAvailability
    var message: String?
    var storageError: String?
    var droppedEvents: UInt64 = 0
    var activeRevision: Int64?
    var activeMode: MonitoringMode?
    var sqliteVersion: String?
}
struct MonitorSnapshot: Codable, Sendable {
    var graph: GraphSnapshot
    var endpoints: [ListeningEndpoint]
    var liveExecutions: [ExecutionRecord] = []
    var configuration: MonitorConfiguration
    var health: MonitorHealth
    var storeID: String
    var watermark: Int64
    var storageBytes: Int64 = 0
    var oldestActivity: Date?
    var captures: [CaptureRecord] = []
    var gaps: [CollectionGap] = []
}

enum ControlOperation: String, Codable, Sendable { case stop, forceQuit }
struct ControlAction: Codable, Sendable {
    var id: String = UUID().uuidString
    var execution: ExecutionIdentity
    var operation: ControlOperation
    var requestedAt: Date
    var signalSent: Bool
    var exitConfirmed: Bool
    var errorCode: Int32?
}
struct ControlRequest: Codable, Sendable {
    var execution: ExecutionIdentity
    var operation: ControlOperation
}

struct WireEnvelope<Value: Codable & Sendable>: Codable, Sendable {
    var value: Value?
    var error: String?
    var errorCode: String?
}
struct EmptyReply: Codable, Sendable {}

enum MonitorWire {
    static let version = 1
    static let serviceName = "dev.shisheng.Sidewatch.Monitor"
    static let extensionID = "dev.shisheng.Sidewatch.Monitor"
    static let hostID = "dev.shisheng.Sidewatch"
    static let teamID = "YOURTEAMID"
    static func encode<T: Codable & Sendable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    static func decode<T: Codable & Sendable>(_ type: T.Type, from data: Data) throws -> T { try JSONDecoder().decode(type, from: data) }
    static func reply<T: Codable & Sendable>(_ value: T) -> Data {
        // Every wire value in this module has a closed, JSON-encodable representation.
        do { return try encode(WireEnvelope(value: value)) }
        catch { return Data("{\"error\":\"Encoding failed\",\"errorCode\":\"encoding\"}".utf8) }
    }
    static func failure(_ message: String, code: String = "operation") -> Data {
        (try? encode(WireEnvelope<EmptyReply>(error: message, errorCode: code))) ?? Data()
    }
}
