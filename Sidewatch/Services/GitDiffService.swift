import Foundation
import Darwin

/// Outcome of a read-only Git comparison of one file's working copy against `HEAD`.
///
/// A diff shows the current workspace state. It may include edits made by other tools or
/// people and never proves which agent changed an individual line.
enum GitDiffResult: Equatable, Sendable {
    case diff(repository: String, text: String, truncated: Bool)
    case noChanges(repository: String)
    /// The file has no committed baseline (untracked, or the repository has no commits).
    case noBaseline(repository: String)
    case notInRepository
    case gitUnavailable
    case failed(status: Int32)
}

/// Runs `git` with read-only commands only: no checkout, no index refresh, no optional locks,
/// no external diff drivers or text conversion filters.
struct GitDiffService: Sendable {
    var gitPath = "/usr/bin/git"
    var timeout: TimeInterval = 10
    var outputLimit = 1_000_000

    func diff(forFile path: String) async -> GitDiffResult {
        let service = self
        return await Task.detached(priority: .userInitiated) {
            service.computeDiff(forFile: path)
        }.value
    }

    nonisolated func computeDiff(forFile path: String) -> GitDiffResult {
        guard path.hasPrefix("/"), !path.contains("\0") else { return .notInRepository }
        guard let directory = Self.nearestExistingDirectory(for: path) else { return .notInRepository }

        let topLevel: String
        switch run(["rev-parse", "--show-toplevel"], in: directory) {
        case .launchFailed:
            return .gitUnavailable
        case .timedOut:
            return .failed(status: ETIMEDOUT)
        case .finished(let status, let output, _):
            guard status == 0 else {
                // 128 is Git's "not a repository" status; anything else is a tool failure.
                return status == 128 ? .notInRepository : .gitUnavailable
            }
            topLevel = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !topLevel.isEmpty else { return .notInRepository }

        let pathspec = ":(literal)" + Self.relativePath(path, to: topLevel)

        if case .finished(let status, _, _) = run(["rev-parse", "--verify", "--quiet", "HEAD"], in: topLevel), status != 0 {
            return .noBaseline(repository: topLevel)
        }

        // A path absent from HEAD has no content baseline, whether or not it is staged.
        switch run(["cat-file", "-e", "HEAD:" + Self.relativePath(path, to: topLevel)], in: topLevel) {
        case .finished(let status, _, _) where status != 0:
            return .noBaseline(repository: topLevel)
        case .launchFailed:
            return .gitUnavailable
        case .timedOut:
            return .failed(status: ETIMEDOUT)
        default:
            break
        }

        switch run(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "HEAD", "--", pathspec], in: topLevel) {
        case .launchFailed:
            return .gitUnavailable
        case .timedOut:
            return .failed(status: ETIMEDOUT)
        case .finished(let status, let output, let truncated):
            guard status == 0 else { return .failed(status: status) }
            if output.isEmpty { return .noChanges(repository: topLevel) }
            return .diff(repository: topLevel, text: String(decoding: output, as: UTF8.self), truncated: truncated)
        }
    }

    // MARK: - Process execution

    private enum RunResult {
        case finished(status: Int32, output: Data, truncated: Bool)
        case launchFailed
        case timedOut
    }

    private nonisolated func run(_ arguments: [String], in directory: String) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = ["-C", directory, "-c", "core.fsmonitor=false", "-c", "core.quotePath=false"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .launchFailed
        }

        let deadline = DispatchTime.now() + timeout
        let timedOut = TimeoutFlag()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) { [weak process] in
            guard let process, process.isRunning else { return }
            timedOut.set()
            process.terminate()
        }

        var output = Data()
        var truncated = false
        let handle = pipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if output.count < outputLimit {
                output.append(chunk.prefix(outputLimit - output.count))
                if output.count >= outputLimit { truncated = true }
            } else {
                truncated = true
            }
        }
        process.waitUntilExit()
        if timedOut.isSet { return .timedOut }
        return .finished(status: process.terminationStatus, output: output, truncated: truncated)
    }

    // MARK: - Paths

    private nonisolated static func nearestExistingDirectory(for path: String) -> String? {
        var current = (path as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        while !current.isEmpty {
            if FileManager.default.fileExists(atPath: current, isDirectory: &isDirectory), isDirectory.boolValue {
                return current
            }
            guard current != "/" else { return nil }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Git reports the canonical top level; resolve the file's directory the same way so
    /// `/tmp` versus `/private/tmp` style aliases still produce a repository-relative path.
    nonisolated static func relativePath(_ path: String, to topLevel: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let resolvedParent = URL(fileURLWithPath: parent).resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedTop = URL(fileURLWithPath: topLevel).resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = resolvedParent == "/" ? "/" + name : resolvedParent + "/" + name
        let prefix = resolvedTop.hasSuffix("/") ? resolvedTop : resolvedTop + "/"
        if candidate.hasPrefix(prefix) {
            return String(candidate.dropFirst(prefix.count))
        }
        return path
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
