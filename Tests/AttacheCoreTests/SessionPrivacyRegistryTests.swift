import XCTest
@testable import AttacheCore

final class SessionPrivacyRegistryTests: XCTestCase {
    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-session-privacy-\(UUID().uuidString)", isDirectory: true)
    }

    func testFreshRegistryHasNoDisabledSessions() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = SessionPrivacyRegistry(fileURL: root.appendingPathComponent("SessionPrivacyRegistry.json"))
        XCTAssertFalse(registry.isRecordingDisabled(sessionID: "session-1"))
        XCTAssertTrue(registry.allDisabledSessionIDs.isEmpty)
    }

    func testSetAndClearRoundTripsThroughANewInstance() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("SessionPrivacyRegistry.json")

        var registry = SessionPrivacyRegistry(fileURL: fileURL)
        XCTAssertTrue(registry.setRecordingDisabled(sessionID: "session-1"))
        XCTAssertTrue(registry.isRecordingDisabled(sessionID: "session-1"))

        // A fresh instance loaded from the same file sees the persisted state.
        let reloaded = SessionPrivacyRegistry(fileURL: fileURL)
        XCTAssertTrue(reloaded.isRecordingDisabled(sessionID: "session-1"))
        XCTAssertFalse(reloaded.isRecordingDisabled(sessionID: "session-2"))

        var mutable = reloaded
        XCTAssertTrue(mutable.clearRecordingDisabled(sessionID: "session-1"))
        XCTAssertFalse(mutable.isRecordingDisabled(sessionID: "session-1"))

        let afterClear = SessionPrivacyRegistry(fileURL: fileURL)
        XCTAssertFalse(afterClear.isRecordingDisabled(sessionID: "session-1"), "toggling off must persist across reload")
    }

    func testSettingAlreadyDisabledSessionIsANoOp() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var registry = SessionPrivacyRegistry(fileURL: root.appendingPathComponent("SessionPrivacyRegistry.json"))
        XCTAssertTrue(registry.setRecordingDisabled(sessionID: "session-1"))
        XCTAssertTrue(registry.setRecordingDisabled(sessionID: "session-1"))
        XCTAssertEqual(registry.allDisabledSessionIDs, ["session-1"])
    }

    func testClearingUnknownSessionIsANoOp() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var registry = SessionPrivacyRegistry(fileURL: root.appendingPathComponent("SessionPrivacyRegistry.json"))
        XCTAssertTrue(registry.clearRecordingDisabled(sessionID: "never-disabled"))
        XCTAssertTrue(registry.allDisabledSessionIDs.isEmpty)
    }

    func testEmptySessionIDIsIgnored() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var registry = SessionPrivacyRegistry(fileURL: root.appendingPathComponent("SessionPrivacyRegistry.json"))
        XCTAssertTrue(registry.setRecordingDisabled(sessionID: ""))
        XCTAssertFalse(registry.isRecordingDisabled(sessionID: ""))
        XCTAssertTrue(registry.allDisabledSessionIDs.isEmpty)
    }

    func testFilePermissionsAre0600InA0700Directory() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("SessionPrivacyRegistry.json")
        var registry = SessionPrivacyRegistry(fileURL: fileURL)
        XCTAssertTrue(registry.setRecordingDisabled(sessionID: "session-1"))

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual(((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o700)
    }

    func testLegacyLooselyPermissionedFileIsHardenedOnLoad() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("SessionPrivacyRegistry.json")
        let json = """
        {"schemaVersion":1,"disabledSessionIDs":["legacy-session"]}
        """
        try json.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)

        let registry = SessionPrivacyRegistry(fileURL: fileURL)
        XCTAssertTrue(registry.isRecordingDisabled(sessionID: "legacy-session"))

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777, 0o600)
    }

    func testCorruptFileIsTreatedAsEmptyRegistry() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("SessionPrivacyRegistry.json")
        try "not valid json".write(to: fileURL, atomically: true, encoding: .utf8)

        let registry = SessionPrivacyRegistry(fileURL: fileURL)
        XCTAssertFalse(registry.isRecordingDisabled(sessionID: "anything"))
        XCTAssertTrue(registry.allDisabledSessionIDs.isEmpty)
    }
}
