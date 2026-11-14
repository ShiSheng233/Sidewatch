import EndpointSecurity
import Foundation

/// A file endpoint copied out of an `es_message_t`. `truncated` also covers a missing or
/// undecodable path, so callers never treat an incomplete path as a confident match.
struct ESFileEndpoint: Sendable, Equatable {
    var path: String
    var truncated: Bool
    var identity: FileIdentity?
}

/// Identifiers from an audit token used only to resolve an already observed process. The
/// start time cannot be derived from a token, so this is not an `ExecutionIdentity`.
struct ESProcessTokenIdentity: Sendable, Hashable {
    var pid: Int32
    var version: UInt32
}

struct ESProcessSnapshot: Sendable {
    var identity: ExecutionIdentity
    var parentPID: Int32
    var userID: UInt32
    var executable: String
    var signingID: String?
    var teamID: String?
    var auditToken: Data
    var startedAt: Date
    var parentToken: ESProcessTokenIdentity?
    var responsibleToken: ESProcessTokenIdentity?
}

enum ESMessagePayload: Sendable {
    case fork(child: ESProcessSnapshot)
    case exec(target: ESProcessSnapshot, arguments: [String], workingDirectory: String?)
    case exit
    case open(ESFileEndpoint)
    case create(ESFileEndpoint)
    case write(ESFileEndpoint)
    case closeModified(ESFileEndpoint)
    case rename(source: ESFileEndpoint, target: ESFileEndpoint?)
    case unlink(ESFileEndpoint)
    case authOpen(ESFileEndpoint)
    case authUnlink(ESFileEndpoint)
    case authRename(source: ESFileEndpoint, target: ESFileEndpoint?)
    case unsupported
}

struct ESDecodedMessage: Sendable {
    var occurredAt: Date
    var globalSequence: UInt64?
    var process: ESProcessSnapshot
    var payload: ESMessagePayload
}

/// Copies every value needed after the callback returns. No message-owned pointer escapes
/// this enumeration.
enum ESMessageDecoder {
    /// Offset of the event union inside `es_message_t`, resolved once for packed exec
    /// argument access. Verified against the C ABI (`offsetof` = 104 on this SDK).
    private static let eventOffset: Int = MemoryLayout<es_message_t>.offset(of: \.event) ?? 0

    static func decode(_ message: UnsafePointer<es_message_t>, bootID: String) -> ESDecodedMessage {
        let version = message.pointee.version
        let process = processSnapshot(
            message.pointee.process,
            bootID: bootID,
            messageVersion: version
        )
        let payload: ESMessagePayload
        let type = message.pointee.event_type

        if type == ES_EVENT_TYPE_NOTIFY_FORK {
            payload = .fork(child: processSnapshot(
                message.pointee.event.fork.child,
                bootID: bootID,
                messageVersion: version
            ))
        } else if type == ES_EVENT_TYPE_NOTIFY_EXEC {
            let event = execEvent(in: message)
            payload = .exec(
                target: processSnapshot(
                    event.pointee.target,
                    bootID: bootID,
                    messageVersion: version
                ),
                arguments: execArguments(event),
                workingDirectory: execWorkingDirectory(event, messageVersion: version)
            )
        } else if type == ES_EVENT_TYPE_NOTIFY_EXIT {
            payload = .exit
        } else if type == ES_EVENT_TYPE_NOTIFY_OPEN {
            payload = .open(endpoint(message.pointee.event.open.file))
        } else if type == ES_EVENT_TYPE_NOTIFY_CREATE {
            payload = .create(createEndpoint(message.pointee.event.create))
        } else if type == ES_EVENT_TYPE_NOTIFY_WRITE {
            payload = .write(endpoint(message.pointee.event.write.target))
        } else if type == ES_EVENT_TYPE_NOTIFY_CLOSE {
            let event = message.pointee.event.close
            payload = event.modified ? .closeModified(endpoint(event.target)) : .unsupported
        } else if type == ES_EVENT_TYPE_NOTIFY_RENAME {
            let event = message.pointee.event.rename
            payload = .rename(
                source: endpoint(event.source),
                target: renameDestination(event)
            )
        } else if type == ES_EVENT_TYPE_NOTIFY_UNLINK {
            payload = .unlink(endpoint(message.pointee.event.unlink.target))
        } else if type == ES_EVENT_TYPE_AUTH_OPEN {
            payload = .authOpen(endpoint(message.pointee.event.open.file))
        } else if type == ES_EVENT_TYPE_AUTH_UNLINK {
            payload = .authUnlink(endpoint(message.pointee.event.unlink.target))
        } else if type == ES_EVENT_TYPE_AUTH_RENAME {
            let event = message.pointee.event.rename
            payload = .authRename(
                source: endpoint(event.source),
                target: renameDestination(event)
            )
        } else {
            payload = .unsupported
        }

        return ESDecodedMessage(
            occurredAt: eventDate(message.pointee.time),
            globalSequence: version >= 4 ? message.pointee.global_seq_num : nil,
            process: process,
            payload: payload
        )
    }

    // MARK: - Processes

    private static func processSnapshot(
        _ process: UnsafePointer<es_process_t>,
        bootID: String,
        messageVersion: UInt32
    ) -> ESProcessSnapshot {
        let token = process.pointee.audit_token
        let pid = audit_token_to_pid(token)
        let version = UInt32(bitPattern: audit_token_to_pidversion(token))
        let euid = UInt32(audit_token_to_euid(token))
        let startTimeMicros = processStartMicros(process, messageVersion: messageVersion)
        let executableToken = process.pointee.executable.pointee.path
        let executable = string(executableToken) ?? ""

        return ESProcessSnapshot(
            identity: ExecutionIdentity(
                process: ProcessIdentity(
                    bootID: bootID,
                    pid: pid,
                    startTimeMicros: startTimeMicros
                ),
                version: version
            ),
            parentPID: process.pointee.ppid,
            userID: euid,
            executable: executable,
            signingID: nilIfEmpty(string(process.pointee.signing_id)),
            teamID: nilIfEmpty(string(process.pointee.team_id)),
            auditToken: tokenData(token),
            startedAt: SystemIdentity.date(micros: startTimeMicros),
            parentToken: messageVersion >= 4
                ? tokenIdentity(process.pointee.parent_audit_token)
                : nil,
            responsibleToken: messageVersion >= 4
                ? tokenIdentity(process.pointee.responsible_audit_token)
                : nil
        )
    }

    private static func processStartMicros(
        _ process: UnsafePointer<es_process_t>,
        messageVersion: UInt32
    ) -> Int64 {
        // `start_time` exists only in message version 3 and later. Current macOS messages
        // are well past that version; the fallback keeps identity construction total.
        guard messageVersion >= 3 else { return 0 }
        let start = process.pointee.start_time
        return Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)
    }

    private static func tokenIdentity(_ token: audit_token_t) -> ESProcessTokenIdentity? {
        let pid = audit_token_to_pid(token)
        guard pid > 0 else { return nil }
        return ESProcessTokenIdentity(
            pid: pid,
            version: UInt32(bitPattern: audit_token_to_pidversion(token))
        )
    }

    private static func tokenData(_ token: audit_token_t) -> Data {
        withUnsafeBytes(of: token) { Data($0) }
    }

    // MARK: - Exec

    /// Packed exec arguments are located relative to the event inside the live message.
    /// A copied `es_event_exec_t` value is not a valid argument base.
    private static func execEvent(
        in message: UnsafePointer<es_message_t>
    ) -> UnsafePointer<es_event_exec_t> {
        UnsafeRawPointer(message)
            .advanced(by: eventOffset)
            .assumingMemoryBound(to: es_event_exec_t.self)
    }

    private static func execArguments(
        _ event: UnsafePointer<es_event_exec_t>
    ) -> [String] {
        let count = es_exec_arg_count(event)
        var arguments: [String] = []
        arguments.reserveCapacity(Int(count))
        for index in 0..<count {
            arguments.append(string(es_exec_arg(event, index)) ?? "")
        }
        // Arguments leave the callback already redacted; environment variables are
        // never read.
        return AgentRecognizer.redact(arguments)
    }

    private static func execWorkingDirectory(
        _ event: UnsafePointer<es_event_exec_t>,
        messageVersion: UInt32
    ) -> String? {
        guard messageVersion >= 3 else { return nil }
        let cwd = endpoint(event.pointee.cwd)
        guard !cwd.truncated, !cwd.path.isEmpty else { return nil }
        return cwd.path
    }

    // MARK: - Files

    private static func endpoint(_ file: UnsafePointer<es_file_t>) -> ESFileEndpoint {
        let path = string(file.pointee.path)
        let truncated = file.pointee.path_truncated || path == nil
        let information = file.pointee.stat
        return ESFileEndpoint(
            path: path ?? "",
            truncated: truncated,
            identity: FileIdentity(
                device: UInt64(UInt32(bitPattern: information.st_dev)),
                inode: UInt64(information.st_ino)
            )
        )
    }

    private static func createEndpoint(_ event: es_event_create_t) -> ESFileEndpoint {
        if event.destination_type == ES_DESTINATION_TYPE_EXISTING_FILE {
            return endpoint(event.destination.existing_file)
        }
        return newPathEndpoint(
            directory: event.destination.new_path.dir,
            filename: event.destination.new_path.filename
        )
    }

    private static func renameDestination(_ event: es_event_rename_t) -> ESFileEndpoint? {
        if event.destination_type == ES_DESTINATION_TYPE_EXISTING_FILE {
            return endpoint(event.destination.existing_file)
        }
        return newPathEndpoint(
            directory: event.destination.new_path.dir,
            filename: event.destination.new_path.filename
        )
    }

    private static func newPathEndpoint(
        directory: UnsafePointer<es_file_t>,
        filename: es_string_token_t
    ) -> ESFileEndpoint {
        guard let parentPath = string(directory.pointee.path),
              !parentPath.isEmpty,
              !directory.pointee.path_truncated,
              let name = string(filename),
              !name.isEmpty else {
            return ESFileEndpoint(path: "", truncated: true, identity: nil)
        }
        let base = parentPath.hasSuffix("/") ? String(parentPath.dropLast()) : parentPath
        return ESFileEndpoint(path: base + "/" + name, truncated: false, identity: nil)
    }

    // MARK: - Strings and time

    static func string(_ token: es_string_token_t) -> String? {
        guard let data = token.data, token.length > 0 else { return nil }
        // Strict UTF-8. `String(decoding:as:)` would repair invalid bytes with U+FFFD and let a
        // repaired path match an unrelated rule; a nil result makes the endpoint truncated.
        return String(
            bytes: UnsafeRawBufferPointer(start: data, count: token.length),
            encoding: .utf8
        )
    }

    private static func nilIfEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func eventDate(_ time: timespec) -> Date {
        guard time.tv_sec != 0 else { return Date() }
        return Date(
            timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
        )
    }
}
