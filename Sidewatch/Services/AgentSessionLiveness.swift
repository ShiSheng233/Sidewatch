import Foundation
import Darwin

/// Session exit evidence comes from a process actually observed writing that log.
/// Descriptor disappearance alone is not exit: the exact PID/start identity must die.
struct AgentSessionLiveness {
    private struct Lease {
        var owners: Set<SessionWriterCollector.Writer> = []
        var endedAt: Date?
    }
    private var leases: [String: Lease] = [:]
    private(set) var issue: String?

    mutating func observe(_ sessions: [AgentArtifactSession], now: Date,
                         pruningMissingSessions: Bool = true) -> [AgentArtifactSession] {
        let paths = Set(sessions.map { canonical($0.logPath) })
        if pruningMissingSessions { leases = leases.filter { paths.contains($0.key) } }
        let collector = SessionWriterCollector(paths: paths)
        let status = sw_probe_session_writers(collectSessionWriter,
            Unmanaged.passUnretained(collector).toOpaque())
        issue = status == 0 ? nil : "Session writer observation failed (errno \(status)); cleanup is deferred."
        var result = sessions
        for index in result.indices {
            let path = canonical(result[index].logPath)
            guard status == 0 else {
                result[index].endedAt = nil
                result[index].lastActivityAt = max(result[index].lastActivityAt, now)
                continue
            }
            var lease = leases[path] ?? Lease()
            // New records after a confirmed exit may belong to a resumed session.
            if let endedAt = lease.endedAt, result[index].lastActivityAt > endedAt {
                lease = Lease()
            }
            if let writers = collector.writers[path], !writers.isEmpty {
                lease.owners.formUnion(writers)
                lease.endedAt = nil
            }
            var liveOrUnknown = false
            for owner in lease.owners {
                var current = SWProcessIdentity()
                let error = sw_probe_identity(owner.pid, &current)
                if error == 0 {
                    if current.start_time_micros == owner.startedAt && current.user_id == owner.userID {
                        liveOrUnknown = true
                        break
                    }
                } else if error != ESRCH {
                    // Permission/transient errors cannot establish an exit.
                    liveOrUnknown = true
                    break
                }
            }
            if liveOrUnknown {
                lease.endedAt = nil
                result[index].endedAt = nil
                // A long-lived app server may close an old session log while it
                // continues serving other sessions. That is not an exit, but it
                // must not renew this session's inactivity lease forever.
                if collector.writers[path]?.isEmpty == false {
                    result[index].lastActivityAt = max(result[index].lastActivityAt, now)
                }
            } else if !lease.owners.isEmpty {
                if lease.endedAt == nil { lease.endedAt = now }
                result[index].endedAt = lease.endedAt
            }
            if !lease.owners.isEmpty { leases[path] = lease }
        }
        return result
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

private final class SessionWriterCollector {
    struct Writer: Hashable {
        var pid: Int32
        var startedAt: Int64
        var userID: UInt32
    }
    let paths: Set<String>
    var writers: [String: Set<Writer>] = [:]
    init(paths: Set<String>) { self.paths = paths }

    func record(_ identity: SWProcessIdentity, path: String) {
        let path = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        guard paths.contains(path) else { return }
        writers[path, default: []].insert(Writer(pid: identity.pid,
            startedAt: identity.start_time_micros, userID: identity.user_id))
    }
}

private func collectSessionWriter(_ identity: UnsafePointer<SWProcessIdentity>?,
                                  _ path: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    guard let identity, let path, let context else { return }
    let collector = Unmanaged<SessionWriterCollector>.fromOpaque(context).takeUnretainedValue()
    collector.record(identity.pointee, path: String(cString: path))
}
