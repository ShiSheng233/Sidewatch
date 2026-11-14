import Foundation

struct AgentSessionRoot: Sendable {
    let provider: String
    let directory: URL
}

/// Provider-owned locations only. Project-folder encodings never establish cwd.
/// A custom home is isolated from the real process environment unless explicitly supplied.
enum AgentSessionRoots {
    static func discover(home: URL, environment: [String: String]? = nil) -> [AgentSessionRoot] {
        let home = home.standardizedFileURL
        let realHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let environment = environment ?? (home == realHome ? ProcessInfo.processInfo.environment : [:])
        var roots: [AgentSessionRoot] = []
        var seen: Set<String> = []

        func add(_ provider: String, _ directory: URL) {
            let directory = directory.resolvingSymlinksInPath().standardizedFileURL
            if seen.insert(provider + ":" + directory.path).inserted {
                roots.append(AgentSessionRoot(provider: provider, directory: directory))
            }
        }

        func configured(_ value: String?) -> URL? {
            guard let value, !value.isEmpty else { return nil }
            let expanded: String
            if value == "~" { expanded = home.path }
            else if value.hasPrefix("~/") { expanded = home.appendingPathComponent(String(value.dropFirst(2))).path }
            else { expanded = value }
            guard expanded.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }

        func children(_ directory: URL) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        }

        func isDirectory(_ url: URL) -> Bool {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        }

        func accountHomes(primary: URL, prefix: String, evidence: String) -> [URL] {
            func hasEvidence(_ account: URL) -> Bool {
                if isDirectory(account.appendingPathComponent(evidence)) { return true }
                return prefix == "codex" && (isDirectory(account.appendingPathComponent("archived_sessions"))
                    || FileManager.default.fileExists(atPath: account.appendingPathComponent("auth.json").path))
            }
            var homes = [primary]
            var parents = [home]
            if primary.deletingLastPathComponent() != home { parents.append(primary.deletingLastPathComponent()) }
            for parent in parents {
                for sibling in children(parent) {
                    let name = sibling.lastPathComponent
                    guard name.hasPrefix(prefix) || name.hasPrefix("." + prefix), isDirectory(sibling) else { continue }
                    if hasEvidence(sibling) { homes.append(sibling) }
                    for profile in children(sibling) where hasEvidence(profile) {
                        homes.append(profile)
                    }
                }
            }
            return homes
        }

        let codex = configured(environment["CODEX_HOME"]) ?? home.appendingPathComponent(".codex")
        for account in accountHomes(primary: codex, prefix: "codex", evidence: "sessions") {
            add("codex", account.appendingPathComponent("sessions"))
            add("codex", account.appendingPathComponent("archived_sessions"))
        }
        let claude = configured(environment["CLAUDE_CONFIG_DIR"]) ?? home.appendingPathComponent(".claude")
        for account in accountHomes(primary: claude, prefix: "claude", evidence: "projects") {
            add("claude", account.appendingPathComponent("projects"))
        }
        // magpie keeps native Claude account homes here; walking the parent also
        // makes unreadable account directories visible to the scanner.
        let config = configured(environment["XDG_CONFIG_HOME"]) ?? home.appendingPathComponent(".config")
        add("claude", config.appendingPathComponent("magpie/claude-accounts"))

        add("omp", home.appendingPathComponent(".omp/agent/sessions"))
        add("omp", home.appendingPathComponent(".omp/profiles"))
        if let dataHome = configured(environment["XDG_DATA_HOME"]) {
            add("omp", dataHome.appendingPathComponent("omp/sessions"))
        }

        let pi = configured(environment["PI_CODING_AGENT_DIR"]) ?? home.appendingPathComponent(".pi/agent")
        add("pi", pi.appendingPathComponent("sessions"))
        let setting = readSettings(pi.appendingPathComponent("settings.json"))
        if let sessions = configured(environment["PI_CODING_AGENT_SESSION_DIR"])
            ?? configured(setting?.sessionDir) { add("pi", sessions) }
        let subagents = readSettings(pi.appendingPathComponent("extensions/subagent/config.json"))
        if let sessions = configured(subagents?.defaultSessionDir) { add("pi", sessions) }
        return roots
    }

    private struct DirectorySettings: Decodable {
        var sessionDir: String?
        var defaultSessionDir: String?
    }

    private static func readSettings(_ path: URL) -> DirectorySettings? {
        // Settings contain no session bodies. Refuse unexpectedly large config files.
        guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1_048_576, let data = try? Data(contentsOf: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        return try? decoder.decode(DirectorySettings.self, from: data)
    }
}
