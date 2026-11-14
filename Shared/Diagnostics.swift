import OSLog

/// Operational diagnostics only. Never log commands, file paths, tokens,
/// protection matches, or individual Endpoint Security activity events.
enum Diagnostics {
    static let lifecycle = Logger(subsystem: MonitorWire.hostID, category: "lifecycle")
    static let connection = Logger(subsystem: MonitorWire.hostID, category: "connection")
    static let storage = Logger(subsystem: MonitorWire.hostID, category: "storage")
    static let endpointSecurity = Logger(subsystem: MonitorWire.hostID, category: "endpoint-security")
    static let interface = Logger(subsystem: MonitorWire.hostID, category: "interface")
}
