import CoreFoundation
import Darwin
import Foundation

/// A provider whose session logs describe tool invocations.
enum AgentLogProvider: String, CaseIterable, Sendable {
    case codex, claude, omp, pi
}

/// The filesystem identity of a log file used to reject stale parse caches.
struct AgentLogFileStat: Equatable, Sendable {
    var device: UInt64
    var inode: UInt64
    var size: Int64
    var modifiedSeconds: Int64
    var modifiedNanoseconds: Int64
    var isRegularFile: Bool
    var isSymbolicLink: Bool

    var modified: Date {
        Date(timeIntervalSince1970: TimeInterval(modifiedSeconds)
            + TimeInterval(modifiedNanoseconds) / 1_000_000_000)
    }
}

struct AgentLogParse: Sendable {
    var session: AgentArtifactSession
    var issues: [String]
    /// False when a malformed, oversized, or truncated record was skipped. Claims from
    /// an incomplete scan are never eligible for automatic cleanup.
    var complete: Bool
    var stat: AgentLogFileStat
    /// Every project cwd observed in the log. Claude relocations and Codex turn
    /// contexts may change it; all observed roots protect their subtrees.
    var observedProjectRoots: [String]
}

enum AgentLogReadResult: Sendable {
    case parsed(AgentLogParse)
    case missing
    case skipped(String)
}

/// Reads one JSONL session log at a time. Parsing is bounded per line and cached by
/// `(device, inode, size, mtime)`, so an unchanged log is never parsed twice. A log that
/// only grew since its last parse resumes from the end of its last complete record
/// instead of being parsed again from the start.
///
/// Log content is data only: nothing read here is ever executed, and only structured
/// tool-call/tool-result fields are inspected. Arbitrary output text is never treated
/// as a path.
struct AgentSessionLogReader {
    /// Parser state at the end of the last complete record, so an appended log can be
    /// parsed from where the previous read stopped.
    private struct Resume {
        var accumulator: LogAccumulator
        var summary: LineScanSummary
        var offset: UInt64
        var lineNumber: Int
        /// The bytes just before `offset`. A log whose prefix was rewritten in place is
        /// parsed again from the start rather than resumed.
        var tail: Data
    }

    private struct Cached {
        var stat: AgentLogFileStat
        var provider: AgentLogProvider
        var parse: AgentLogParse
        var resume: Resume?
    }

    private static let tailBytes = 256
    private static let chunkBytes = 64 * 1024

    private var cache: [String: Cached] = [:]
    let maxLineBytes: Int

    init(maxLineBytes: Int = 32 * 1024 * 1024) {
        self.maxLineBytes = maxLineBytes
    }

    /// Number of logs with cached parser state. Tests use it to check trimming.
    var cachedLogCount: Int { cache.count }

    /// Drops cached parses for logs that are no longer discovered, so the cache doesn't
    /// grow with every log that ever existed.
    mutating func retainOnly(_ logPaths: Set<String>) {
        cache = cache.filter { logPaths.contains($0.key) }
    }

    mutating func read(logURL: URL, provider: AgentLogProvider, home: URL) -> AgentLogReadResult {
        guard let stat = Self.stat(of: logURL) else { return .missing }
        if stat.isSymbolicLink {
            return .skipped("the log is a symbolic link")
        }
        guard stat.isRegularFile else {
            return .skipped("the log is not a regular file")
        }
        let key = logURL.standardizedFileURL.path
        let cached = cache[key]
        if let cached, cached.stat == stat, cached.provider == provider {
            var parse = cached.parse
            // The lease always uses the newest log mtime, even on a cache hit.
            if stat.modified > parse.session.lastActivityAt {
                parse.session.lastActivityAt = stat.modified
            }
            return .parsed(parse)
        }
        var resume: Resume?
        if let cached, cached.provider == provider,
           cached.stat.device == stat.device, cached.stat.inode == stat.inode,
           let previous = cached.resume, UInt64(stat.size) >= previous.offset,
           Self.tailMatches(url: logURL, offset: previous.offset, tail: previous.tail) {
            resume = previous
        }
        do {
            let (parse, next) = try parseLog(logURL: logURL, provider: provider, home: home,
                                             stat: stat, resume: resume)
            cache[key] = Cached(stat: stat, provider: provider, parse: parse, resume: next)
            return .parsed(parse)
        } catch is CancellationError {
            // Keep the previous state; a later scan resumes from it.
            return .skipped("the scan was cancelled")
        } catch {
            cache.removeValue(forKey: key)
            return .skipped(error.localizedDescription)
        }
    }

    /// Current stat for a log, used to revalidate leases immediately before deletion.
    static func stat(of url: URL) -> AgentLogFileStat? {
        var info = Darwin.stat()
        let result = url.path.withCString { Darwin.lstat($0, &info) }
        guard result == 0 else { return nil }
        return AgentLogFileStat(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            isRegularFile: (info.st_mode & S_IFMT) == S_IFREG,
            isSymbolicLink: (info.st_mode & S_IFMT) == S_IFLNK
        )
    }

    private static func tailMatches(url: URL, offset: UInt64, tail: Data) -> Bool {
        guard UInt64(tail.count) <= offset else { return false }
        guard !tail.isEmpty else { return offset == 0 }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset - UInt64(tail.count))
            return try handle.read(upToCount: tail.count) == tail
        } catch {
            return false
        }
    }

    private func parseLog(logURL: URL, provider: AgentLogProvider, home: URL,
                          stat: AgentLogFileStat, resume: Resume?) throws -> (AgentLogParse, Resume?) {
        var accumulator = resume?.accumulator ?? LogAccumulator(
            provider: provider,
            logPath: logURL.standardizedFileURL.path,
            home: home,
            fileModified: stat.modified
        )
        let scan = try Self.readLines(url: logURL, maxLineBytes: maxLineBytes,
                                      from: resume.map { ($0.offset, $0.lineNumber, $0.summary) }) { data, lineNumber in
            accumulator.ingest(data, lineNumber: lineNumber)
        }
        let summary = scan.summary

        // Resume state captures the parser before any end-of-file handling, so an appended
        // record continues exactly where the complete records ended.
        var next: Resume?
        if let offset = scan.consumedOffset {
            // A resumed read that found no new complete record keeps the previous tail.
            let tail = scan.tail.isEmpty ? (resume?.tail ?? Data()) : scan.tail
            next = Resume(accumulator: accumulator, summary: scan.resumableSummary, offset: offset,
                          lineNumber: scan.lineNumber, tail: tail)
        }

        var issues = accumulator.issues
        if summary.malformedCount > 0 {
            issues.append("Skipped \(summary.malformedCount) malformed record(s) in \(accumulator.logPath) (first at line \(summary.firstMalformedLine ?? 0)).")
        }
        if summary.oversizedCount > 0 {
            issues.append("Skipped \(summary.oversizedCount) oversized record(s) in \(accumulator.logPath).")
        }
        if summary.truncatedFinalRecord {
            issues.append("Skipped a truncated final record in \(accumulator.logPath).")
        }

        let fallbackID: String
        let stem = logURL.deletingPathExtension().lastPathComponent
        if (provider == .omp || provider == .pi), let separator = stem.firstIndex(of: "_") {
            fallbackID = String(stem[stem.index(after: separator)...])
        } else {
            fallbackID = stem
        }
        var lastActivity = max(accumulator.lastActivity, stat.modified)
        // `finalClaims` folds pending Codex calls into the claim list, so it runs on a copy
        // that never becomes resume state.
        var finished = accumulator
        let finalClaims = finished.finalClaims()
        for claim in finalClaims where claim.recordedAt > lastActivity {
            lastActivity = claim.recordedAt
        }
        let session = AgentArtifactSession(
            id: accumulator.sessionID ?? fallbackID,
            agent: provider.rawValue,
            logPath: accumulator.logPath,
            projectRoot: accumulator.projectRoot,
            lastActivityAt: lastActivity,
            endedAt: nil,
            claims: finalClaims
        )
        let parse = AgentLogParse(
            session: session,
            issues: issues,
            complete: summary.complete ? accumulator.complete : false,
            stat: stat,
            observedProjectRoots: accumulator.observedProjectRoots
        )
        return (parse, next)
    }

    // MARK: - Bounded line streaming

    private struct LineScanSummary {
        var complete = true
        var malformedCount = 0
        var firstMalformedLine: Int?
        var oversizedCount = 0
        var truncatedFinalRecord = false
    }

    private struct LineScan {
        var summary: LineScanSummary
        /// The summary before the unfinished final record was considered; resume state
        /// starts from it so a record completed later isn't counted as truncated.
        var resumableSummary: LineScanSummary
        var lineNumber: Int
        /// File offset just past the last complete record, or nil when the read ended in
        /// the middle of an oversized record and can't be resumed.
        var consumedOffset: UInt64?
        var tail: Data
    }

    /// Streams a log in fixed-size chunks. Each line is capped; an oversized line is
    /// skipped without accumulating unbounded memory. A record that cannot be decoded
    /// is counted and excluded rather than guessed at. Cancellation is checked per chunk.
    private static func readLines(url: URL, maxLineBytes: Int,
                                  from start: (offset: UInt64, lineNumber: Int, summary: LineScanSummary)?,
                                  onLine: (Data, Int) -> Bool) throws -> LineScan {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let startOffset = start?.offset ?? 0
        if startOffset > 0 { try handle.seek(toOffset: startOffset) }

        var summary = start?.summary ?? LineScanSummary()
        var buffer = Data()
        var lineNumber = start?.lineNumber ?? 0
        var skippingOversized = false
        var totalRead: UInt64 = 0
        var tail = Data()

        func consumeLine(_ lineData: Data) {
            lineNumber += 1
            if skippingOversized {
                skippingOversized = false
                return
            }
            if lineData.count > maxLineBytes {
                summary.oversizedCount += 1
                summary.complete = false
                return
            }
            if lineData.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                return
            }
            let valid = autoreleasepool { onLine(lineData, lineNumber) }
            if !valid {
                summary.malformedCount += 1
                summary.complete = false
                if summary.firstMalformedLine == nil {
                    summary.firstMalformedLine = lineNumber
                }
            }
        }

        // FileHandle's autoreleased NSData chunks must drain too; an actor call
        // can otherwise retain the entire log corpus until the scan returns.
        while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: chunkBytes) }), !chunk.isEmpty {
            try Task.checkCancellation()
            totalRead += UInt64(chunk.count)
            buffer.append(chunk)
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 0x0A) {
                consumeLine(buffer[start..<newline])
                start = buffer.index(after: newline)
                // Keep the bytes ending at the last newline so a resumed read can confirm
                // the file still has the same prefix.
                let tailStart = max(buffer.startIndex, start - tailBytes)
                tail = Data(buffer[tailStart..<start])
            }
            if start != buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
            if buffer.count > maxLineBytes {
                if !skippingOversized {
                    summary.oversizedCount += 1
                    summary.complete = false
                }
                skippingOversized = true
                buffer.removeAll(keepingCapacity: true)
            }
        }

        let consumed: UInt64? = skippingOversized ? nil : startOffset + totalRead - UInt64(buffer.count)
        let resumable = summary
        if !buffer.isEmpty {
            if skippingOversized {
                summary.complete = false
            } else if buffer.count > maxLineBytes {
                summary.oversizedCount += 1
                summary.complete = false
            } else if !buffer.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) {
                // A record without its terminating newline may still be written by
                // the agent. Leave it for the next scan and never grant cleanup on it.
                summary.truncatedFinalRecord = true
                summary.complete = false
            }
        }
        if skippingOversized { summary.complete = false }
        return LineScan(summary: summary, resumableSummary: resumable, lineNumber: lineNumber,
                        consumedOffset: consumed, tail: tail)
    }

    // MARK: - Record parsing

    private struct PendingCall {
        var tool: String
        var recordedAt: Date
        var claims: [ToolClaimCandidate]
        var templates: [String] = []
        var completedAt: Date? = nil
        /// Set by a paired output or a Codex native `item_completed`; nil means
        /// the call never produced a trustworthy result and is not a claim.
        var success: Bool?
    }

    private struct LogAccumulator {
        let provider: AgentLogProvider
        let logPath: String
        let home: URL
        let fileModified: Date

        var sessionID: String?
        var projectRoot: String?
        var observedProjectRoots: [String] = []
        var startedAt: Date?
        var lastActivity: Date
        var pending: [String: PendingCall] = [:]
        var nativeResults: [String: Bool] = [:]
        var claims: [AgentArtifactClaim] = []
        var issues: [String] = []
        var complete = true

        private var observedProjectRootSet = Set<String>()
        private var seenIssueKeys = Set<String>()
        private let fractionalFormatter: ISO8601DateFormatter
        private let plainFormatter: ISO8601DateFormatter

        init(provider: AgentLogProvider, logPath: String, home: URL, fileModified: Date) {
            self.provider = provider
            self.logPath = logPath
            self.home = home
            self.fileModified = fileModified
            self.lastActivity = fileModified
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            self.fractionalFormatter = fractional
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            self.plainFormatter = plain
        }

        mutating func ingest(_ data: Data, lineNumber: Int) -> Bool {
            guard let raw = try? JSONSerialization.jsonObject(with: data),
                  let object = raw as? [String: Any] else { return false }

            let date = recordDate(object)
            if date > lastActivity { lastActivity = date }
            if startedAt == nil { startedAt = date }
            discoverHeader(object, date: date)

            switch provider {
            case .codex: ingestCodex(object, date: date)
            case .claude: ingestClaude(object, date: date)
            case .omp, .pi: ingestOmp(object, date: date)
            }
            return true
        }

        // MARK: Dates

        private func recordDate(_ object: [String: Any]) -> Date {
            if let value = Self.timestampValue(object) {
                return date(from: value) ?? lastActivity
            }
            return lastActivity
        }

        private func date(from value: Any) -> Date? {
            if let string = value as? String {
                if let date = fractionalFormatter.date(from: string) ?? plainFormatter.date(from: string) {
                    return date
                }
                return nil
            }
            if let number = value as? NSNumber,
               CFGetTypeID(number) != CFBooleanGetTypeID() {
                let seconds = number.doubleValue
                if seconds > 100_000_000_000 { return Date(timeIntervalSince1970: seconds / 1000) }
                if seconds > 1 { return Date(timeIntervalSince1970: seconds) }
            }
            return nil
        }

        private static func timestampValue(_ object: [String: Any]) -> Any? {
            for key in ["timestamp", "time", "createdAt", "created_at", "date", "at"] {
                if let value = object[key] { return value }
            }
            if let payload = object["payload"] as? [String: Any] {
                for key in ["timestamp", "time", "createdAt", "created_at"] {
                    if let value = payload[key] { return value }
                }
            }
            if let message = object["message"] as? [String: Any] {
                for key in ["timestamp", "time", "createdAt", "created_at"] {
                    if let value = message[key] { return value }
                }
            }
            return nil
        }

        // MARK: Session identity and lifetime

        private mutating func observeProjectRoot(_ value: String?) {
            guard let value, !value.isEmpty else { return }
            projectRoot = value
            if observedProjectRootSet.insert(value).inserted {
                observedProjectRoots.append(value)
            }
        }

        private mutating func discoverHeader(_ object: [String: Any], date: Date) {
            let type = string(object["type"])

            if let value = string(object["sessionId"]) ?? string(object["session_id"]) {
                sessionID = value
            }

            switch provider {
            case .codex:
                guard type == "session_meta" || type == "turn_context",
                      let payload = object["payload"] as? [String: Any] else { return }
                if type == "session_meta", sessionID == nil {
                    // A forked rollout replays the parent's session_meta after its
                    // own. Only the first record names this file.
                    sessionID = string(payload["id"]) ?? string(payload["session_id"])
                }
                observeProjectRoot(string(payload["cwd"]))
            case .claude:
                // A relocated record changes the cwd for subsequent relative paths.
                if type == "relocated" {
                    observeProjectRoot(string(object["relocatedCwd"]))
                }
                observeProjectRoot(string(object["cwd"]))
            case .omp, .pi:
                if let type, ["session", "session_meta", "session_start"].contains(type) {
                    if sessionID == nil {
                        sessionID = string(object["id"]) ?? string(object["sessionId"])
                            ?? string(object["session_id"])
                    }
                }
                observeProjectRoot(string(object["cwd"]) ?? string(object["workingDirectory"])
                    ?? string(object["projectRoot"]))
            }
            if startedAt == nil { startedAt = date }
        }

        // MARK: Codex

        private mutating func ingestCodex(_ object: [String: Any], date: Date) {
            guard let type = string(object["type"]) else { return }
            switch type {
            case "event_msg":
                guard let payload = object["payload"] as? [String: Any] else { return }
                if string(payload["type"]) == "item_completed",
                   let item = payload["item"] as? [String: Any],
                   let id = string(item["id"]) ?? string(item["call_id"]) {
                    let status = string(item["status"])
                    let exitCode = ToolExtractor.intValue(item["exit_code"])
                    nativeResults[id] = status != "failed" && status != "error" && (exitCode == nil || exitCode == 0)
                    if var call = pending[id] { call.completedAt = date; pending[id] = call }
                }
            case "response_item":
                guard let payload = object["payload"] as? [String: Any] else { return }
                ingestCodexResponseItem(payload, date: date)
            default:
                break
            }
        }

        private mutating func ingestCodexResponseItem(_ payload: [String: Any], date: Date) {
            guard let type = string(payload["type"]) else { return }
            switch type {
            case "function_call", "custom_tool_call":
                guard let callID = string(payload["call_id"]) ?? string(payload["id"]),
                      let name = string(payload["name"]) else { return }
                let raw: Any?
                if type == "custom_tool_call" {
                    raw = payload["input"] ?? payload["arguments"]
                } else {
                    raw = payload["arguments"]
                }
                let extraction = ToolExtractor(provider: provider, home: home, defaultCWD: projectRoot)
                    .extract(name: name, arguments: raw, rawInput: raw, at: date)
                note(extraction.issues)
                guard pending[callID] == nil else { return }
                pending[callID] = PendingCall(tool: extraction.tool, recordedAt: date,
                    claims: extraction.claims, templates: extraction.templates)
            case "function_call_output", "custom_tool_call_output":
                guard let callID = string(payload["call_id"]), var call = pending[callID] else { return }
                call.success = ToolExtractor.outputSucceeded(payload["output"])
                call.completedAt = date
                if call.success == true {
                    call.claims += ToolExtractor.resultClaims(payload["output"], templates: call.templates, tool: call.tool)
                }
                pending[callID] = call
            default:
                break
            }
        }

        // MARK: Claude

        private mutating func ingestClaude(_ object: [String: Any], date: Date) {
            guard let type = string(object["type"]),
                  let message = object["message"] as? [String: Any] else { return }
            let items = Self.contentItems(message["content"])

            switch type {
            case "assistant":
                for item in items where string(item["type"]) == "tool_use" {
                    guard let callID = string(item["id"]),
                          let name = string(item["name"]) else { continue }
                    let input = item["input"]
                    let extraction = ToolExtractor(provider: provider, home: home, defaultCWD: projectRoot)
                        .extract(name: name, arguments: input, rawInput: input, at: date)
                    note(extraction.issues)
                    pending[callID] = PendingCall(tool: extraction.tool, recordedAt: date,
                        claims: extraction.claims, templates: extraction.templates)
                }
            case "user":
                for item in items where string(item["type"]) == "tool_result" || item["tool_use_id"] != nil {
                    guard let callID = string(item["tool_use_id"]),
                          var call = pending.removeValue(forKey: callID) else { continue }
                    if bool(item["is_error"]) != true {
                        call.completedAt = date
                        call.claims += ToolExtractor.resultClaims(item["content"], templates: call.templates, tool: call.tool)
                        appendClaims(call)
                    }
                }
            default:
                break
            }
        }

        private static func contentItems(_ value: Any?) -> [[String: Any]] {
            if let array = value as? [Any] {
                return array.compactMap { $0 as? [String: Any] }
            }
            if let dictionary = value as? [String: Any] {
                return [dictionary]
            }
            return []
        }

        // MARK: omp / pi

        private mutating func ingestOmp(_ object: [String: Any], date: Date) {

            if let message = object["message"] as? [String: Any] {
                ingestOmpMessage(message, date: date)
                return
            }
            if let type = string(object["type"]),
               type == "toolCall" || type == "tool_call" || type == "toolResult" || type == "tool_result" {
                ingestOmpMessage(object, date: date)
            }
        }

        private mutating func ingestOmpMessage(_ message: [String: Any], date: Date) {
            let role = (string(message["role"]) ?? "").lowercased()
            let type = (string(message["type"]) ?? "").lowercased()
            let isToolResult = role == "toolresult" || role == "tool_result" || role == "tool"
                || type == "toolresult" || type == "tool_result"

            if isToolResult {
                guard let callID = string(message["toolCallId"])
                    ?? string(message["tool_call_id"])
                    ?? string(message["id"]),
                      var call = pending.removeValue(forKey: callID) else { return }
                if ToolExtractor.ompResultSucceeded(message) {
                    call.completedAt = date
                    call.claims += ToolExtractor.resultClaims(message["content"], templates: call.templates, tool: call.tool)
                    appendClaims(call)
                }
                return
            }

            var callItems: [[String: Any]] = []
            for item in Self.contentItems(message["content"]) {
                let itemType = (string(item["type"]) ?? "").lowercased()
                if itemType == "toolcall" || itemType == "tool_call" || itemType == "tooluse" {
                    callItems.append(item)
                }
            }
            if let calls = message["toolCalls"] as? [Any] {
                callItems.append(contentsOf: calls.compactMap { $0 as? [String: Any] })
            }
            if type == "toolcall" || type == "tool_call" {
                callItems.append(message)
            }

            for item in callItems {
                guard let callID = string(item["id"]) ?? string(item["toolCallId"]),
                      let name = string(item["name"]) ?? string(item["toolName"]) else { continue }
                let raw = item["arguments"] ?? item["input"] ?? item["args"]
                let extraction = ToolExtractor(provider: provider, home: home, defaultCWD: projectRoot)
                    .extract(name: name, arguments: raw, rawInput: raw, at: date)
                note(extraction.issues)
                pending[callID] = PendingCall(tool: extraction.tool, recordedAt: date,
                    claims: extraction.claims, templates: extraction.templates)
            }
        }

        // MARK: Shared helpers

        private func string(_ value: Any?) -> String? { value as? String }
        private func bool(_ value: Any?) -> Bool? { ToolExtractor.boolValue(value) }

        private mutating func appendClaims(_ call: PendingCall) {
            for candidate in call.claims {
                claims.append(AgentArtifactClaim(
                    path: candidate.path,
                    tool: candidate.tool,
                    recordedAt: call.recordedAt,
                    succeeded: true,
                    creationEvidence: candidate.creationEvidence,
                    completedAt: call.completedAt
                ))
            }
        }

        /// Emits Codex claims only after all records, including native
        /// `item_completed` overrides, have been seen.
        mutating func finalClaims() -> [AgentArtifactClaim] {
            guard provider == .codex else { return claims }
            for (callID, call) in pending {
                let success = nativeResults[callID] ?? call.success
                guard success == true else { continue }
                for candidate in call.claims {
                    claims.append(AgentArtifactClaim(
                        path: candidate.path,
                        tool: candidate.tool,
                        recordedAt: call.recordedAt,
                        succeeded: true,
                        creationEvidence: candidate.creationEvidence,
                        completedAt: call.completedAt
                    ))
                }
            }
            return claims
        }

        private mutating func note(_ values: [String]) {
            for value in values {
                if seenIssueKeys.insert(value).inserted {
                    issues.append(value)
                }
            }
        }

    }
}

// MARK: - Tool extraction

struct ToolClaimCandidate: Sendable {
    var path: String
    var tool: String
    /// True only when the invocation itself can create the path. Edits identify an
    /// existing artifact but never establish creation.
    var creationEvidence: Bool = true
}

struct ToolExtraction: Sendable {
    var tool = ""
    var claims: [ToolClaimCandidate] = []
    var templates: [String] = []
    var issues: [String] = []
}

/// Converts structured tool arguments into literal paths. It never evaluates code:
/// JavaScript shell wrappers are scanned only for literal string arguments, and any
/// dynamic template or substitution is skipped with a visible issue.
struct ToolExtractor {
    let provider: AgentLogProvider
    let home: URL
    let defaultCWD: String?

    func extract(name rawName: String, arguments: Any?, rawInput: Any?, at date: Date) -> ToolExtraction {
        var result = ToolExtraction(tool: rawName)
        let lower = rawName.lowercased()

        if lower.contains("multi_tool_use") || lower == "parallel" {
            return extractParallel(arguments, date: date)
        }

        let name = Self.normalizedToolName(rawName)
        let decoded = Self.decodeJSON(arguments ?? rawInput)
        result.tool = name

        if Self.editTools.contains(name) {
            guard let dictionary = decoded as? [String: Any] else { return result }
            if Self.string(dictionary["command"]) == "view" { return result }
            for key in ["file_path", "path", "filePath", "target_file", "file"] {
                if let path = Self.string(dictionary[key]),
                   let normalized = Self.normalize(path: path, cwd: defaultCWD, home: home) {
                    result.claims.append(ToolClaimCandidate(path: normalized, tool: name,
                        creationEvidence: Self.string(dictionary["command"]) == "create"))
                }
            }
            if let input = Self.string(dictionary["input"]) {
                for line in input.split(separator: "\n") {
                    guard line.hasPrefix("["), line.hasSuffix("]"), let hash = line.lastIndex(of: "#") else { continue }
                    let tag = line[line.index(after: hash)..<line.index(before: line.endIndex)]
                    guard tag.count == 4, tag.allSatisfy({ $0.isHexDigit }) else { continue }
                    let path = String(line[line.index(after: line.startIndex)..<hash])
                    if let normalized = Self.normalize(path: path, cwd: defaultCWD, home: home) {
                        result.claims.append(ToolClaimCandidate(path: normalized, tool: name, creationEvidence: false))
                    }
                }
            }
            return result
        }

        if Self.writeTools.contains(name) {
            guard let dictionary = decoded as? [String: Any] else { return result }
            for key in ["file_path", "path", "filePath", "filename", "target_file", "targetPath", "file"] {
                if let path = dictionary[key] as? String,
                   let normalized = Self.normalize(path: path, cwd: defaultCWD, home: home) {
                    result.claims.append(ToolClaimCandidate(path: normalized, tool: name))
                    return result
                }
            }
            return result
        }

        if name.contains("apply_patch") || name.contains("applypatch") {
            let patch: String?
            if let dictionary = decoded as? [String: Any] {
                patch = Self.string(dictionary["input"]) ?? Self.string(dictionary["patch"])
                    ?? Self.string(dictionary["text"])
            } else if let text = rawInput as? String {
                patch = text
            } else if let text = arguments as? String {
                patch = text
            } else {
                patch = nil
            }
            if let patch {
                for (path, creates) in Self.patchFiles(in: patch) {
                    if let normalized = Self.normalize(path: path, cwd: defaultCWD, home: home) {
                        result.claims.append(ToolClaimCandidate(path: normalized, tool: name, creationEvidence: creates))
                    }
                }
            }
            return result
        }

        if name == "exec" || name == "codex_exec" {
            let raw = rawInput ?? arguments
            if let dictionary = decoded as? [String: Any],
               let command = Self.string(dictionary["cmd"]) ?? Self.string(dictionary["command"]) {
                let cwd = Self.string(dictionary["workdir"]) ?? Self.string(dictionary["cwd"]) ?? defaultCWD
                appendShell(command: command, cwd: cwd, tool: name, to: &result)
                return result
            }
            if let source = raw as? String {
                let scanned = Self.literalJavaScriptCommands(in: source)
                for command in scanned.commands {
                    appendShell(command: command, cwd: defaultCWD, tool: name, to: &result)
                }
                if scanned.dynamic {
                    result.issues.append("Skipped a dynamic JavaScript shell template in \(rawName).")
                }
                if scanned.commands.isEmpty && !scanned.dynamic && !source.isEmpty {
                    result.issues.append("Skipped an unrecognized JavaScript wrapper in \(rawName).")
                }
            }
            return result
        }

        if Self.shellTools.contains(name) {
            guard let dictionary = decoded as? [String: Any] else {
                if let command = decoded as? String {
                    appendShell(command: command, cwd: defaultCWD, tool: name, to: &result)
                }
                return result
            }
            let cwd = Self.string(dictionary["workdir"]) ?? Self.string(dictionary["cwd"])
                ?? Self.string(dictionary["directory"]) ?? defaultCWD
            if let command = Self.string(dictionary["command"]) {
                appendShell(command: command, cwd: cwd, tool: name, to: &result)
            } else if let command = Self.string(dictionary["cmd"]) {
                appendShell(command: command, cwd: cwd, tool: name, to: &result)
            } else if let command = Self.string(dictionary["script"]) {
                appendShell(command: command, cwd: cwd, tool: name, to: &result)
            } else if let list = dictionary["command"] as? [String] {
                if let script = Self.shellScript(fromArgumentVector: list) {
                    appendShell(command: script, cwd: cwd, tool: name, to: &result)
                }
            }
            return result
        }

        return result
    }

    private func extractParallel(_ arguments: Any?, date: Date) -> ToolExtraction {
        var result = ToolExtraction(tool: "multi_tool_use.parallel")
        let decoded = Self.decodeJSON(arguments)
        guard let dictionary = decoded as? [String: Any] else { return result }
        let uses = (dictionary["tool_uses"] as? [Any])
            ?? (dictionary["toolUses"] as? [Any])
            ?? (dictionary["calls"] as? [Any])
        guard let uses else { return result }
        for use in uses {
            guard let item = use as? [String: Any] else { continue }
            let name = Self.string(item["recipient_name"]) ?? Self.string(item["name"])
                ?? Self.string(item["tool"]) ?? Self.string(item["toolName"])
            guard let name else { continue }
            let parameters = item["parameters"] ?? item["arguments"] ?? item["input"] ?? item["args"]
            let nested = extract(name: name, arguments: parameters, rawInput: parameters, at: date)
            result.claims.append(contentsOf: nested.claims.map {
                ToolClaimCandidate(path: $0.path, tool: $0.tool, creationEvidence: false)
            })
            result.issues.append(contentsOf: nested.issues)
            if !nested.claims.isEmpty { result.tool = nested.tool }
        }
        return result
    }

    private func appendShell(command: String, cwd: String?, tool: String, to result: inout ToolExtraction) {
        let scan = ShellCreationScanner.scan(command: command, cwd: cwd, home: home)
        for path in scan.paths {
            if let normalized = Self.normalize(path: path, cwd: cwd, home: home) {
                result.claims.append(ToolClaimCandidate(path: normalized, tool: tool))
            }
        }
        result.templates.append(contentsOf: scan.templates)
        result.issues.append(contentsOf: scan.issues)
    }

    // MARK: Results

    /// Only mktemp's paired stdout can resolve its random suffix. Other output
    /// text is never searched for arbitrary filesystem references.
    static func resultClaims(_ output: Any?, templates: [String], tool: String) -> [ToolClaimCandidate] {
        guard !templates.isEmpty else { return [] }
        func texts(_ value: Any?) -> [String] {
            if let string = value as? String { return [string] }
            if let array = value as? [Any] { return array.flatMap { texts($0) } }
            if let object = value as? [String: Any] {
                return texts(object["text"] ?? object["content"] ?? object["output"])
            }
            return []
        }
        let patterns = templates.compactMap { template -> NSRegularExpression? in
            let escaped = NSRegularExpression.escapedPattern(for: template)
            let pattern = escaped.replacingOccurrences(of: #"X{3,}"#, with: "[A-Za-z0-9]+", options: .regularExpression)
            return try? NSRegularExpression(pattern: "^" + pattern + "$")
        }
        var paths = Set<String>()
        for text in texts(output) {
            for line in text.split(separator: "\n") {
                let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard path.hasPrefix("/"), path.utf8.count <= 4096 else { continue }
                let range = NSRange(path.startIndex..., in: path)
                if patterns.contains(where: { $0.firstMatch(in: path, range: range) != nil }) { paths.insert(path) }
            }
        }
        return paths.sorted().map { ToolClaimCandidate(path: $0, tool: tool) }
    }

    /// Output may be a string, a dictionary, or a list of content blocks. Absence of
    /// output is not success; a present result is success unless it reports failure.
    static func outputSucceeded(_ output: Any?) -> Bool {
        guard let output else { return false }
        return succeededValue(output)
    }

    private static func succeededValue(_ value: Any) -> Bool {
        if value is NSNull { return false }
        if let string = value as? String { return succeededString(string) }
        if let dictionary = value as? [String: Any] {
            if boolValue(dictionary["success"]) == false { return false }
            if boolValue(dictionary["is_error"]) == true || boolValue(dictionary["isError"]) == true {
                return false
            }
            // Codex shell results nest the status: {"output": "...", "metadata": {"exit_code": 1}}.
            for container in [dictionary, dictionary["metadata"] as? [String: Any] ?? [:]] {
                for key in ["exit_code", "exitCode", "status_code", "statusCode"] {
                    if let code = intValue(container[key]), code != 0 { return false }
                }
            }
            for key in ["error", "failure"] {
                if let error = dictionary[key], !(error is NSNull) {
                    if let text = error as? String, text.isEmpty { continue }
                    return false
                }
            }
            if let content = dictionary["content"] { return succeededValue(content) }
            if let output = dictionary["output"] { return succeededValue(output) }
            if let text = dictionary["text"] as? String { return succeededString(text) }
            return true
        }
        if let array = value as? [Any] {
            guard !array.isEmpty else { return false }
            var sawSuccess = false
            for element in array {
                if let dictionary = element as? [String: Any] {
                    if boolValue(dictionary["is_error"]) == true || boolValue(dictionary["isError"]) == true {
                        return false
                    }
                    if let type = dictionary["type"] as? String, type == "input_text" || type == "text",
                       let text = dictionary["text"] as? String {
                        if succeededString(text) { sawSuccess = true }
                        else if stringReportsFailure(text) { return false }
                    }
                } else if let text = element as? String {
                    if stringReportsFailure(text) { return false }
                    if text.contains("Script completed") { sawSuccess = true }
                }
            }
            return sawSuccess || !array.isEmpty
        }
        if let number = value as? NSNumber {
            return number.intValue == 0
        }
        return true
    }

    private static func succeededString(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if stringReportsFailure(trimmed) { return false }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
           let data = trimmed.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) {
            return succeededValue(decoded)
        }
        return true
    }

    private static func stringReportsFailure(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.hasPrefix("error:") || lowered.hasPrefix("failed:") { return true }
        if lowered.contains("script failed") { return true }
        if lowered.contains("\"success\":false") || lowered.contains("\"is_error\":true")
            || lowered.contains("\"iserror\":true") {
            return true
        }
        // "Process exited with code 2", "exit status 1", "exit code: 1"
        let patterns = [
            #"(?:process\s+exited\s+with\s+code|exit\s+status|exit\s+code)\s*[:=]?\s*([1-9][0-9]*)"#,
            #"command\s+failed\s+with\s+exit\s+code\s*[:=]?\s*([1-9][0-9]*)"#,
        ]
        for pattern in patterns {
            if lowered.range(of: pattern, options: .regularExpression) != nil { return true }
        }
        return false
    }

    static func ompResultSucceeded(_ message: [String: Any]) -> Bool {
        if boolValue(message["isError"]) == true { return false }
        if boolValue(message["is_error"]) == true { return false }
        if let details = message["details"] as? [String: Any] {
            if boolValue(details["isError"]) == true || boolValue(details["is_error"]) == true {
                return false
            }
            for key in ["exitCode", "exit_code", "statusCode"] {
                if let code = intValue(details[key]), code != 0 { return false }
            }
            for key in ["error", "failure"] {
                if let error = details[key], !(error is NSNull) {
                    if let text = error as? String, text.isEmpty { continue }
                    return false
                }
            }
        }
        return true
    }

    // MARK: Tool classification

    private static let writeTools: Set<String> = [
        "write", "write_file", "writefile", "create_file", "createfile", "file_write",
    ]

    private static let editTools: Set<String> = [
        "edit", "edit_file", "multiedit", "multi_edit", "str_replace_editor", "str_replace",
    ]

    private static let shellTools: Set<String> = [
        "bash", "shell", "exec_command", "run_command", "run_shell_command",
        "terminal", "local_shell", "container_exec",
    ]

    private static func normalizedToolName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let index = name.lastIndex(where: { $0 == "." || $0 == "/" }),
           name.index(after: index) < name.endIndex {
            name = String(name[name.index(after: index)...])
        }
        return name
    }

    // MARK: Argument decoding

    private static func decodeJSON(_ value: Any?) -> Any? {
        guard let value else { return nil }
        if let dictionary = value as? [String: Any] { return dictionary }
        if let array = value as? [Any] { return array }
        guard let string = value as? String else { return value }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return string }
        guard let data = trimmed.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) else { return string }
        return decoded
    }

    private static func shellScript(fromArgumentVector vector: [String]) -> String? {
        let flags = ["-c", "-lc", "-ic", "-cl", "-ec"]
        for (index, item) in vector.enumerated() where flags.contains(item) {
            if index + 1 < vector.count { return vector[index + 1] }
        }
        if vector.count == 1 { return vector[0] }
        return nil
    }

    static func patchFiles(in patch: String) -> [(String, Bool)] {
        var paths: [(String, Bool)] = []
        for line in patch.split(separator: "\n") {
            for (prefix, creates) in [("*** Add File:", true), ("*** Update File:", false), ("*** Move to:", false)] {
                guard line.hasPrefix(prefix) else { continue }
                let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty { paths.append((path, creates)) }
            }
        }
        return paths
    }

    // MARK: JavaScript literal shell extraction

    struct JavaScriptScan {
        var commands: [String] = []
        var dynamic = false
    }

    /// Finds literal `cmd`/`command` arguments inside `exec_command({...})` calls.
    /// No JavaScript is evaluated and no expression is resolved.
    static func literalJavaScriptCommands(in source: String) -> JavaScriptScan {
        var scan = JavaScriptScan()
        let characters = Array(source)
        var index = 0
        let needle = Array("exec_command")

        while index < characters.count {
            guard matches(characters, at: index, needle: needle) else {
                index += 1
                continue
            }
            let previous = index > 0 ? characters[index - 1] : " "
            if previous.isLetter || previous.isNumber || previous == "_" {
                index += needle.count
                continue
            }
            var cursor = index + needle.count
            skipWhitespace(characters, &cursor)
            guard cursor < characters.count, characters[cursor] == "(" else {
                index += needle.count
                continue
            }
            cursor += 1
            skipWhitespace(characters, &cursor)
            if cursor < characters.count, characters[cursor] == "{" {
                if let string = firstStringProperty(named: ["cmd", "command"],
                                                    inObjectAt: cursor, characters: characters) {
                    if string.dynamic {
                        scan.dynamic = true
                    } else if let command = string.value {
                        scan.commands.append(command)
                    }
                } else {
                    scan.dynamic = true
                }
            } else {
                scan.dynamic = true
            }
            index = cursor
        }
        return scan
    }

    private static func matches(_ characters: [Character], at index: Int, needle: [Character]) -> Bool {
        guard index + needle.count <= characters.count else { return false }
        for offset in 0..<needle.count where characters[index + offset] != needle[offset] {
            return false
        }
        return true
    }

    private static func skipWhitespace(_ characters: [Character], _ index: inout Int) {
        while index < characters.count, characters[index].isWhitespace { index += 1 }
    }

    private struct LiteralString {
        var value: String?
        var dynamic: Bool
    }

    private static func firstStringProperty(named names: [String], inObjectAt start: Int,
                                            characters: [Character]) -> LiteralString? {
        var index = start + 1
        var depth = 1
        while index < characters.count && depth > 0 {
            let character = characters[index]
            if character == "{" { depth += 1; index += 1; continue }
            if character == "}" { depth -= 1; index += 1; continue }
            if depth != 1 { index += 1; continue }
            if character == "'" || character == "\"" || character == "`" {
                // Skip a string value so property-like text inside it is not matched.
                _ = parseString(characters, index: &index)
                continue
            }
            for name in names {
                let needle = Array(name)
                if matches(characters, at: index, needle: needle) {
                    let before = index > 0 ? characters[index - 1] : " "
                    if before.isLetter || before.isNumber || before == "_" {
                        continue
                    }
                    var cursor = index + needle.count
                    skipWhitespace(characters, &cursor)
                    guard cursor < characters.count, characters[cursor] == ":" else { continue }
                    cursor += 1
                    skipWhitespace(characters, &cursor)
                    guard cursor < characters.count else { continue }
                    if characters[cursor] == "'" || characters[cursor] == "\""
                        || characters[cursor] == "`" {
                        return parseString(characters, index: &cursor)
                    }
                    return LiteralString(value: nil, dynamic: true)
                }
            }
            index += 1
        }
        return nil
    }

    private static func parseString(_ characters: [Character], index: inout Int) -> LiteralString {
        guard index < characters.count else { return LiteralString(value: nil, dynamic: true) }
        let quote = characters[index]
        index += 1
        var value = ""
        while index < characters.count {
            let character = characters[index]
            if character == quote {
                index += 1
                return LiteralString(value: value, dynamic: false)
            }
            if quote == "`", character == "$", index + 1 < characters.count,
               characters[index + 1] == "{" {
                return LiteralString(value: nil, dynamic: true)
            }
            if character == "\\" {
                index += 1
                guard index < characters.count else {
                    return LiteralString(value: nil, dynamic: true)
                }
                let escaped = characters[index]
                switch escaped {
                case "n": value.append("\n")
                case "r": value.append("\r")
                case "t": value.append("\t")
                case "b": value.append("\u{08}")
                case "f": value.append("\u{0C}")
                case "v": value.append("\u{0B}")
                case "0": value.append("\0")
                case "\\", "'", "\"", "`": value.append(escaped)
                case "x":
                    var hex = ""
                    var cursor = index + 1
                    while cursor < characters.count, hex.count < 2,
                          characters[cursor].isHexDigit {
                        hex.append(characters[cursor])
                        cursor += 1
                    }
                    if let scalar = UInt32(hex, radix: 16), let unicode = UnicodeScalar(scalar) {
                        value.append(Character(unicode))
                        index = cursor - 1
                    } else {
                        return LiteralString(value: nil, dynamic: true)
                    }
                case "u":
                    var hex = ""
                    var cursor = index + 1
                    while cursor < characters.count, hex.count < 4,
                          characters[cursor].isHexDigit {
                        hex.append(characters[cursor])
                        cursor += 1
                    }
                    if let scalar = UInt32(hex, radix: 16), let unicode = UnicodeScalar(scalar) {
                        value.append(Character(unicode))
                        index = cursor - 1
                    } else {
                        return LiteralString(value: nil, dynamic: true)
                    }
                case "\n":
                    break // line continuation
                default:
                    value.append(escaped)
                }
                index += 1
                continue
            }
            if character == "\n" || character == "\r" {
                return LiteralString(value: nil, dynamic: true)
            }
            value.append(character)
            index += 1
        }
        return LiteralString(value: nil, dynamic: true)
    }

    // MARK: Path normalization

    static func normalize(path raw: String, cwd: String?, home: URL) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\0"), !value.contains("://") else { return nil }
        if value == "/dev/null" || value == "/dev/stdout" || value == "/dev/stderr"
            || value == "/dev/tty" { return nil }

        if value == "~" {
            value = home.path
        } else if value.hasPrefix("~/") {
            value = home.path + String(value.dropFirst(1))
        } else if value.hasPrefix("~") {
            return nil
        }

        let url: URL
        if value.hasPrefix("/") {
            url = URL(fileURLWithPath: value)
        } else {
            // A relative or missing working directory is unknown. It must never
            // resolve against Sidewatch's own process directory.
            guard let cwd, let base = normalize(path: cwd, cwd: nil, home: home) else { return nil }
            url = URL(fileURLWithPath: value,
                      relativeTo: URL(fileURLWithPath: base, isDirectory: true))
        }
        var path = url.standardizedFileURL.path
        guard path.hasPrefix("/") else { return nil }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: Small JSON helpers

    static func string(_ value: Any?) -> String? {
        value as? String
    }

    static func boolValue(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber else {
            return value as? Bool
        }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        return nil
    }

    static func intValue(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }
}

// MARK: - Conservative shell creation scanner

/// Extracts literal creation operands from a shell command without a shell. It
/// understands quoting, simple redirections, `mkdir`, `mktemp`, and `touch`; it
/// retains heredoc header outputs while excluding their bodies. Substitutions
/// and other dynamic constructs are reported instead of evaluated.
enum ShellCreationScanner {
    struct Result {
        var paths: [String] = []
        var templates: [String] = []
        var issues: [String] = []
    }

    private enum Separator {
        /// `;` or a newline.
        case sequence
        case and
        case or
        /// `|` or `|&`: each segment starts at the pipeline's working directory.
        case pipe
        /// `&`: the preceding and-or list runs asynchronously in a subshell.
        case background
        case openSubshell
        case closeSubshell
    }

    private enum Token {
        case word(String, dynamic: Bool)
        case redirect
        case ignoreRedirect
        case separator(Separator)
    }

    static func scan(command: String, cwd: String?, home: URL) -> Result {
        var result = Result()
        guard let command = removingHeredocBodies(command), !containsUnsafeConstruct(command) else {
            result.issues.append("Skipped dynamic shell code or an unfinished heredoc.")
            return result
        }
        var tokens: [Token] = []
        var index = 0
        let characters = Array(command)
        let count = characters.count

        while index < count {
            let character = characters[index]
            if character == " " || character == "\t" || character == "\r" {
                index += 1
                continue
            }
            if character == "\n" || character == ";" {
                tokens.append(.separator(.sequence))
                index += 1
                continue
            }
            if character == "&" {
                if index + 1 < count, characters[index + 1] == "&" {
                    tokens.append(.separator(.and))
                    index += 2
                    continue
                }
                if index + 1 < count, characters[index + 1] == ">" {
                    tokens.append(.redirect)
                    index += 2
                    if index < count, characters[index] == ">" { index += 1 }
                    continue
                }
                tokens.append(.separator(.background))
                index += 1
                continue
            }
            if character == "|" {
                if index + 1 < count, characters[index + 1] == "|" {
                    tokens.append(.separator(.or))
                    index += 2
                    continue
                }
                if index + 1 < count, characters[index + 1] == "&" { index += 1 }
                tokens.append(.separator(.pipe))
                index += 1
                continue
            }
            if character == "(" || character == ")" {
                tokens.append(.separator(character == "(" ? .openSubshell : .closeSubshell))
                index += 1
                continue
            }
            if character == ">" {
                index += 1
                if index < count, characters[index] == ">" { index += 1 }
                if index < count, characters[index] == "|" { index += 1 }
                if index < count, characters[index] == "&" {
                    index += 1
                    // `>&2`, `>& 2`, `>&2-`, and `>&-` duplicate or close a
                    // descriptor. Any other word (`>& file`) redirects both
                    // stdout and stderr to that file.
                    var lookahead = index
                    while lookahead < count, characters[lookahead] == " " || characters[lookahead] == "\t" {
                        lookahead += 1
                    }
                    var end = lookahead
                    while end < count, !" \t\r\n;|&()<>".contains(characters[end]) { end += 1 }
                    let word = String(characters[lookahead..<end])
                    let digits = word.hasSuffix("-") ? String(word.dropLast()) : word
                    if word == "-" || (!digits.isEmpty && digits.allSatisfy({ $0.isASCII && $0.isNumber })) {
                        index = end
                        continue
                    }
                }
                tokens.append(.redirect)
                continue
            }
            if character == "<" {
                index += 1
                if index < count, characters[index] == "<" { index += 1 }
                if index < count, characters[index] == "<" { index += 1 }
                tokens.append(.ignoreRedirect)
                continue
            }
            if character == "#" {
                while index < count, characters[index] != "\n" { index += 1 }
                continue
            }

            let wordStart = index
            var value = ""
            var dynamic = false
            var quoted = false
            var fdPrefix = false
            while index < count {
                let current = characters[index]
                if current == " " || current == "\t" || current == "\r"
                    || current == "\n" || current == ";" || current == "|"
                    || current == "&" || current == "(" || current == ")"
                    || current == "<" || current == ">" {
                    break
                }
                if current == "\\" {
                    index += 1
                    if index < count {
                        value.append(characters[index])
                        quoted = true
                        index += 1
                    }
                    continue
                }
                if current == "'" {
                    quoted = true
                    index += 1
                    while index < count, characters[index] != "'" {
                        value.append(characters[index])
                        index += 1
                    }
                    if index < count { index += 1 }
                    continue
                }
                if current == "\"" {
                    quoted = true
                    index += 1
                    while index < count, characters[index] != "\"" {
                        if characters[index] == "\\", index + 1 < count {
                            let escaped = characters[index + 1]
                            if escaped == "\"" || escaped == "\\" || escaped == "$" || escaped == "`" {
                                value.append(escaped)
                                index += 2
                                continue
                            }
                            value.append("\\")
                            index += 1
                            continue
                        }
                        if characters[index] == "$" || characters[index] == "`" {
                            dynamic = true
                        }
                        value.append(characters[index])
                        index += 1
                    }
                    if index < count { index += 1 }
                    continue
                }
                if current == "$" || current == "`" {
                    dynamic = true
                    value.append(current)
                    index += 1
                    continue
                }
                if current == "*" || current == "?" || current == "[" || current == "{" {
                    dynamic = true
                    value.append(current)
                    index += 1
                    continue
                }
                value.append(current)
                index += 1
            }

            if index < count, (characters[index] == ">" || characters[index] == "<"),
               !dynamic, !quoted, !value.isEmpty,
               value.allSatisfy({ $0.isNumber }) {
                fdPrefix = true
            }
            if fdPrefix {
                // The redirect follows immediately; the numeric token was a descriptor.
                continue
            }
            // An empty quoted word (`""`, `''`) is still an argument; it must not
            // end tokenization of the rest of the command.
            if !value.isEmpty || quoted {
                tokens.append(.word(value, dynamic: dynamic))
            }
            if index == wordStart {
                // Defensive: never loop on a character no branch consumed.
                index += 1
            }
        }

        process(tokens: tokens, cwd: cwd, home: home, result: &result)
        return result
    }

    /// Keeps literal redirects on the command line, excluding heredoc bodies.
    private static func removingHeredocBodies(_ source: String) -> String? {
        guard source.contains("<<") else { return source }
        let expression = try! NSRegularExpression(pattern: #"(?<!<)<<(-?)\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\2"#)
        var pending: [(String, Bool)] = []
        var output: [String] = []
        for raw in source.components(separatedBy: "\n") {
            if let (delimiter, stripTabs) = pending.first {
                let line = stripTabs ? String(raw.drop(while: { $0 == "\t" })) : raw
                if line == delimiter { pending.removeFirst() }
                continue
            }
            let matches = expression.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
            var header = raw
            for match in matches {
                guard let tokenRange = Range(match.range(at: 3), in: raw) else { return nil }
                pending.append((String(raw[tokenRange]), match.range(at: 1).length > 0))
            }
            for match in matches.reversed() {
                if let range = Range(match.range, in: header) { header.replaceSubrange(range, with: " ") }
            }
            output.append(header)
        }
        return pending.isEmpty ? output.joined(separator: "\n") : nil
    }

    private static func containsUnsafeConstruct(_ command: String) -> Bool {
        var singleQuoted = false
        var doubleQuoted = false
        let characters = Array(command)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                index += 2
                continue
            }
            if character == "'" && !doubleQuoted {
                singleQuoted.toggle()
                index += 1
                continue
            }
            if character == "\"" && !singleQuoted {
                doubleQuoted.toggle()
                index += 1
                continue
            }
            if !singleQuoted {
                if character == "`" { return true }
                if character == "$", index + 1 < characters.count, characters[index + 1] == "(" {
                    return true
                }
                if character == "<", index + 1 < characters.count, characters[index + 1] == "(" {
                    return true
                }
            }
            if character == "<", index + 1 < characters.count, characters[index + 1] == "<" {
                return true
            }
            index += 1
        }
        return false
    }

    /// Working-directory state for the shell structure around the current command.
    /// A nil directory is unknown: relative outputs are then reported, not guessed.
    private struct DirectoryScope {
        /// The directory at the start of the current and-or list.
        var list: String?
        /// The directory at the start of the current pipeline.
        var pipeline: String?
        var pipelineSegments = 1
        /// A `||` earlier in this and-or list makes a later `cd` conditional.
        var afterOr = false
        /// The directory in effect when this subshell opened.
        var entry: String?
    }

    private static func process(tokens: [Token], cwd rawCWD: String?, home: URL, result: inout Result) {
        let cwd = rawCWD.flatMap { ToolExtractor.normalize(path: $0, cwd: nil, home: home) }
        var current: [(String, Bool)] = []
        var redirects: [String] = []
        var currentCWD = cwd
        var scope = DirectoryScope(list: cwd, pipeline: cwd, entry: cwd)
        var subshells: [DirectoryScope] = []
        /// Depth inside if/while/until/for/case/select or a brace group. A `cd`
        /// there runs conditionally or repeatedly, so its result is unknown.
        var controlDepth = 0
        var index = 0

        func claim(_ target: String) {
            if currentCWD == nil && !target.hasPrefix("/") && !target.hasPrefix("~") {
                result.issues.append("Skipped a relative shell output without a known working directory.")
                return
            }
            if let path = ToolExtractor.normalize(path: target, cwd: currentCWD, home: home) {
                result.paths.append(path)
            }
        }

        func endPipeline() {
            // Every segment of a multi-command pipeline is a subshell in bash,
            // but zsh runs the last segment in the current shell. A cd in that
            // segment therefore leaves the directory unknown.
            if scope.pipelineSegments > 1 && currentCWD != scope.pipeline {
                currentCWD = nil
            }
            scope.pipelineSegments = 1
        }

        func flush() {
            defer {
                current.removeAll(keepingCapacity: true)
                redirects.removeAll(keepingCapacity: true)
            }
            for target in redirects where !isDevice(target) {
                claim(target)
            }

            // Reserved words precede the command they introduce.
            var start = 0
            keywords: while start < current.count {
                switch current[start].0 {
                case "if", "while", "until", "{":
                    controlDepth += 1
                case "then", "do", "else", "elif", "!":
                    break
                case "fi", "done", "esac", "}":
                    controlDepth = max(0, controlDepth - 1)
                case "for", "case", "select":
                    // The remaining words are loop or case operands, not a command.
                    controlDepth += 1
                    return
                default:
                    break keywords
                }
                start += 1
            }
            let words = Array(current[start...])

            guard let position = commandIndex(words) else { return }
            let name = (words[position].0 as NSString).lastPathComponent.lowercased()
            let arguments = Array(words.dropFirst(position + 1))

            if name == "cd" || name == "pushd" || name == "popd" {
                guard name == "cd", controlDepth == 0, !scope.afterOr,
                      arguments.count == 1, !arguments[0].1, arguments[0].0 != "-" else {
                    currentCWD = nil
                    return
                }
                let raw = arguments[0].0
                if currentCWD == nil && !raw.hasPrefix("/") && !raw.hasPrefix("~") { return }
                currentCWD = ToolExtractor.normalize(path: raw, cwd: currentCWD, home: home)
                return
            }

            if name == "mkdir" {
                for path in operands(arguments, optionsWithValues: ["-m"]) { claim(path) }
                return
            }
            if name == "touch" {
                for path in operands(arguments, optionsWithValues: []) { claim(path) }
                return
            }
            if name == "mktemp" {
                var template: String?
                var directory: String?
                var usesTemplateFlag = false
                var index = 0
                while index < arguments.count {
                    let (argument, dynamic) = arguments[index]
                    if argument == "--" { index += 1; continue }
                    if argument.hasPrefix("--tmpdir") {
                        if argument.hasPrefix("--tmpdir=") {
                            directory = String(argument.dropFirst("--tmpdir=".count))
                        }
                        usesTemplateFlag = true
                        index += 1
                        continue
                    }
                    if argument == "-p" {
                        if index + 1 < arguments.count { directory = arguments[index + 1].0 }
                        index += 2
                        continue
                    }
                    if argument == "-t" { usesTemplateFlag = true; index += 1; continue }
                    if argument == "-d" || argument == "-q" || argument == "-u" {
                        index += 1
                        continue
                    }
                    if argument.hasPrefix("-") { index += 1; continue }
                    if !dynamic { template = argument }
                    index += 1
                }
                let rawTemplate: String
                if usesTemplateFlag {
                    rawTemplate = (directory ?? FileManager.default.temporaryDirectory.path) + "/" + (template ?? "tmp") + ".XXXXXXXXXX"
                } else if let template {
                    rawTemplate = template.hasPrefix("/") ? template : (directory.map { $0 + "/" + template } ?? template)
                } else {
                    rawTemplate = FileManager.default.temporaryDirectory.appendingPathComponent("tmp.XXXXXXXXXX").path
                }
                if let normalized = ToolExtractor.normalize(path: rawTemplate, cwd: currentCWD, home: home) {
                    result.templates.append(normalized)
                }
                return
            }
            if name == "sh" || name == "bash" || name == "zsh" {
                if let scriptIndex = arguments.firstIndex(where: { $0.0 == "-c" }),
                   scriptIndex + 1 < arguments.count, !arguments[scriptIndex + 1].1 {
                    let nested = scan(command: arguments[scriptIndex + 1].0,
                                      cwd: currentCWD, home: home)
                    result.paths.append(contentsOf: nested.paths)
                    result.templates.append(contentsOf: nested.templates)
                    result.issues.append(contentsOf: nested.issues)
                }
                return
            }
            if ["cp", "mv", "install"].contains(name) {
                let values = operands(arguments, optionsWithValues: ["-m", "-o", "-g", "-t"])
                if values.count >= 2, let destination = values.last { claim(destination) }
            }
            if name == "tee" {
                for target in operands(arguments, optionsWithValues: []) where !isDevice(target) {
                    claim(target)
                }
            }
            let outputOptions: Set<String>
            switch name {
            case "swiftc", "clang", "clang++", "cc", "c++", "gcc", "g++", "ld": outputOptions = ["-o"]
            case "curl", "wget": outputOptions = ["-o", "--output", "-O", "--output-document"]
            case "xcodebuild": outputOptions = ["-derivedDataPath", "-archivePath", "-resultBundlePath", "-exportPath"]
            default: outputOptions = []
            }
            for index in arguments.indices where !arguments[index].1 {
                let value = arguments[index].0
                if outputOptions.contains(value), index + 1 < arguments.count, !arguments[index + 1].1 {
                    claim(arguments[index + 1].0)
                } else if let equals = value.firstIndex(of: "="), outputOptions.contains(String(value[..<equals])) {
                    claim(String(value[value.index(after: equals)...]))
                }
            }
            if name == "eval" || name == "source" || name == "." {
                result.issues.append("Skipped an eval/source shell command.")
                // Evaluated code may change directory.
                currentCWD = nil
                return
            }
        }

        while index < tokens.count {
            switch tokens[index] {
            case .separator(let separator):
                flush()
                switch separator {
                case .pipe:
                    // Each segment starts where the pipeline started.
                    currentCWD = scope.pipeline
                    scope.pipelineSegments += 1
                case .and, .or:
                    // Sequential for cd purposes: a later pipeline runs only after
                    // this one, in the directory it left.
                    endPipeline()
                    if separator == .or { scope.afterOr = true }
                    scope.pipeline = currentCWD
                case .sequence:
                    endPipeline()
                    scope.list = currentCWD
                    scope.pipeline = currentCWD
                    scope.afterOr = false
                case .background:
                    // The whole and-or list ran asynchronously in a subshell.
                    endPipeline()
                    currentCWD = scope.list
                    scope.list = currentCWD
                    scope.pipeline = currentCWD
                    scope.afterOr = false
                case .openSubshell:
                    subshells.append(scope)
                    scope = DirectoryScope(list: currentCWD, pipeline: currentCWD, entry: currentCWD)
                case .closeSubshell:
                    endPipeline()
                    if let outer = subshells.popLast() {
                        // A subshell's cd never reaches the enclosing shell.
                        currentCWD = scope.entry
                        scope = outer
                    } else {
                        // An unmatched `)` (such as a case pattern) has unknown structure.
                        currentCWD = nil
                        scope = DirectoryScope(list: nil, pipeline: nil, entry: nil)
                    }
                }
                index += 1
            case .redirect:
                index += 1
                var sawTarget = false
                while index < tokens.count {
                    if case .word(let value, let dynamic) = tokens[index] {
                        if dynamic {
                            result.issues.append("Skipped a dynamic shell redirection target.")
                        } else {
                            redirects.append(value)
                        }
                        sawTarget = true
                        index += 1
                        break
                    }
                    if case .separator = tokens[index] { break }
                    index += 1
                }
                if !sawTarget { result.issues.append("Skipped a shell redirection without a literal target.") }
            case .ignoreRedirect:
                index += 1
                if index < tokens.count, case .word = tokens[index] { index += 1 }
            case .word(let value, let dynamic):
                current.append((value, dynamic))
                index += 1
            }
        }
        flush()
    }

    private static func commandIndex(_ words: [(String, Bool)]) -> Int? {
        for (index, word) in words.enumerated() {
            let (value, dynamic) = word
            if dynamic { return nil }
            if value.contains("="), !value.hasPrefix("/"),
               value.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
                continue
            }
            if value == "env" || value == "command" || value == "nohup" || value == "time" {
                continue
            }
            return index
        }
        return nil
    }

    private static func operands(_ words: [(String, Bool)], optionsWithValues: Set<String>) -> [String] {
        var result: [String] = []
        var index = 0
        var endOfOptions = false
        while index < words.count {
            let (value, dynamic) = words[index]
            if !endOfOptions && value == "--" { endOfOptions = true; index += 1; continue }
            if !endOfOptions && value.hasPrefix("-") && value != "-" {
                if optionsWithValues.contains(value) { index += 2; continue }
                index += 1
                continue
            }
            if dynamic {
                // Reported once per command below.
            } else {
                result.append(value)
            }
            index += 1
        }
        return result
    }

    private static func isDevice(_ path: String) -> Bool {
        path == "/dev/null" || path == "/dev/stdout" || path == "/dev/stderr"
            || path == "/dev/tty" || path.hasPrefix("/dev/fd/")
    }
}
