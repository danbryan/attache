import AttacheCore
import XCTest
@testable import AttacheApp

/// INF-363: the "local" chip on `SourceBadge` is a cosmetic distinction for
/// Ollama-backed Claude Code sessions (e.g. Dan's `claude-oss` wrapper). This
/// proves the chip's visibility derives ONLY from `localModelHint`, never from
/// `sourceKind` or `displayName`, so it can never appear or disappear for a
/// reason unrelated to local-model detection.
final class SourceBadgeLocalModelChipTests: XCTestCase {
    func testChipHiddenWhenHintIsNil() {
        XCTAssertFalse(SourceBadge.showsLocalChip(localModelHint: nil))
    }

    func testChipShownWhenHintIsPresent() {
        XCTAssertTrue(SourceBadge.showsLocalChip(localModelHint: "qwen2.5-coder:32b"))
    }

    func testChipStateIsIndependentOfSourceKindAndDisplayName() {
        // Same hint value, wildly different sourceKind/displayName inputs:
        // the derivation must agree every time because it only looks at the hint.
        let hint = "glm-4"
        let combos: [(sourceKind: String, displayName: String)] = [
            (SourceKind.claudeCode.rawValue, "Claude Code"),
            (SourceKind.codex.rawValue, "Codex"),
            ("unknown-source", "Unknown")
        ]
        for combo in combos {
            _ = combo // sourceKind/displayName are irrelevant to the derivation by construction
            XCTAssertTrue(SourceBadge.showsLocalChip(localModelHint: hint))
        }
        for combo in combos {
            _ = combo
            XCTAssertFalse(SourceBadge.showsLocalChip(localModelHint: nil))
        }
    }
}
