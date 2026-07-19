import Foundation
import XCTest
@testable import AttacheApp

final class DocumentationLinksTests: XCTestCase {
    func testEveryModelGuidePointsToAnExistingHeading() throws {
        let markdown = try String(contentsOf: repositoryRoot
            .appendingPathComponent("docs/model-integrations.md"))
        let anchors = Set(markdown
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.hasPrefix("## ") else { return nil }
                return githubAnchor(String(line.dropFirst(3)))
            })

        for guide in AttacheDocumentationLinks.ModelIntegrationGuide.allCases {
            XCTAssertTrue(anchors.contains(guide.rawValue), "Missing setup-guide heading #\(guide.rawValue)")
            let url = AttacheDocumentationLinks.modelIntegration(guide)
            XCTAssertEqual(url.path, "/danbryan/attache/blob/main/docs/model-integrations.md")
            XCTAssertEqual(url.fragment, guide.rawValue)
        }
    }

    func testCharacterArtworkLinksPointToExistingDocumentAndAnchor() throws {
        let document = repositoryRoot.appendingPathComponent("design/attache-animation-spec.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.path))
        let markdown = try String(contentsOf: document)
        XCTAssertTrue(markdown.contains("## Bring your own artwork"))
        XCTAssertEqual(AttacheDocumentationLinks.characterArtwork.path,
                       "/danbryan/attache/blob/main/design/attache-animation-spec.md")
        XCTAssertEqual(AttacheDocumentationLinks.customArtwork.fragment, "bring-your-own-artwork")
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func githubAnchor(_ heading: String) -> String {
        heading.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }
            .replacingOccurrences(of: " ", with: "-")
    }
}
