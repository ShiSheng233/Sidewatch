import Foundation
import Darwin

/// Outcome of a control request. `action` records only what actually happened to the
/// signal; a failure to persist the audit record is reported separately and never
/// rewrites `signalSent` or claims `exitConfirmed`.
struct ProcessControlResult: Sendable {
    var action: ControlAction
    var auditErrorCode: String?
}

/// Requests a fresh extension token for the exact execution, validates the live target,
/// and signals it through the native probe's audit-token path on a background executor.
@MainActor
final class ProcessControlService {
    private let connection: MonitorConnection

    init(connection: MonitorConnection) {
        self.connection = connection
    }

    func perform(_ request: ControlRequest) async -> ProcessControlResult {
        let action: ControlAction
        if let code = Self.precheckFailure(request) {
            action = Self.failedAction(request, code: code)
        } else {
            do {
                let token = try await connection.liveToken(request.execution)
                action = await Task.detached(priority: .userInitiated) {
                    ProcessControlService.signal(request, token: token)
                }.value
            } catch {
                action = Self.failedAction(request, code: Self.failureCode(error))
            }
        }

        var auditErrorCode: String?
        do {
            try await connection.recordControl(action)
        } catch {
            // Persistence failure is distinct from the signal result.
            auditErrorCode = (error as? MonitorConnectionError)?.errorCode ?? "operation"
        }
        return ProcessControlResult(action: action, auditErrorCode: auditErrorCode)
    }

    /// Exercises the same real validation and `proc_signal_with_audittoken` path as
    /// `perform`, using a token supplied by the caller. Isolated tests may pass a token
    /// reported by their own child process.
    nonisolated static func signal(_ request: ControlRequest, token: Data) -> ControlAction {
        let pid = request.execution.process.pid
        guard pid > 0, pid != getpid(), token.count == MemoryLayout<audit_token_t>.size else {
            return failedAction(request, code: EINVAL)
        }
        do {
            guard try SystemIdentity.bootID() == request.execution.process.bootID else {
                return failedAction(request, code: ESTALE)
            }
        } catch {
            return failedAction(request, code: failureCode(error))
        }

        let signalNumber: Int32 = request.operation == .stop ? SIGTERM : SIGKILL
        let status = token.withUnsafeBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return EINVAL
            }
            return sw_probe_signal(
                pid,
                request.execution.process.startTimeMicros,
                request.execution.version,
                geteuid(),
                base,
                buffer.count,
                signalNumber
            )
        }

        return ControlAction(
            execution: request.execution,
            operation: request.operation,
            requestedAt: Date(),
            signalSent: status == 0,
            exitConfirmed: false,
            errorCode: status == 0 ? nil : status
        )
    }

    /// Boot, PID, and live identity checks that must pass before a token is requested.
    private nonisolated static func precheckFailure(_ request: ControlRequest) -> Int32? {
        let pid = request.execution.process.pid
        guard pid > 0, pid != getpid() else { return EINVAL }

        do {
            guard try SystemIdentity.bootID() == request.execution.process.bootID else {
                return ESTALE
            }
        } catch {
            return (error as? POSIXError)?.code.rawValue ?? EIO
        }

        var observed = SWProcessIdentity()
        let status = sw_probe_identity(pid, &observed)
        guard status == 0 else { return status }
        guard observed.pid == pid,
              observed.start_time_micros == request.execution.process.startTimeMicros else {
            return ESTALE
        }
        guard observed.user_id == geteuid() else { return EPERM }
        return nil
    }

    private nonisolated static func failureCode(_ error: Error) -> Int32 {
        if let monitor = error as? MonitorConnectionError {
            switch monitor {
            case .invalidToken(let code):
                // A zero token errno means the extension no longer sees the process.
                return code == 0 ? ESRCH : code
            case .malformedToken:
                return EINVAL
            case .notConnected:
                return ENOTCONN
            case .cancelled:
                return ECANCELED
            default:
                return EIO
            }
        }
        if let posix = error as? POSIXError {
            return posix.code.rawValue
        }
        return EIO
    }

    private nonisolated static func failedAction(_ request: ControlRequest, code: Int32) -> ControlAction {
        ControlAction(
            execution: request.execution,
            operation: request.operation,
            requestedAt: Date(),
            signalSent: false,
            exitConfirmed: false,
            errorCode: code
        )
    }
}
