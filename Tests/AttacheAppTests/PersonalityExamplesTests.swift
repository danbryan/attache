import XCTest

/// Guards the community personality gallery in examples/personalities so PR
/// contributions stay usable: the whole file is pasted into the app as a
/// prompt, so it must be plain non-empty text of reasonable length.
final class PersonalityExamplesTests: XCTestCase {
    private var galleryURL: URL {
        // Tests/AttacheAppTests/PersonalityExamplesTests.swift -> repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("examples/personalities")
    }

    func testGalleryPersonalitiesAreValidPrompts() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: galleryURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        XCTAssertGreaterThanOrEqual(files.count, 3, "gallery should keep its seed personalities")

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(trimmed.isEmpty, "\(file.lastPathComponent) is empty")
            XCTAssertLessThanOrEqual(trimmed.count, 2_000,
                                     "\(file.lastPathComponent) exceeds the 2,000 character cap")
            XCTAssertFalse(trimmed.contains("\r"), "\(file.lastPathComponent) has CRLF line endings")
        }
    }
}
