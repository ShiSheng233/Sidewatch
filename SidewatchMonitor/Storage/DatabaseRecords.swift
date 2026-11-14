import Foundation
import GRDB

/// Storage representation of wall-clock time. All persisted instants are UTC
/// microseconds so ordering does not depend on locale or floating point.
enum MicroTime {
    static func value(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }

    static func date(_ value: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(value) / 1_000_000)
    }
}

struct StoreMetadata: Sendable, Equatable {
    var storeID: String
    var watermark: Int64
    var formatVersion: Int
}

/// Canonical JSON for the small, versioned configuration payloads. Rules are
/// normalized so an unchanged configuration always compares byte-for-byte,
/// even though `ProtectionRule` stores its operations and agent identifiers in
/// unordered sets.
enum ConfigurationJSON {
    private struct CanonicalRule: Encodable {
        var id: String
        var name: String
        var enabled: Bool
        var target: RuleTarget
        var path: String
        var fileIdentity: FileIdentity?
        var operations: [String]
        var agentIDs: [String]

        init(_ rule: ProtectionRule) {
            id = rule.id
            name = rule.name
            enabled = rule.enabled
            target = rule.target
            path = rule.path
            fileIdentity = rule.fileIdentity
            operations = rule.operations.map(\.rawValue).sorted()
            agentIDs = rule.agentIDs.sorted()
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func encodeRules(_ rules: [ProtectionRule]) throws -> String {
        let data = try encoder().encode(rules.map { CanonicalRule($0) })
        guard let string = String(data: data, encoding: .utf8) else {
            throw ActivityStoreError.corruptRecord
        }
        return string
    }

    static func decodeRules(_ json: String) throws -> [ProtectionRule] {
        try JSONDecoder().decode([ProtectionRule].self, from: Data(json.utf8))
    }

    static func encodeAgents(_ agents: [AgentDefinition]) throws -> String {
        let data = try encoder().encode(agents)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ActivityStoreError.corruptRecord
        }
        return string
    }

    static func decodeAgents(_ json: String) throws -> [AgentDefinition] {
        try JSONDecoder().decode([AgentDefinition].self, from: Data(json.utf8))
    }

    static func encodeArguments(_ arguments: [String]) throws -> String {
        let data = try JSONEncoder().encode(arguments)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ActivityStoreError.corruptRecord
        }
        return string
    }

    static func decodeArguments(_ json: String) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(json.utf8))
    }

    static func encodeStringArray(_ values: [String]) throws -> String {
        let data = try JSONEncoder().encode(values)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ActivityStoreError.corruptRecord
        }
        return string
    }

    static func decodeStringArray(_ json: String) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(json.utf8))
    }
}

/// Strict row accessors. A malformed persisted value is reported as a storage
/// error instead of crashing the extension.
enum RowMapping {
    static func required<T: DatabaseValueConvertible>(_ row: Row, _ column: String) throws -> T {
        do {
            return try row.decode(T.self, forColumn: column)
        } catch {
            throw ActivityStoreError.corruptRecord
        }
    }

    static func optional<T: DatabaseValueConvertible>(_ row: Row, _ column: String) throws -> T? {
        do {
            return try row.decode(Optional<T>.self, forColumn: column)
        } catch {
            throw ActivityStoreError.corruptRecord
        }
    }

    static func int32(_ row: Row, _ column: String) throws -> Int32 {
        let value: Int64 = try required(row, column)
        guard let converted = Int32(exactly: value) else {
            throw ActivityStoreError.corruptRecord
        }
        return converted
    }

    static func uint32(_ row: Row, _ column: String) throws -> UInt32 {
        let value: Int64 = try required(row, column)
        guard let converted = UInt32(exactly: value) else {
            throw ActivityStoreError.corruptRecord
        }
        return converted
    }

    static func enumValue<T: RawRepresentable>(
        _ row: Row,
        _ column: String,
        as type: T.Type
    ) throws -> T where T.RawValue == String {
        let raw: String = try required(row, column)
        guard let value = T(rawValue: raw) else {
            throw ActivityStoreError.corruptRecord
        }
        return value
    }

    static func identity(
        boot: String?,
        pid: Int64?,
        start: Int64?,
        version: Int64?
    ) throws -> ExecutionIdentity? {
        guard let boot, let pid, let start, let version else { return nil }
        guard let pid32 = Int32(exactly: pid), let version32 = UInt32(exactly: version) else {
            throw ActivityStoreError.corruptRecord
        }
        return ExecutionIdentity(
            process: ProcessIdentity(bootID: boot, pid: pid32, startTimeMicros: start),
            version: version32)
    }

    /// Restores an execution record for display only. Tokens are never part of
    /// the persisted graph, and the live state of a restored record is unknown.
    static func execution(from row: Row) throws -> ExecutionRecord {
        let executionIdentity = ExecutionIdentity(
            process: ProcessIdentity(
                bootID: try required(row, "boot_identifier"),
                pid: try int32(row, "pid"),
                startTimeMicros: try required(row, "start_time_us")),
            version: try uint32(row, "pidversion"))

        let argumentsJSON: String = try required(row, "arguments_json")
        let arguments = try ConfigurationJSON.decodeArguments(argumentsJSON)
        let evidence: EvidenceKind = try enumValue(row, "evidence", as: EvidenceKind.self)

        let parentBoot: String? = try optional(row, "parent_boot_identifier")
        let parentPid: Int64? = try optional(row, "parent_identity_pid")
        let parentStart: Int64? = try optional(row, "parent_identity_start_us")
        let parentVersion: Int64? = try optional(row, "parent_identity_pidversion")
        let parent = try identity(
            boot: parentBoot,
            pid: parentPid,
            start: parentStart,
            version: parentVersion)

        let responsibleBoot: String? = try optional(row, "responsible_boot_identifier")
        let responsiblePid: Int64? = try optional(row, "responsible_identity_pid")
        let responsibleStart: Int64? = try optional(row, "responsible_identity_start_us")
        let responsibleVersion: Int64? = try optional(row, "responsible_identity_pidversion")
        let responsible = try identity(
            boot: responsibleBoot,
            pid: responsiblePid,
            start: responsibleStart,
            version: responsibleVersion)

        let startedAtMicros: Int64 = try required(row, "started_at_us")
        let endedAtMicros: Int64? = try optional(row, "ended_at_us")
        let workingDirectory: String? = try optional(row, "working_directory")
        let signingID: String? = try optional(row, "signing_id")
        let teamID: String? = try optional(row, "team_id")

        return ExecutionRecord(
            identity: executionIdentity,
            parent: parent,
            responsible: responsible,
            parentPID: try int32(row, "parent_pid"),
            userID: try uint32(row, "user_id"),
            executable: try required(row, "executable"),
            arguments: arguments,
            workingDirectory: workingDirectory,
            signingID: signingID,
            teamID: teamID,
            startedAt: MicroTime.date(startedAtMicros),
            endedAt: endedAtMicros.map(MicroTime.date),
            state: .unknown,
            evidence: evidence,
            auditToken: nil)
    }
}
