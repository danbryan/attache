import AttacheCore
import Foundation
import XCTest
@testable import AttacheApp

final class AttacheContextGateTests: XCTestCase {
    func testProductionProbeCoversEveryRoleAcrossHTTPAndSafeCLITransport() throws {
        let directory = temporaryDirectory("probe-inventory")
        defer { try? FileManager.default.removeItem(at: directory) }

        try AttacheContextProductionProbe.generate(at: directory)
        try AttacheContextProductionProbe.verify(at: directory)

        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            ) as? [String: Any]
        )
        let entries = try XCTUnwrap(manifest["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, AttacheRequestRole.allCases.count * 2)
        for transport in ["http", "claude_cli"] {
            XCTAssertEqual(
                Set(entries.compactMap {
                    ($0["transport"] as? String) == transport ? $0["role"] as? String : nil
                }),
                Set(AttacheRequestRole.allCases.map(\.rawValue))
            )
        }
        XCTAssertFalse(entries.contains { ($0["transport"] as? String) == "codex_cli" })
    }

    func testDeliberateSerializedPayloadMutationMakesProbeFailClosed() throws {
        let directory = temporaryDirectory("probe-mutation")
        defer { try? FileManager.default.removeItem(at: directory) }
        try AttacheContextProductionProbe.generate(at: directory)

        let target = directory.appendingPathComponent("http/conversation.json")
        var payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any]
        )
        payload["model"] = "mutated-model-that-was-not-compiled"
        try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ).write(to: target, options: .atomic)

        XCTAssertThrowsError(try AttacheContextProductionProbe.verify(at: directory))
    }

    func testProductionPublishesOverflowAndExhaustiveReviewStateFromAppModel() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/AttacheApp/AppModel.swift"
        ))
        XCTAssertTrue(
            source.range(of: #"\.presentOverflowRecovery\s*\("#, options: .regularExpression) != nil,
            "AppModel must publish typed compiler overflow into the real recovery UI. A smoke-only fixture is not production wiring."
        )
        XCTAssertTrue(
            source.range(of: #"\.presentExhaustiveReview\s*\("#, options: .regularExpression) != nil,
            "AppModel must publish a real focused-session exhaustive review preview. A smoke-only fixture is not production wiring."
        )
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("attache-context-gate-\(suffix)-\(UUID().uuidString)")
    }
}
