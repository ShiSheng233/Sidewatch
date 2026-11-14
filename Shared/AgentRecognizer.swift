import Foundation

/// Recognizes known agent CLIs from structured execution data.
///
/// Matching is deliberately narrow: the executable basename must be an exact known name, the
/// executable must sit in a known versioned install directory, or a known JavaScript CLI script
/// must appear as the positional script of `node`/`bun`. Words that merely appear in arguments
/// (for example `echo codex` or `sh -c "claude ..."`) never match, and neither does `argv[0]`,
/// which the launching process chooses freely.
enum AgentRecognizer {
    private static let interpreters: Set<String> = ["node", "bun"]

    static func recognize(_ execution: ExecutionRecord, definitions: [AgentDefinition] = AgentDefinition.defaults) -> AgentDefinition? {
        let executableName = executableBasename(execution.executable)
        guard !executableName.isEmpty else { return nil }

        for definition in definitions where definition.executableNames.contains(executableName) {
            return definition
        }

        // The kernel reports the resolved executable path, so a versioned binary reached through a
        // `claude` symlink is identified by its install directory, never by argv[0].
        let directory = pathComponents((execution.executable as NSString).deletingLastPathComponent)
        for definition in definitions {
            let layout = definition.installDirectoryComponents
            guard !layout.isEmpty, layout.count <= directory.count else { continue }
            if directory.suffix(layout.count).elementsEqual(layout) {
                return definition
            }
        }

        guard interpreters.contains(executableName.lowercased()),
              let script = positionalScript(for: execution) else { return nil }
        let scriptComponents = pathComponents(script)
        guard !scriptComponents.isEmpty else { return nil }

        for definition in definitions {
            for suffix in definition.scriptPathComponents {
                let suffixComponents = pathComponents(suffix)
                guard !suffixComponents.isEmpty, suffixComponents.count <= scriptComponents.count else { continue }
                if scriptComponents.suffix(suffixComponents.count).elementsEqual(suffixComponents) {
                    return definition
                }
            }
        }
        return nil
    }

    /// Redacts credential flags, `--flag=value` forms, URL userinfo and secret-looking
    /// `NAME=value` assignments. Non-secret arguments are left untouched.
    static func redact(_ arguments: [String]) -> [String] {
        var result = arguments
        var index = 0
        while index < result.count {
            let argument = result[index]

            if let redactedFlag = redactedFlagAssignment(argument) {
                result[index] = redactedFlag
                index += 1
                continue
            }

            if isCredentialFlag(argument) {
                index += 1
                if index < result.count {
                    result[index] = "<redacted>"
                    index += 1
                }
                continue
            }

            result[index] = redactEmbeddedSecrets(argument)
            index += 1
        }
        return result
    }

    // MARK: - Script extraction

    private static func executableBasename(_ executable: String) -> String {
        (executable as NSString).lastPathComponent
    }

    private static func pathComponents(_ path: String) -> [String] {
        var value = path
        if value.hasPrefix("file://") {
            value = String(value.dropFirst("file://".count))
            value = value.removingPercentEncoding ?? value
        }
        return value.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Returns the first positional argument for node/bun, skipping options and `--`.
    private static func positionalScript(for execution: ExecutionRecord) -> String? {
        var arguments = execution.arguments
        if let first = arguments.first, isExecutableToken(first, executable: execution.executable) {
            arguments.removeFirst()
        }

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                index += 1
                break
            }
            // Inline evaluation has no script file.
            if argument == "-e" || argument == "--eval" || argument == "-p" || argument == "--print" {
                return nil
            }
            if argument.hasPrefix("--") {
                if argument.contains("=") {
                    index += 1
                } else if valueTakingOptions.contains(argument) {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            if argument.hasPrefix("-"), argument != "-" {
                index += valueTakingOptions.contains(argument) ? 2 : 1
                continue
            }
            return argument
        }

        if index < arguments.count {
            return arguments[index]
        }
        return nil
    }

    private static func isExecutableToken(_ token: String, executable: String) -> Bool {
        token == executable || executableBasename(token) == executableBasename(executable)
    }

    private static let valueTakingOptions: Set<String> = [
        "-r", "--require",
        "--loader", "--experimental-loader",
        "--import", "--inspect-port", "--title",
        "--max-old-space-size", "--max-semi-space-size",
        "--conditions", "--experimental-specifier-resolution"
    ]

    // MARK: - Redaction

    private static let credentialFlagNames: Set<String> = [
        "password", "passwd", "pass",
        "token", "api-key", "apikey",
        "secret", "client-secret",
        "access-token", "refresh-token", "auth-token", "session-token", "bearer", "bearer-token",
        "credential", "credentials", "private-key", "access-key", "secret-key",
        "auth", "authorization", "cookie"
    ]

    private static func normalizedFlagName(_ name: String) -> String {
        var value = name
        while value.hasPrefix("-") { value.removeFirst() }
        return value.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func isCredentialFlag(_ argument: String) -> Bool {
        guard argument.hasPrefix("-"), !argument.contains("=") else { return false }
        let name = normalizedFlagName(argument)
        guard !name.isEmpty else { return false }
        if credentialFlagNames.contains(name) { return true }
        return name.hasSuffix("-token")
            || name.hasSuffix("-secret")
            || name.hasSuffix("-password")
            || name.hasSuffix("-passwd")
            || name.hasSuffix("-credentials")
            || name.hasSuffix("-api-key")
            || name.hasSuffix("-private-key")
            || name.hasSuffix("-access-key")
            || name.hasSuffix("-secret-key")
            || name.hasSuffix("-session-token")
    }

    private static func redactedFlagAssignment(_ argument: String) -> String? {
        guard argument.hasPrefix("-"), let equals = argument.firstIndex(of: "=") else { return nil }
        let name = String(argument[..<equals])
        guard isCredentialFlag(name) else { return nil }
        return name + "=<redacted>"
    }

    private static func redactEmbeddedSecrets(_ argument: String) -> String {
        let urlRedacted = redactURLUserInfo(argument)
        return redactSecretAssignments(urlRedacted)
    }

    private static func redactURLUserInfo(_ argument: String) -> String {
        guard let scheme = argument.range(of: "://") else { return argument }
        let remainder = argument[scheme.upperBound...]
        guard let at = remainder.firstIndex(of: "@") else { return argument }
        let userInfo = remainder[remainder.startIndex..<at]
        guard !userInfo.isEmpty, !userInfo.contains("/") else { return argument }
        return String(argument[..<scheme.upperBound]) + "<redacted>" + String(remainder[at...])
    }

    private static func redactSecretAssignments(_ argument: String) -> String {
        let pattern = #"(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)[A-Za-z0-9_]*)=([^\s&,;]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return argument
        }
        let range = NSRange(argument.startIndex..<argument.endIndex, in: argument)
        return expression.stringByReplacingMatches(in: argument, options: [], range: range, withTemplate: "$1=<redacted>")
    }
}
