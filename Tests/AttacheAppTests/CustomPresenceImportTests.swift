import AppKit
import XCTest
@testable import AttacheApp

final class CustomPresenceImportTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-import-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func writePNG(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    /// Build a source package directory with the given manifest JSON and a valid
    /// neutral frame (unless `skipNeutralImage`).
    private func makeSource(name: String, manifestJSON: String, skipNeutralImage: Bool = false) throws -> URL {
        let pkg = tempRoot.appendingPathComponent("\(name).attache-character", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try manifestJSON.data(using: .utf8)!.write(to: pkg.appendingPathComponent("manifest.json"))
        if !skipNeutralImage {
            try writePNG(pkg.appendingPathComponent("frames/neutral.png"))
        }
        return pkg
    }

    private func dest() -> URL { tempRoot.appendingPathComponent("Characters", isDirectory: true) }

    private let validManifest = """
    {"format":3,"name":"Test Face","canvas":252,"safeArea":240,
     "frames":{"neutral":"frames/neutral.png"}}
    """

    func testValidImportCopiesManifestAndFrame() throws {
        let source = try makeSource(name: "Test Face", manifestJSON: validManifest)
        let ref = try AttacheCustomPresenceStore.importPackage(from: source, into: dest())
        XCTAssertEqual(ref, "Test Face.attache-character")
        let copied = dest().appendingPathComponent(ref)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.appendingPathComponent("frames/neutral.png").path))
        // The copied package loads back as drawable artwork.
        XCTAssertNotNil(AttacheCustomPresenceStore.load(copied))
    }

    func testMissingManifestThrows() throws {
        let empty = tempRoot.appendingPathComponent("Empty.attache-character", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try AttacheCustomPresenceStore.importPackage(from: empty, into: dest())) { error in
            XCTAssertEqual(error as? AttacheCustomPresenceStore.ImportError, .invalidManifest)
        }
    }

    func testUnreadableNeutralFrameThrowsAndCopiesNothing() throws {
        let source = try makeSource(name: "NoImage", manifestJSON: validManifest, skipNeutralImage: true)
        XCTAssertThrowsError(try AttacheCustomPresenceStore.importPackage(from: source, into: dest()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest().path),
                       "a failed import must not leave a partial package behind")
    }

    func testPathTraversalFrameIsRejected() throws {
        let evil = """
        {"format":3,"name":"Evil","canvas":252,"safeArea":240,
         "frames":{"neutral":"frames/neutral.png","x":"../../escape.png"}}
        """
        let source = try makeSource(name: "Evil", manifestJSON: evil)
        XCTAssertThrowsError(try AttacheCustomPresenceStore.importPackage(from: source, into: dest())) { error in
            guard let e = error as? AttacheCustomPresenceStore.ImportError, case .unsafePath = e else {
                return XCTFail("expected unsafePath, got \(error)")
            }
        }
    }

    func testNameCollisionGetsSuffix() throws {
        let source = try makeSource(name: "Dup", manifestJSON:
            #"{"format":3,"name":"Dup","canvas":252,"safeArea":240,"frames":{"neutral":"frames/neutral.png"}}"#)
        let first = try AttacheCustomPresenceStore.importPackage(from: source, into: dest())
        let second = try AttacheCustomPresenceStore.importPackage(from: source, into: dest())
        XCTAssertEqual(first, "Dup.attache-character")
        XCTAssertEqual(second, "Dup 2.attache-character")
    }

    func testSafeDirectoryNameStripsSeparatorsAndTraversal() {
        XCTAssertEqual(AttacheCustomPresenceStore.safeDirectoryName("../../etc/passwd"), "etcpasswd")
        XCTAssertEqual(AttacheCustomPresenceStore.safeDirectoryName("A/B"), "AB")
        XCTAssertEqual(AttacheCustomPresenceStore.safeDirectoryName("   "), "Imported")
        XCTAssertEqual(AttacheCustomPresenceStore.safeDirectoryName("Good Name-1_2"), "Good Name-1_2")
    }
}
