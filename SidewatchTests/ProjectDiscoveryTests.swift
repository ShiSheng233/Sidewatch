import XCTest

final class ProjectDiscoveryTests: XCTestCase {
    func testUnversionedDirectoryAndNewNestedRepositoryAreDiscovered() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalRoot = root.resolvingSymlinksInPath().path
        let canonicalNested = nested.resolvingSymlinksInPath().path
        XCTAssertEqual(ProjectResolver.resolve(nested.path)?.root, canonicalNested)
        XCTAssertNil(ProjectResolver.resolve(nested.path)?.gitDirectory)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertEqual(ProjectResolver.resolve(nested.path)?.root, canonicalRoot)
        try FileManager.default.createDirectory(at: nested.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertEqual(ProjectResolver.resolve(nested.path)?.root, canonicalNested)
        XCTAssertNotNil(ProjectResolver.resolve(nested.path)?.gitDirectory)
    }
}
