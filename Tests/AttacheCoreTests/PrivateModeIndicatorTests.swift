import AttacheCore
import XCTest

/// Covers INF-356: the pure state and copy rules behind the incognito
/// identity indicators (crown band, PRIVATE chip, VoiceOver announcements).
final class PrivateModeIndicatorTests: XCTestCase {

    // MARK: - Indicator visibility is state-driven

    func testIndicatorsVisibleOnlyWhilePrivate() {
        XCTAssertTrue(PrivateModeIndicator.indicatorsVisible(isPrivateConversation: true))
        XCTAssertFalse(PrivateModeIndicator.indicatorsVisible(isPrivateConversation: false))
    }

    // MARK: - Chip tooltip reflects the active model's egress, not a static disclosure

    func testTooltipForLocalModel() {
        XCTAssertEqual(
            PrivateModeIndicator.chipTooltip(modelIsLocal: true),
            "Nothing leaves this Mac and no record is kept"
        )
    }

    func testTooltipForCloudModel() {
        XCTAssertEqual(
            PrivateModeIndicator.chipTooltip(modelIsLocal: false),
            "No record is kept on this Mac; the model provider still receives the conversation"
        )
    }

    func testLocalAndCloudTooltipsAreDistinct() {
        XCTAssertNotEqual(
            PrivateModeIndicator.chipTooltip(modelIsLocal: true),
            PrivateModeIndicator.chipTooltip(modelIsLocal: false)
        )
    }

    // MARK: - VoiceOver announcement copy

    func testAnnouncementCopyIsFixedAndDistinct() {
        XCTAssertEqual(PrivateModeIndicator.enteredAnnouncement, "Private call started, no record will be kept")
        XCTAssertEqual(PrivateModeIndicator.exitedAnnouncement, "Private call ended")
        XCTAssertNotEqual(PrivateModeIndicator.enteredAnnouncement, PrivateModeIndicator.exitedAnnouncement)
    }
}
