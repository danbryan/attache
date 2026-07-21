import AttacheCore
import XCTest
@testable import AttacheApp

/// The playback controller half of the forced-alignment pipeline: applying a
/// completed alignment upgrades the live timeline, caches the result next to the
/// audio, and a replay loads that cached exact timeline. Driven through the
/// internal `applyForcedAlignmentResult` seam so no real `AVAudioPlayer` (and
/// thus no real audio cache under Application Support) is touched.
@MainActor
final class ForcedAlignmentPipelineTests: XCTestCase {
    private func exactAlignment(text: String) -> CaptionAlignment {
        let result = ForcedAlignment.align(
            scriptText: text,
            recognized: [
                RecognizedWord(text: "one", startMs: 0, durationMs: 400),
                RecognizedWord(text: "two", startMs: 500, durationMs: 400),
                RecognizedWord(text: "three", startMs: 1000, durationMs: 400)
            ],
            totalDurationMs: 1500
        )
        XCTAssertTrue(result.accepted)
        return result.alignment
    }

    private func tempAudioURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("forced-align-\(UUID().uuidString).wav")
    }

    func testCompletedAlignmentUpgradesLiveTimelineAndCaches() {
        let controller = SpeechPlaybackController()
        let audioURL = tempAudioURL()
        defer { try? FileManager.default.removeItem(at: controller.alignmentSidecarURL(for: audioURL)) }
        let exact = exactAlignment(text: "one two three")

        // A freshly constructed controller has a nil generation; passing nil
        // matches it, standing in for "this clip is still active", so the live
        // timeline upgrades.
        controller.applyForcedAlignmentResult(exact, audioURL: audioURL, generation: nil)

        XCTAssertEqual(controller.currentAlignment?.provenance, .exactFromAlignment)
        // And it persisted a sidecar that reads back as the same exact alignment.
        let cached = controller.loadCachedAlignment(for: audioURL, text: "one two three")
        XCTAssertEqual(cached, exact)
    }

    func testLateCompletionForAnEndedClipStillCaches() {
        let controller = SpeechPlaybackController()
        let audioURL = tempAudioURL()
        defer { try? FileManager.default.removeItem(at: controller.alignmentSidecarURL(for: audioURL)) }
        let exact = exactAlignment(text: "one two three")

        // A different generation than the (nil) active one: the clip already
        // ended, so the live timeline must NOT change, but the result still caches
        // for the next replay.
        controller.applyForcedAlignmentResult(exact, audioURL: audioURL, generation: UUID())

        XCTAssertNil(controller.currentAlignment, "an ended clip's timeline must not be mutated")
        XCTAssertEqual(controller.loadCachedAlignment(for: audioURL, text: "one two three"), exact)
    }

    func testCacheRoundTripRejectsEstimatedOrMismatchedText() {
        let controller = SpeechPlaybackController()
        let audioURL = tempAudioURL()
        defer { try? FileManager.default.removeItem(at: controller.alignmentSidecarURL(for: audioURL)) }

        // An estimated alignment is never treated as an exact cached timeline.
        let estimated = CaptionAlignmentBuilder.fallback(text: "one two three", durationMs: 1500)
        controller.writeCachedAlignment(estimated, for: audioURL)
        XCTAssertNil(controller.loadCachedAlignment(for: audioURL, text: "one two three"))

        // An exact alignment for different text is not reused for this script.
        let exact = exactAlignment(text: "one two three")
        controller.writeCachedAlignment(exact, for: audioURL)
        XCTAssertNil(controller.loadCachedAlignment(for: audioURL, text: "totally different words"))
        XCTAssertEqual(controller.loadCachedAlignment(for: audioURL, text: "one two three"), exact)
    }

    func testSidecarIsWrittenUserOnly() throws {
        let controller = SpeechPlaybackController()
        let audioURL = tempAudioURL()
        let sidecar = controller.alignmentSidecarURL(for: audioURL)
        defer { try? FileManager.default.removeItem(at: sidecar) }

        controller.writeCachedAlignment(exactAlignment(text: "one two three"), for: audioURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: sidecar.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        XCTAssertEqual(permissions & 0o777, 0o600)
    }
}
