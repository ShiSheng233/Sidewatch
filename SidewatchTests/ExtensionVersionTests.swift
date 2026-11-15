import XCTest

/// An older app must not replace a newer installed monitor.
final class ExtensionVersionTests: XCTestCase {
    func testOlderVersionOrBuildIsRecognized() {
        XCTAssertTrue(ExtensionManager.isOlder(version: "1.2", build: "40", than: "1.10", build: "1"))
        XCTAssertTrue(ExtensionManager.isOlder(version: "1.2", build: "9", than: "1.2", build: "10"))
        XCTAssertFalse(ExtensionManager.isOlder(version: "1.2.0", build: "10", than: "1.2", build: "10"))
        XCTAssertFalse(ExtensionManager.isOlder(version: "2.0", build: "1", than: "1.9", build: "99"))
    }
}
