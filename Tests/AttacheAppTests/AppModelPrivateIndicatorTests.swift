import AppKit
import AttacheCore
import XCTest
@testable import AttacheApp

/// Covers INF-356: the state that drives the crown band / PRIVATE chip
/// indicators (`AppModel.isPrivateConversation`) publishes correctly for
/// private and non-private (saved) calls, and the tooltip selection follows
/// the active presentation model's egress classification.
@MainActor
final class AppModelPrivateIndicatorTests: XCTestCase {
    func testIndicatorStateIsFalseWithNoActiveCall() throws {
        _ = NSApplication.shared
        let model = AppModel(store: try CardStore.inMemory())

        XCTAssertFalse(model.isPrivateConversation)
        XCTAssertFalse(PrivateModeIndicator.indicatorsVisible(isPrivateConversation: model.isPrivateConversation))
    }

    func testIndicatorStateIsTrueForAPrivateCall() throws {
        _ = NSApplication.shared
        let model = AppModel(store: try CardStore.inMemory())

        model.startConversation(storageMode: .privateCall)
        defer { model.endConversation() }

        XCTAssertTrue(model.isPrivateConversation)
        XCTAssertTrue(PrivateModeIndicator.indicatorsVisible(isPrivateConversation: model.isPrivateConversation))
    }

    func testIndicatorStateIsFalseForASavedCall() throws {
        _ = NSApplication.shared
        let model = AppModel(store: try CardStore.inMemory())

        model.startConversation(storageMode: .saved)
        defer { model.endConversation() }

        XCTAssertFalse(model.isPrivateConversation)
        XCTAssertFalse(PrivateModeIndicator.indicatorsVisible(isPrivateConversation: model.isPrivateConversation))
    }

    func testIndicatorStateClearsAfterHangUp() throws {
        _ = NSApplication.shared
        let model = AppModel(store: try CardStore.inMemory())

        model.startConversation(storageMode: .privateCall)
        XCTAssertTrue(model.isPrivateConversation)
        model.endConversation()

        XCTAssertFalse(model.isPrivateConversation)
    }

    func testIndicatorStateTracksMidCallConversion() throws {
        _ = NSApplication.shared
        let model = AppModel(store: try CardStore.inMemory())

        model.startConversation(storageMode: .saved)
        defer { model.endConversation() }
        XCTAssertFalse(model.isPrivateConversation)

        XCTAssertTrue(model.convertActiveCallToPrivate())
        XCTAssertTrue(model.isPrivateConversation)
        XCTAssertTrue(PrivateModeIndicator.indicatorsVisible(isPrivateConversation: model.isPrivateConversation))
    }

    // MARK: - Chip tooltip follows the active model's egress, not a static string

    func testChipTooltipForDefaultLocalPresentationModel() throws {
        _ = NSApplication.shared
        let model = AppModel(store: try CardStore.inMemory())
        // .ollama with no configured remote endpoint resolves to loopback,
        // which is not a remote service (AttacheDataEgress.isRemoteService).
        model.presentationProvider = .ollama

        let tooltip = PrivateModeIndicator.chipTooltip(modelIsLocal: !model.presentationSendsToCloud)
        XCTAssertEqual(tooltip, "Nothing leaves this Mac and no record is kept")
    }

    func testChipTooltipForACloudPresentationModel() throws {
        _ = NSApplication.shared
        let model = AppModel(store: try CardStore.inMemory())
        // .xai is a hosted provider (AttacheDataEgressClassifier.hostedProviderRawValues).
        model.presentationProvider = .xai

        let tooltip = PrivateModeIndicator.chipTooltip(modelIsLocal: !model.presentationSendsToCloud)
        XCTAssertEqual(tooltip, "No record is kept on this Mac; the model provider still receives the conversation")
    }
}
