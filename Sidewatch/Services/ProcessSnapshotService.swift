import Foundation
import Darwin

/// Errors raised only when the native capture as a whole cannot enumerate processes.
/// Partial read failures are preserved as `ProcessQueryIssue` values in the snapshot.
struct ProcessSnapshotError: Equatable, Sendable, CustomNSError {
    static let errorDomain = "dev.shisheng.Sidewatch.ProcessSnapshot"

    /// The real errno returned by the probe, never a fabricated success.
    let code: Int32

    var errorCode: Int { Int(code) }
}

enum ProcessQueryStage: String, Codable, Hashable, Sendable {
    case enumeration, identity, executable, arguments, cwd, sockets, unknown
}

struct ProcessQueryIssue: Codable, Hashable, Sendable {
    var pid: Int32
    var stage: ProcessQueryStage
    var code: Int32
}

/// A complete process and socket observation from the native probe.
/// `socketInspectedProcesses` contains only processes whose descriptor scan completed,
/// so a missing endpoint for an uninspected process must not be treated as closed.
struct NativeProcessSnapshot: Sendable {
    var capturedAt: Date
    var executions: [ExecutionRecord]
    var endpoints: [ListeningEndpoint]
    var issues: [ProcessQueryIssue]
    var socketInspectedProcesses: Set<ProcessIdentity>
}

/// Exact executable-name recognition for locally installed runtimes. Matching never examines
/// arguments or arbitrary command substrings.
enum RuntimeKind: String, Codable, Hashable, Sendable, CaseIterable {
    case python, node, bun, deno, ruby, java, dotnet, unknown
}

enum RuntimeDetector {
    private static let exactNames: [String: RuntimeKind] = [
        "python": .python,
        "node": .node,
        "bun": .bun,
        "deno": .deno,
        "ruby": .ruby,
        "java": .java,
        "dotnet": .dotnet
    ]

    static func runtime(forExecutable executable: String) -> RuntimeKind {
        let name = (executable as NSString).lastPathComponent.lowercased()
        guard !name.isEmpty else { return .unknown }
        if let exact = exactNames[name] { return exact }
        // Python is commonly installed with a version suffix (python3, python3.12).
        if name.hasPrefix("python") {
            let suffix = name.dropFirst("python".count)
            if suffix.first?.isNumber == true,
               suffix.allSatisfy({ $0.isNumber || $0 == "." }) {
                return .python
            }
        }
        return .unknown
    }
}

/// Runs the synchronous native probe on the actor executor, off the main actor.
actor ProcessSnapshotService {
    func snapshot() throws -> NativeProcessSnapshot {
        let capturedAt = Date()
        let bootID = try SystemIdentity.bootID()
        let collector = ProbeCollector(bootID: bootID, capturedAt: capturedAt)
        let context = Unmanaged.passUnretained(collector).toOpaque()
        let status = sw_probe_capture(
            collectProcess,
            collectEndpoint,
            collectIssue,
            context
        )
        guard status == 0 else { throw ProcessSnapshotError(code: status) }
        return collector.makeSnapshot()
    }
}

// MARK: - C callback trampolines

private func collectProcess(_ info: UnsafePointer<SWProcessInfo>?, _ context: UnsafeMutableRawPointer?) {
    guard let info, let context else { return }
    Unmanaged<ProbeCollector>.fromOpaque(context).takeUnretainedValue().addProcess(info.pointee)
}

private func collectEndpoint(_ info: UnsafePointer<SWEndpointInfo>?, _ context: UnsafeMutableRawPointer?) {
    guard let info, let context else { return }
    Unmanaged<ProbeCollector>.fromOpaque(context).takeUnretainedValue().addEndpoint(info.pointee)
}

private func collectIssue(_ pid: Int32, _ stage: SWQueryStage, _ code: Int32, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<ProbeCollector>.fromOpaque(context).takeUnretainedValue()
        .addIssue(pid: pid, stage: stage, code: code)
}

// MARK: - Collection

/// Mutated only by the synchronous callbacks of a single `sw_probe_capture` invocation.
private final class ProbeCollector: @unchecked Sendable {
    private let bootID: String
    private let capturedAt: Date
    private var executions: [ExecutionRecord] = []
    private var endpoints: [ListeningEndpoint] = []
    private var issues: [ProcessQueryIssue] = []
    private var inspectedProcesses: Set<ProcessIdentity> = []
    private var endpointIDs: Set<String> = []

    init(bootID: String, capturedAt: Date) {
        self.bootID = bootID
        self.capturedAt = capturedAt
    }

    func addProcess(_ info: SWProcessInfo) {
        let process = identity(from: info.identity)
        let record = ExecutionRecord(
            identity: ExecutionIdentity(process: process, version: 0),
            parent: nil,
            responsible: nil,
            parentPID: info.identity.parent_pid,
            userID: info.identity.user_id,
            executable: Self.copyCString(info.executable) ?? "",
            arguments: AgentRecognizer.redact(Self.copyArguments(info)),
            workingDirectory: Self.copyCString(info.working_directory).flatMap { $0.isEmpty ? nil : $0 },
            signingID: nil,
            teamID: nil,
            startedAt: SystemIdentity.date(micros: info.identity.start_time_micros),
            endedAt: nil,
            state: .running,
            evidence: .snapshot,
            auditToken: nil
        )
        executions.append(record)
        if info.sockets_complete {
            inspectedProcesses.insert(process)
        }
    }

    func addEndpoint(_ info: SWEndpointInfo) {
        // The probe reports only TCP listeners and UDP bindings; never invent a transport.
        let transport: TransportProtocol
        if info.transport == IPPROTO_TCP {
            transport = .tcp
        } else if info.transport == IPPROTO_UDP {
            transport = .udp
        } else {
            return
        }
        guard let address = Self.copyCString(info.address), !address.isEmpty else { return }
        let endpoint = ListeningEndpoint(
            execution: ExecutionIdentity(process: identity(from: info.process), version: 0),
            transport: transport,
            address: address,
            addressFamily: info.address_family,
            scopeID: info.scope_id,
            port: info.port,
            firstObservedAt: capturedAt,
            lastObservedAt: capturedAt,
            endedAt: nil
        )
        guard endpointIDs.insert(endpoint.id).inserted else { return }
        endpoints.append(endpoint)
    }

    func addIssue(pid: Int32, stage: SWQueryStage, code: Int32) {
        issues.append(ProcessQueryIssue(pid: pid, stage: Self.stage(stage), code: code))
    }

    func makeSnapshot() -> NativeProcessSnapshot {
        var identitiesByPID: [Int32: ExecutionIdentity] = [:]
        identitiesByPID.reserveCapacity(executions.count)
        for record in executions {
            if let previous = identitiesByPID[record.identity.process.pid],
               previous.process.startTimeMicros > record.identity.process.startTimeMicros { continue }
            identitiesByPID[record.identity.process.pid] = record.identity
        }
        for index in executions.indices {
            let identity = executions[index].identity
            if let parent = identitiesByPID[executions[index].parentPID], parent != identity,
               parent.process.startTimeMicros <= identity.process.startTimeMicros {
                executions[index].parent = parent
            }
        }

        return NativeProcessSnapshot(
            capturedAt: capturedAt,
            executions: executions,
            endpoints: endpoints,
            issues: issues,
            socketInspectedProcesses: inspectedProcesses
        )
    }

    private func identity(from value: SWProcessIdentity) -> ProcessIdentity {
        ProcessIdentity(bootID: bootID, pid: value.pid, startTimeMicros: value.start_time_micros)
    }

    private static func stage(_ stage: SWQueryStage) -> ProcessQueryStage {
        // Raw values are the stable SWQueryStage constants declared in Shared/ProcessProbe.h.
        switch stage.rawValue {
        case 1: return .enumeration
        case 2: return .identity
        case 3: return .executable
        case 4: return .arguments
        case 5: return .cwd
        case 6: return .sockets
        default: return .unknown
        }
    }

    private static func copyCString(_ pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        if let value = String(validatingCString: pointer) { return value }
        return String(
            decodingCString: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
            as: UTF8.self
        )
    }

    /// `arguments` is `argument_count` NUL-terminated entries concatenated within
    /// `arguments_length` bytes. Never split on whitespace, never read past the buffer.
    private static func copyArguments(_ info: SWProcessInfo) -> [String] {
        guard let base = info.arguments, info.arguments_length > 0, info.argument_count > 0 else {
            return []
        }
        let buffer = UnsafeRawBufferPointer(start: base, count: Int(info.arguments_length))
        let count = Int(info.argument_count)
        var arguments: [String] = []
        arguments.reserveCapacity(count)
        var start = 0
        for index in 0..<buffer.count where buffer[index] == 0 {
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            start = index + 1
            if arguments.count == count { break }
        }
        return arguments
    }
}
