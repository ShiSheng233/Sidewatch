import Foundation
import OSLog

/// Authenticated XPC client for the privileged Endpoint Security extension.
///
/// Only typed, versioned Codable envelopes cross the wire. The connection is
/// created on demand, requires the monitor extension's signature, and performs
/// an explicit protocol handshake before any operation is considered usable.
@MainActor
final class MonitorConnection {
    var onCommit: ((String, Int64) -> Void)?
    var onHealth: ((MonitorHealth) -> Void)?
    var onDisconnect: (() -> Void)?

    private var connection: NSXPCConnection?
    private var generation: UInt64 = 0
    private var isHandshaken = false
    private var connectTask: Task<Void, Error>?
    private var connectID: UUID?
    private let pending = PendingRegistry()

    private static let tokenByteCount = 32
    private static let peerRequirement =
        "anchor apple generic and identifier \"\(MonitorWire.extensionID)\" and certificate leaf[subject.OU] = \"\(MonitorWire.teamID)\""

    func connect() async throws {
        try Task.checkCancellation()
        if isHandshaken { return }
        if let connectTask {
            try await connectTask.value
            guard isHandshaken else { throw MonitorConnectionError.notConnected }
            return
        }

        let identifier = UUID()
        let task = Task { @MainActor [self] in
            try await performConnect()
        }
        connectTask = task
        connectID = identifier
        do {
            try await task.value
            if connectID == identifier {
                connectTask = nil
                connectID = nil
            }
            guard isHandshaken else { throw MonitorConnectionError.notConnected }
        } catch {
            if connectID == identifier {
                connectTask = nil
                connectID = nil
            }
            throw error
        }
    }

    func disconnect() {
        guard connection != nil || connectTask != nil else { return }
        connectTask?.cancel()
        connectTask = nil
        connectID = nil
        teardown(generation: generation, notify: true, invalidateConnection: true)
        Diagnostics.connection.notice("Monitor service disconnected.")
    }

    func snapshot() async throws -> MonitorSnapshot {
        try requireHandshake()
        let data = try await perform { proxy, reply in
            proxy.snapshot(withReply: reply)
        }
        return try decodeReply(MonitorSnapshot.self, from: data)
    }

    func activities(_ query: ActivityQuery) async throws -> ActivityPage {
        try requireHandshake()
        let payload = try encode(query)
        let data = try await perform { proxy, reply in
            proxy.activities(payload, withReply: reply)
        }
        return try decodeReply(ActivityPage.self, from: data)
    }

    func configure(_ value: MonitorConfiguration) async throws -> MonitorConfiguration {
        try requireHandshake()
        let payload = try encode(value)
        let data = try await perform { proxy, reply in
            proxy.configure(payload, withReply: reply)
        }
        return try decodeReply(MonitorConfiguration.self, from: data)
    }

    func liveToken(_ identity: ExecutionIdentity) async throws -> Data {
        try requireHandshake()
        let payload = try encode(identity)
        let result = try await perform { proxy, reply in
            proxy.liveToken(payload, withReply: { @Sendable token, code in
                reply(TokenReply(token: token, errno: code))
            })
        }
        guard let token = result.token else {
            throw MonitorConnectionError.invalidToken(result.errno)
        }
        guard token.count == Self.tokenByteCount else {
            throw MonitorConnectionError.malformedToken
        }
        return token
    }

    func recordControl(_ action: ControlAction) async throws {
        try requireHandshake()
        let payload = try encode(action)
        let data = try await perform { proxy, reply in
            proxy.recordControl(payload, withReply: reply)
        }
        _ = try decodeReply(EmptyReply.self, from: data)
    }

    func clearHistory() async throws {
        try requireHandshake()
        let data = try await perform { proxy, reply in
            proxy.clearHistory(withReply: reply)
        }
        _ = try decodeReply(EmptyReply.self, from: data)
    }

    func eraseAllData() async throws {
        try requireHandshake()
        let data = try await perform { proxy, reply in
            proxy.eraseAllData(withReply: reply)
        }
        _ = try decodeReply(EmptyReply.self, from: data)
    }

    func prepareForRemoval(_ armed: Bool) async throws {
        try requireHandshake()
        let data = try await perform { proxy, reply in
            proxy.prepareForRemoval(armed, withReply: reply)
        }
        _ = try decodeReply(EmptyReply.self, from: data)
    }

    // MARK: - Connection lifecycle

    private func performConnect() async throws {
        try Task.checkCancellation()
        if connection != nil {
            teardown(generation: generation, notify: false, invalidateConnection: true)
        }
        pending.failAll(.notConnected)

        let connection = NSXPCConnection(
            machServiceName: MonitorWire.serviceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: MonitorRemote.self)
        connection.exportedInterface = NSXPCInterface(with: MonitorClient.self)

        generation &+= 1
        let currentGeneration = generation
        let adapter = MonitorClientAdapter(
            commit: { [weak self] storeID, watermark in
                Task { @MainActor in
                    self?.handleCommit(
                        generation: currentGeneration,
                        storeID: storeID,
                        watermark: watermark
                    )
                }
            },
            health: { [weak self] data in
                Task { @MainActor in
                    self?.handleHealth(generation: currentGeneration, data: data)
                }
            }
        )
        connection.exportedObject = adapter
        self.connection = connection

        // XPC invokes these on its own queue; they must not inherit main-actor isolation.
        connection.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor in
                self?.handleConnectionLoss(generation: currentGeneration, invalidate: true)
            }
        }
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in
                self?.handleConnectionLoss(generation: currentGeneration, invalidate: false)
            }
        }
        connection.setCodeSigningRequirement(Self.peerRequirement)
        connection.resume()

        do {
            let data = try await perform { proxy, reply in
                proxy.handshake(MonitorWire.version, withReply: reply)
            }
            _ = try decodeReply(EmptyReply.self, from: data)
            guard generation == currentGeneration, self.connection === connection else {
                throw MonitorConnectionError.cancelled
            }
            try Task.checkCancellation()
            isHandshaken = true
            Diagnostics.connection.notice("Monitor service handshake completed.")
        } catch {
            teardown(generation: currentGeneration, notify: true, invalidateConnection: true)
            Diagnostics.connection.error("Monitor service connection failed.")
            throw error
        }
    }

    private func handleConnectionLoss(generation expected: UInt64, invalidate: Bool) {
        guard expected == generation, connection != nil else { return }
        teardown(generation: expected, notify: true, invalidateConnection: invalidate)
        Diagnostics.connection.notice("Monitor service connection closed.")
    }

    private func teardown(generation expected: UInt64, notify: Bool, invalidateConnection: Bool) {
        guard expected == generation else { return }
        let wasHandshaken = isHandshaken
        let previous = connection
        connection = nil
        isHandshaken = false
        generation &+= 1
        pending.failAll(.serviceUnavailable(0))
        if invalidateConnection {
            previous?.invalidate()
        }
        if notify, wasHandshaken {
            onDisconnect?()
        }
    }

    private func handleCommit(generation expected: UInt64, storeID: String, watermark: Int64) {
        guard expected == generation, isHandshaken else { return }
        onCommit?(storeID, watermark)
    }

    private func handleHealth(generation expected: UInt64, data: Data) {
        guard expected == generation, isHandshaken else { return }
        do {
            let envelope = try MonitorWire.decode(WireEnvelope<MonitorHealth>.self, from: data)
            guard envelope.error == nil, envelope.errorCode == nil else {
                Diagnostics.connection.error("Monitor health notification reported an error.")
                return
            }
            guard let health = envelope.value else {
                Diagnostics.connection.error("Monitor health notification was empty.")
                return
            }
            onHealth?(health)
        } catch {
            Diagnostics.connection.error("Monitor health notification could not be decoded.")
        }
    }

    // MARK: - Requests

    private func requireHandshake() throws {
        guard connection != nil, isHandshaken else {
            throw MonitorConnectionError.notConnected
        }
    }

    private func encode<T: Codable & Sendable>(_ value: T) throws -> Data {
        do {
            return try MonitorWire.encode(value)
        } catch {
            throw MonitorConnectionError.encoding
        }
    }

    private func decodeReply<Value: Codable & Sendable>(_ type: Value.Type, from data: Data) throws -> Value {
        let envelope: WireEnvelope<Value>
        do {
            envelope = try MonitorWire.decode(WireEnvelope<Value>.self, from: data)
        } catch {
            throw MonitorConnectionError.decoding
        }

        if let rawCode = envelope.errorCode {
            let code = Self.sanitizedCode(rawCode)
            switch code {
            case "store_cursor_mismatch", "store_invalid_watermark":
                throw MonitorConnectionError.cursor
            case "version":
                throw MonitorConnectionError.protocolVersion
            default:
                throw MonitorConnectionError.remote(code)
            }
        }
        if envelope.error != nil {
            throw MonitorConnectionError.remote("operation")
        }
        guard let value = envelope.value else {
            throw MonitorConnectionError.invalidReply
        }
        return value
    }

    private static func sanitizedCode(_ raw: String) -> String {
        let candidate = raw.prefix(64)
        guard !candidate.isEmpty,
              candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            return "operation"
        }
        return String(candidate)
    }

    private func perform<Value: Sendable>(
        _ invoke: @MainActor (MonitorRemote, @escaping @Sendable (Value) -> Void) -> Void
    ) async throws -> Value {
        guard let connection else {
            throw MonitorConnectionError.notConnected
        }
        let expectedGeneration = generation
        let token = UUID()
        let reply = ReplyOnce<Value>()
        let pendingRegistry = pending

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                reply.install(continuation)
                guard !reply.isSettled else { return }
                guard !Task.isCancelled else {
                    reply.fail(.cancelled)
                    return
                }
                guard self.generation == expectedGeneration, self.connection === connection else {
                    reply.fail(.notConnected)
                    return
                }

                pendingRegistry.add(token, reply)
                guard !Task.isCancelled, !reply.isSettled else {
                    pendingRegistry.remove(token)
                    reply.fail(.cancelled)
                    return
                }

                // Called on an XPC queue: explicitly nonisolated so no main-actor assertion fires there.
                let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                    let code = Int32(clamping: (error as NSError).code)
                    reply.fail(.serviceUnavailable(code))
                    pendingRegistry.remove(token)
                }
                guard let remote = proxy as? MonitorRemote else {
                    pendingRegistry.remove(token)
                    reply.fail(.serviceUnavailable(0))
                    return
                }

                invoke(remote) { value in
                    reply.succeed(value)
                    pendingRegistry.remove(token)
                }
            }
        }, onCancel: {
            reply.fail(.cancelled)
            pendingRegistry.remove(token)
        })
    }

    private struct TokenReply: Sendable {
        let token: Data?
        let errno: Int32
    }
}

private protocol PendingReply: AnyObject, Sendable {
    func fail(_ error: MonitorConnectionError)
}

private final class PendingRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UUID: any PendingReply] = [:]

    func add(_ token: UUID, _ reply: any PendingReply) {
        lock.lock()
        entries[token] = reply
        lock.unlock()
    }

    func remove(_ token: UUID) {
        lock.lock()
        entries.removeValue(forKey: token)
        lock.unlock()
    }

    func failAll(_ error: MonitorConnectionError) {
        lock.lock()
        let replies = Array(entries.values)
        entries.removeAll()
        lock.unlock()
        for reply in replies {
            reply.fail(error)
        }
    }
}

/// Guarantees exactly one continuation resume, even when a reply, an XPC
/// interruption, and task cancellation race with each other.
private final class ReplyOnce<Value: Sendable>: PendingReply, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var settled: Result<Value, MonitorConnectionError>?

    @discardableResult
    func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        if let settled {
            lock.unlock()
            Self.resume(continuation, with: settled)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func succeed(_ value: Value) {
        settle(.success(value))
    }

    func fail(_ error: MonitorConnectionError) {
        settle(.failure(error))
    }

    var isSettled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return settled != nil
    }

    private func settle(_ result: Result<Value, MonitorConnectionError>) {
        lock.lock()
        if settled != nil {
            lock.unlock()
            return
        }
        settled = result
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        Self.resume(continuation, with: result)
    }

    private static func resume(_ continuation: CheckedContinuation<Value, Error>, with result: Result<Value, MonitorConnectionError>) {
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

/// Sendable exported object. NSXPC invokes these methods on its own queue;
/// each callback is forwarded to the main actor before touching host state.
final class MonitorClientAdapter: NSObject, MonitorClient, @unchecked Sendable {
    private let commitHandler: @Sendable (String, Int64) -> Void
    private let healthHandler: @Sendable (Data) -> Void

    init(
        commit: @escaping @Sendable (String, Int64) -> Void,
        health: @escaping @Sendable (Data) -> Void
    ) {
        self.commitHandler = commit
        self.healthHandler = health
        super.init()
    }

    nonisolated func databaseDidCommit(_ storeID: String, watermark: Int64) {
        commitHandler(storeID, watermark)
    }

    nonisolated func monitorHealthChanged(_ health: Data) {
        healthHandler(health)
    }
}

enum MonitorConnectionError: Error, LocalizedError, Sendable, Equatable {
    case notConnected
    case serviceUnavailable(Int32)
    case encoding
    case decoding
    case invalidReply
    case remote(String)
    case cursor
    case protocolVersion
    case invalidToken(Int32)
    case malformedToken
    case cancelled

    var errorCode: String {
        switch self {
        case .notConnected:
            return "notConnected"
        case .serviceUnavailable:
            return "service"
        case .encoding:
            return "encoding"
        case .decoding:
            return "decoding"
        case .invalidReply:
            return "reply"
        case .remote(let code):
            return code
        case .cursor:
            return "cursor"
        case .protocolVersion:
            return "version"
        case .invalidToken:
            return "token"
        case .malformedToken:
            return "token"
        case .cancelled:
            return "cancelled"
        }
    }

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "The Sidewatch monitor service is not connected.")
        case .serviceUnavailable(let code):
            if code == 0 {
                return String(localized: "The Sidewatch monitor service is unavailable.")
            }
            return String(localized: "The Sidewatch monitor service is unavailable (error \(Int(code))).")
        case .encoding:
            return String(localized: "The request could not be encoded.")
        case .decoding:
            return String(localized: "The monitor service reply could not be read.")
        case .invalidReply:
            return String(localized: "The monitor service returned an incomplete reply.")
        case .remote(let code):
            return String(localized: "The monitor service reported an error (\(code)).")
        case .cursor:
            return String(localized: "The activity history changed. Reload the history and try again.")
        case .protocolVersion:
            return String(localized: "The monitor service uses an unsupported protocol version.")
        case .invalidToken(let code):
            if code == 0 {
                return String(localized: "The process is no longer running.")
            }
            return String(localized: "The monitor couldn't verify this process (error \(Int(code))).")
        case .malformedToken:
            return String(localized: "The monitor service returned an invalid process token.")
        case .cancelled:
            return String(localized: "The monitor request was canceled.")
        }
    }
}
