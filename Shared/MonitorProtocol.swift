import Foundation

// XPC carries versioned Codable DTOs as Data; no database objects or arbitrary SQL.
@objc protocol MonitorRemote {
    func handshake(_ version: Int, withReply reply: @escaping (Data) -> Void)
    func snapshot(withReply reply: @escaping (Data) -> Void)
    func activities(_ query: Data, withReply reply: @escaping (Data) -> Void)
    func configure(_ configuration: Data, withReply reply: @escaping (Data) -> Void)
    func liveToken(_ execution: Data, withReply reply: @escaping (Data?, Int32) -> Void)
    func recordControl(_ action: Data, withReply reply: @escaping (Data) -> Void)
    func clearHistory(withReply reply: @escaping (Data) -> Void)
}

@objc protocol MonitorClient {
    func databaseDidCommit(_ storeID: String, watermark: Int64)
    func monitorHealthChanged(_ health: Data)
}
