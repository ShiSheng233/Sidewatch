import Foundation

/// Resolves the project that owns a working directory by walking parents for `.git`.
///
/// Disk work happens here and only here. Callers on the authorization path use a memory-only
/// lookup populated by a background worker; `RuleMatcher.evaluate` never performs I/O.
enum ProjectResolver {

    static func resolve(_ cwd: String?) -> ProjectRecord? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let start = canonical(cwd)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: start, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        var current = start
        while true {
            if let project = projectRecord(at: current) { return project }
            guard current != "/" else { break }
            let parent = (current as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != current else { break }
            current = parent
        }
        // An unversioned project is still identifiable by the launch directory.
        // The background caller owns its cache; explicit resolution observes newly created repos.
        return ProjectRecord(root: start, gitDirectory: nil)
    }

    private static func projectRecord(at directory: String) -> ProjectRecord? {
        let gitPath = directory == "/" ? "/.git" : directory + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory) else { return nil }

        if isDirectory.boolValue {
            return ProjectRecord(root: directory, gitDirectory: gitPath)
        }

        // A worktree has a `.git` file containing `gitdir: <path>`.
        guard let data = FileManager.default.contents(atPath: gitPath),
              let contents = String(data: data, encoding: .utf8),
              let firstLine = contents.split(separator: "\n", omittingEmptySubsequences: false).first else {
            return nil
        }
        let line = String(firstLine).trimmingCharacters(in: .whitespaces)
        guard line.lowercased().hasPrefix("gitdir:") else { return nil }
        let raw = String(line.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        let gitDirectory = raw.hasPrefix("/") ? canonical(raw) : canonical(directory + "/" + raw)
        return ProjectRecord(root: directory, gitDirectory: gitDirectory)
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
