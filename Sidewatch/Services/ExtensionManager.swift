import AppKit
import Foundation
import SystemExtensions

/// Host-side lifecycle for the Endpoint Security system extension.
///
/// Installing or activating the extension is always an explicit user action:
/// creating the manager only queries the current system state. Delegate
/// callbacks arrive on the main queue and are applied on the main actor.
@MainActor
final class ExtensionManager: NSObject {
    var availability: MonitorAvailability = .connecting
    var errorCode: String?
    var onChange: (() -> Void)?

    private enum RequestKind: Equatable {
        case properties
        case activation
    }

    private var request: OSSystemExtensionRequest?
    private var pending: RequestKind?

    override init() {
        super.init()
        queryProperties()
    }

    func activate() {
        guard pending != .activation else { return }
        update(.connecting, errorCode: nil)
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: MonitorWire.extensionID,
            queue: .main
        )
        request.delegate = self
        self.request = request
        pending = .activation
        Diagnostics.lifecycle.notice("Requesting system extension activation.")
        OSSystemExtensionManager.shared.submitRequest(request)
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
        guard pending == nil else { return }
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: MonitorWire.extensionID,
            queue: .main
        )
        request.delegate = self
        self.request = request
        pending = .properties
        OSSystemExtensionManager.shared.submitRequest(request)
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
        pending = nil
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
            guard isCurrent(identifier), pending == .activation else { return }
            update(.awaitingApproval, errorCode: nil)
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        let identifier = ObjectIdentifier(request)
        MainActor.assumeIsolated {
            guard isCurrent(identifier), pending == .activation else { return }
            applyActivationResult(result)
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
            applyFailure(domain: domain, code: code)
            finish(identifier)
            Diagnostics.lifecycle.error("System extension request failed (\(code, privacy: .public)).")
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        foundProperties properties: [OSSystemExtensionProperties]
    ) {
        let identifier = ObjectIdentifier(request)
        let installed = !properties.isEmpty
        let enabled = properties.contains { $0.isEnabled }
        let awaitingApproval = properties.contains { $0.isAwaitingUserApproval }
        let uninstalling = properties.contains { $0.isUninstalling }
        MainActor.assumeIsolated {
            guard isCurrent(identifier), pending == .properties else { return }
            applyProperties(
                installed: installed,
                enabled: enabled,
                awaitingApproval: awaitingApproval,
                uninstalling: uninstalling
            )
            finish(identifier)
        }
    }
}
