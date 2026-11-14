import Foundation

/// Keeps persistence and policy activation in the same per-user order across suspension points.
actor ConfigurationTransactions {
    private struct Tail {
        let ticket: UUID
        let task: Task<MonitorConfiguration, Error>
    }
    private var tails: [UInt32: Tail] = [:]

    func run(userID: UInt32, operation: @escaping @Sendable () async throws -> MonitorConfiguration) async throws -> MonitorConfiguration {
        let previous = tails[userID]?.task
        let ticket = UUID()
        let task = Task {
            if let previous { _ = await previous.result }
            return try await operation()
        }
        tails[userID] = Tail(ticket: ticket, task: task)
        do {
            let value = try await task.value
            finish(userID: userID, ticket: ticket)
            return value
        } catch {
            finish(userID: userID, ticket: ticket)
            throw error
        }
    }

    func drain() async {
        let pending = tails.values.map(\.task)
        for task in pending { _ = await task.result }
    }

    private func finish(userID: UInt32, ticket: UUID) {
        if tails[userID]?.ticket == ticket { tails.removeValue(forKey: userID) }
    }
}
