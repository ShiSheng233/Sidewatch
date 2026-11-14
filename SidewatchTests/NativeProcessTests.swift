import Foundation
import Darwin
import XCTest

final class NativeProcessTests: XCTestCase {
    func testLinkLocalIPv6EndpointPreservesCanonicalAddressAndInterface() async throws {
        let scope = if_nametoindex("lo0")
        guard scope != 0 else { throw XCTSkip("Loopback interface is unavailable") }
        let descriptor = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_scope_id = scope
        XCTAssertEqual(inet_pton(AF_INET6, "fe80::1", &address.sin6_addr), 1)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        if result != 0 {
            let code = errno
            if code == EADDRNOTAVAIL || code == EAFNOSUPPORT { throw XCTSkip("Loopback IPv6 link-local address is unavailable") }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let queried = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard queried == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let port = UInt16(bigEndian: address.sin6_port)
        let snapshot = try await ProcessSnapshotService().snapshot()
        let endpoint = try XCTUnwrap(snapshot.endpoints.first {
            $0.execution.process.pid == getpid() && $0.transport == .udp &&
            $0.addressFamily == AF_INET6 && $0.port == port
        })
        XCTAssertEqual(endpoint.address, "fe80::1")
        XCTAssertEqual(endpoint.scopeID, scope)
    }
}
