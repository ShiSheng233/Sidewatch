import Foundation
import Darwin
import OSLog

@main
struct MonitorMain {
    static func main() {
        umask(0o077)
        do {
            let capture = CaptureRecord(id: UUID().uuidString, bootID: try SystemIdentity.bootID(), startedAt: Date())
            if CommandLine.arguments.contains("--diagnose") {
                let client = EndpointSecurityClient(capture: capture)
                let health = client.start()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(health)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
                client.stop()
                exit(health.availability == .active ? 0 : 2)
            }
            guard geteuid() == 0 else {
                Diagnostics.lifecycle.error("System extension requires its system-managed root launch context")
                FileHandle.standardError.write(Data("Run the installed system extension, or use --diagnose to inspect Endpoint Security authorization.\n".utf8))
                exit(1)
            }
            let service = MonitorService(capture: capture)
            let sources = [SIGTERM, SIGINT].map { number -> any DispatchSourceSignal in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
                source.setEventHandler {
                    Task {
                        await service.shutdown()
                        exit(0)
                    }
                }
                source.resume()
                return source
            }
            Task { await service.start() }
            withExtendedLifetime((service, sources)) { dispatchMain() }
        } catch {
            Diagnostics.lifecycle.fault("Monitor bootstrap failed; code \((error as NSError).code, privacy: .public)")
            FileHandle.standardError.write(Data("The monitor could not initialize.\n".utf8))
            exit(1)
        }
    }
}
