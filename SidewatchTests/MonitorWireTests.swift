import Foundation
import XCTest

final class MonitorWireTests: XCTestCase {
    func testFailureEnvelopeDecodesAgainstAValueReply() throws {
        let data = MonitorWire.failure("History cursor expired.", code: "cursor")
        let envelope = try MonitorWire.decode(WireEnvelope<MonitorSnapshot>.self, from: data)

        XCTAssertNil(envelope.value)
        XCTAssertEqual(envelope.error, "History cursor expired.")
        XCTAssertEqual(envelope.errorCode, "cursor")
    }

    func testErrorWithoutCodeRemainsDistinguishable() throws {
        let data = Data(#"{"error":"Operation failed."}"#.utf8)
        let envelope = try MonitorWire.decode(WireEnvelope<EmptyReply>.self, from: data)

        XCTAssertNil(envelope.value)
        XCTAssertEqual(envelope.error, "Operation failed.")
        XCTAssertNil(envelope.errorCode)
    }

    func testSuccessEnvelopeCarriesValueAndNoError() throws {
        let data = MonitorWire.reply(EmptyReply())
        let envelope = try MonitorWire.decode(WireEnvelope<EmptyReply>.self, from: data)

        XCTAssertNotNil(envelope.value)
        XCTAssertNil(envelope.error)
        XCTAssertNil(envelope.errorCode)
    }

    func testMalformedEnvelopeCannotBeTreatedAsSuccess() {
        XCTAssertThrowsError(
            try MonitorWire.decode(WireEnvelope<MonitorSnapshot>.self, from: Data("not json".utf8))
        )
    }
}
