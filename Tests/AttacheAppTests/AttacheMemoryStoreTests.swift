import XCTest
@testable import AttacheApp

final class AttacheMemoryStoreTests: XCTestCase {
    func testFreshMemoryFileIsCreatedWithRestrictivePermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-memory-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("AttacheMemory.md")
        let store = AttacheMemoryStore(environment: ["ATTACHE_MEMORY_FILE": fileURL.path])

        let snapshot = store.loadSnapshot()

        XCTAssertNil(snapshot.errorDescription)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testExistingMemoryFileIsHardenedBeforeLoad() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-memory-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("AttacheMemory.md")
        try "# Attaché Memory\n- Private preference\n".write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: fileURL.path
        )

        let snapshot = AttacheMemoryStore(
            environment: ["ATTACHE_MEMORY_FILE": fileURL.path]
        ).loadSnapshot()

        XCTAssertNil(snapshot.errorDescription)
        XCTAssertTrue(snapshot.rawText.contains("Private preference"))
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testMemorySymlinkIsRejectedWithoutReadingOrChangingTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-memory-symlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let targetURL = root.appendingPathComponent("outside-private.txt")
        let memoryURL = root.appendingPathComponent("AttacheMemory.md")
        try "SYMLINK_PRIVATE_MARKER".write(to: targetURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: targetURL.path)
        try FileManager.default.createSymbolicLink(at: memoryURL, withDestinationURL: targetURL)

        let snapshot = AttacheMemoryStore(
            environment: ["ATTACHE_MEMORY_FILE": memoryURL.path]
        ).loadSnapshot()

        XCTAssertNotNil(snapshot.errorDescription)
        XCTAssertFalse(snapshot.rawText.contains("SYMLINK_PRIVATE_MARKER"))
        let targetAttributes = try FileManager.default.attributesOfItem(atPath: targetURL.path)
        XCTAssertEqual(((targetAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o644)
        XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), "SYMLINK_PRIVATE_MARKER")
    }
}
