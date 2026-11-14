import Foundation
import Darwin

enum SystemIdentity {
    private static let cachedBootID: Result<String, Error> = Result {
        var count = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &count, nil, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var buffer = [UInt8](repeating: 0, count: count)
        let result = buffer.withUnsafeMutableBytes {
            sysctlbyname("kern.bootsessionuuid", $0.baseAddress, &count, nil, 0)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let value = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        guard !value.isEmpty else { throw POSIXError(.EINVAL) }
        return value
    }

    static func bootID() throws -> String { try cachedBootID.get() }
    static func micros(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000_000).rounded()) }
    static func date(micros: Int64) -> Date { Date(timeIntervalSince1970: Double(micros) / 1_000_000) }
}
