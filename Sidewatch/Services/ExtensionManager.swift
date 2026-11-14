import AppKit
import Foundation
import OSLog
import SystemExtensions

/// Version of a monitor extension bundle, as reported by the system or read from the app.
struct MonitorVersion: Equatable, Sendable {
    var version: String
    var build: String
}

/// Outcome of an uninstall (deactivation) request.
enum MonitorRemovalOutcome: Equatable, Sendable {
    case removed
    case afterRestart
    case canceled
    case failed(String)
}

/// Host-side lifecycle for the Endpoint Security system extension.
///
/// Installing, updating, or removing the extension is always an explicit user action:
/// creating the manager only queries the current system state. Delegate
/// callbacks arrive on the main queue and are applied on the main actor.
@MainActor
final class ExtensionManager: NSObject {
    /// A system-extension request this manager is running.
    enum Operation: Equatable, Sendable {
        case checking, installing, uninstalling
    }

    var availability: MonitorAvailability = .connecting
    var errorCode: String?
    var onChange: (() -> Void)?

    private(set) var operation: Operation?
    /// The installed extension the system reported in the last status check.
    private(set) var installed: MonitorVersion?
    /// When the system last answered a status check.
    private(set) var lastChecked: Date?
    /// The extension embedded in this copy of the app.
    let bundled: MonitorVersion? = ExtensionManager.readBundledVersion()

    /// The installed extension differs from the one inside this app.
    var isUpdateAvailable: Bool {
        guard let installed, let bundled else { return false }
        return installed != bundled
    }

    private var request: OSSystemExtensionRequest?
    private var removal: CheckedContinuation<MonitorRemovalOutcome, Never>?

    override init() {
        super.init()
        queryProperties()
    }

    func activate() {
        guard operation != .installing, operation != .uninstalling else { return }
        update(.connecting, errorCode: nil)
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: MonitorWire.extensionID,
            queue: .main
        )
        submit(request, as: .installing)
        Diagnostics.lifecycle.notice("Requesting system extension activation.")
    }

    /// Asks the system to remove the extension. macOS asks for an administrator's approval.
    func deactivate() async -> MonitorRemovalOutcome {
        guard operation != .installing, operation != .uninstalling else {
            return .failed(String(localized: "Another monitor request is in progress."))
        }
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: MonitorWire.extensionID,
            queue: .main
        )
        Diagnostics.lifecycle.notice("Requesting system extension deactivation.")
        return await withCheckedContinuation { continuation in
            removal = continuation
            submit(request, as: .uninstalling)
        }
    }

    /// Asks the system for the extension's current state again. Ignored while a request runs.
    func refreshStatus() {
        queryProperties()
    }

    func openFullDiskAccess() {
        let modern = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!
        let legacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        if !NSWorkspace.shared.open(modern), !NSWorkspace.shared.open(legacy) {
            Diagnostics.interface.error("Could not open Full Disk Access settings.")
        }
    }

    func openExtensionSettings() {
        let settings = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        if !NSWorkspace.shared.open(settings) {
            Diagnostics.interface.error("Could not open extension settings.")
        }
    }

    // MARK: - System state

    private func queryProperties() {
        guard operation == nil else { return }
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: MonitorWire.extensionID,
            queue: .main
        )
        submit(request, as: .checking)
    }

    private func submit(_ request: OSSystemExtensionRequest, as kind: Operation) {
        request.delegate = self
        self.request = request
        operation = kind
        onChange?()
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private static func readBundledVersion() -> MonitorVersion? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
            .appendingPathComponent(MonitorWire.extensionID + ".systemextension", isDirectory: true)
        guard let bundle = Bundle(url: url),
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return nil }
        return MonitorVersion(version: version, build: build)
    }

    private func update(_ availability: MonitorAvailability, errorCode: String?) {
        self.availability = availability
        self.errorCode = errorCode
        onChange?()
    }

    private func isCurrent(_ identifier: ObjectIdentifier) -> Bool {
        guard let request else { return false }
        return ObjectIdentifier(request) == identifier
    }

    private func finish(_ identifier: ObjectIdentifier) {
        guard isCurrent(identifier) else { return }
        request = nil
        operation = nil
        onChange?()
    }

    private func completeRemoval(_ outcome: MonitorRemovalOutcome) {
        let continuation = removal
        removal = nil
        continuation?.resume(returning: outcome)
    }

    private func applyProperties(installed: Bool, enabled: Bool, awaitingApproval: Bool, uninstalling: Bool) {
        if uninstalling {
            update(.needsRestart, errorCode: nil)
        } else if enabled {
            update(.active, errorCode: nil)
        } else if awaitingApproval {
            update(.awaitingApproval, errorCode: nil)
        } else if installed {
            update(.unavailable, errorCode: "extensionDisabled")
        } else {
            update(.notInstalled, errorCode: nil)
        }
    }

    private func applyDeactivationResult(_ result: OSSystemExtensionRequest.Result) {
        installed = nil
        switch result {
        case .completed:
            update(.notInstalled, errorCode: nil)
            completeRemoval(.removed)
        case .willCompleteAfterReboot:
            update(.needsRestart, errorCode: nil)
            completeRemoval(.afterRestart)
        @unknown default:
            update(.unavailable, errorCode: "unknownResult")
            completeRemoval(.failed(String(localized: "The system returned an unexpected result.")))
        }
    }

    private func applyActivationResult(_ result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            update(.active, errorCode: nil)
        case .willCompleteAfterReboot:
            update(.needsRestart, errorCode: nil)
        @unknown default:
            update(.unavailable, errorCode: "unknownResult")
        }
    }

    private func applyFailure(domain: String, code: Int) {
        guard domain == OSSystemExtensionErrorDomain,
              let failure = OSSystemExtensionError.Code(rawValue: code) else {
            update(.unavailable, errorCode: "oserror")
            return
        }

        switch failure {
        case .missingEntitlement:
            update(.notEntitled, errorCode: "missingEntitlement")
        case .extensionNotFound:
            update(.notInstalled, errorCode: "extensionNotFound")
        case .unsupportedParentBundleLocation:
            update(.unavailable, errorCode: "unsupportedLocation")
        case .extensionMissingIdentifier:
            update(.unavailable, errorCode: "missingIdentifier")
        case .duplicateExtensionIdentifer:
            update(.unavailable, errorCode: "duplicateIdentifier")
        case .unknownExtensionCategory:
            update(.unavailable, errorCode: "unknownCategory")
        case .codeSignatureInvalid:
            update(.unavailable, errorCode: "codeSignature")
        case .validationFailed:
            update(.unavailable, errorCode: "validation")
        case .forbiddenBySystemPolicy:
            update(.unavailable, errorCode: "systemPolicy")
        case .requestCanceled:
            update(.notInstalled, errorCode: "canceled")
        case .requestSuperseded:
            update(.unavailable, errorCode: "superseded")
        case .authorizationRequired:
            update(.unavailable, errorCode: "authorizationRequired")
        case .unknown:
            update(.unavailable, errorCode: "unknown")
        @unknown default:
            update(.unavailable, errorCode: "oserror")
        }
    }
}

extension ExtensionManager: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        Diagnostics.lifecycle.notice("Replacing an existing system extension.")
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        let identifier = ObjectIdentifier(request)
        MainActor.assumeIsolated {
            guard isCurrent(identifier), operation == .installing else { return }
            update(.awaitingApproval, errorCode: nil)
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        let identifier = ObjectIdentifier(request)
        MainActor.assumeIsolated {
            guard isCurrent(identifier) else { return }
            switch operation {
            case .installing:
                installed = bundled
                lastChecked = Date()
                applyActivationResult(result)
            case .uninstalling:
                lastChecked = Date()
                applyDeactivationResult(result)
            case .checking, nil:
                return
            }
            finish(identifier)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let identifier = ObjectIdentifier(request)
        let nsError = error as NSError
        let domain = nsError.domain
        let code = nsError.code
        MainActor.assumeIsolated {
            guard isCurrent(identifier) else { return }
            Diagnostics.lifecycle.error("System extension request failed (\(code, privacy: .public)).")
            if operation == .uninstalling {
                finish(identifier)
                let failure = domain == OSSystemExtensionErrorDomain ? OSSystemExtensionError.Code(rawValue: code) : nil
                switch failure {
                case .extensionNotFound?:
                    installed = nil
                    update(.notInstalled, errorCode: nil)
                    completeRemoval(.removed)
                case .requestCanceled?, .authorizationRequired?:
                    completeRemoval(.canceled)
                    queryProperties()
                default:
                    completeRemoval(.failed(String(localized: "The system couldn't remove the monitor extension (error \(code)).")))
                    queryProperties()
                }
                return
            }
            if operation == .checking { lastChecked = Date() }
            applyFailure(domain: domain, code: code)
            finish(identifier)
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        foundProperties properties: [OSSystemExtensionProperties]
    ) {
        let identifier = ObjectIdentifier(request)
        let exists = !properties.isEmpty
        let enabled = properties.contains { $0.isEnabled && !$0.isUninstalling }
        let awaitingApproval = properties.contains { $0.isAwaitingUserApproval }
        // A replaced version can stay "uninstalling" until restart while its successor runs.
        let uninstalling = !enabled && properties.contains { $0.isUninstalling }
        let current = properties.first { $0.isEnabled && !$0.isUninstalling }
            ?? properties.first { $0.isAwaitingUserApproval }
            ?? properties.first { !$0.isUninstalling }
        let version = current.map { MonitorVersion(version: $0.bundleShortVersion, build: $0.bundleVersion) }
        MainActor.assumeIsolated {
            guard isCurrent(identifier), operation == .checking else { return }
            installed = version
            lastChecked = Date()
            applyProperties(
                installed: exists,
                enabled: enabled,
                awaitingApproval: awaitingApproval,
                uninstalling: uninstalling
            )
            finish(identifier)
        }
    }
}
