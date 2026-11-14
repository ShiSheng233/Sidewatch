import Foundation
import Darwin
import XCTest

final class ESClientStateTests: XCTestCase {
    func testPersistedProtectIsNotActiveBeforeESStarts() throws {
        let capture = CaptureRecord(id: "offline-state", bootID: try SystemIdentity.bootID(), startedAt: Date())
        let client = EndpointSecurityClient(capture: capture)
        defer { client.stop() }
        let uid = geteuid()
        let configuration = MonitorConfiguration(revision: 2, mode: .protect)
        client.restore(.init(executions: [], edges: [], sessions: [], associations: []),
                       configuration: configuration, userID: uid)
        let restored = client.health(userID: uid)
        XCTAssertNotEqual(restored.availability, .active)
        XCTAssertNil(restored.activeMode)
        XCTAssertNil(restored.activeRevision)

        XCTAssertThrowsError(try client.apply(.init(revision: 3, mode: .dryRun), userID: uid))
        let rejected = client.health(userID: uid)
        XCTAssertNotEqual(rejected.availability, .active)
        XCTAssertNil(rejected.activeMode)
        XCTAssertNil(rejected.activeRevision)
    }
}
