import AttacheCore
import XCTest
@testable import AttacheApp

/// Exercises the on-device aligner's wiring (mapping, confidence gate, and the
/// never-block contract) through its `recognizerOverride` seam, so these run
/// without depending on `SFSpeechRecognizer` being available in the environment.
final class SpeechForcedAlignerTests: XCTestCase {
    func testOverrideRecognitionProducesExactAlignment() {
        let aligner = SpeechForcedAligner.shared
        aligner.recognizerOverride = { _, completion in
            completion([
                RecognizedWord(text: "one", startMs: 0, durationMs: 400),
                RecognizedWord(text: "two", startMs: 500, durationMs: 400),
                RecognizedWord(text: "three", startMs: 1000, durationMs: 400)
            ])
        }
        defer { aligner.recognizerOverride = nil }

        let expectation = expectation(description: "alignment")
        var result: CaptionAlignment?
        aligner.align(audioURL: URL(fileURLWithPath: "/tmp/x.wav"), scriptText: "one two three", totalDurationMs: 1500) {
            result = $0
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(result?.provenance, .exactFromAlignment)
        XCTAssertEqual(result?.words.map(\.startMs), [0, 500, 1000])
    }

    func testLowConfidenceRecognitionIsRejected() {
        let aligner = SpeechForcedAligner.shared
        aligner.recognizerOverride = { _, completion in
            completion([
                RecognizedWord(text: "aaa", startMs: 0, durationMs: 400),
                RecognizedWord(text: "bbb", startMs: 500, durationMs: 400),
                RecognizedWord(text: "ccc", startMs: 1000, durationMs: 400)
            ])
        }
        defer { aligner.recognizerOverride = nil }

        let expectation = expectation(description: "rejected")
        var result: CaptionAlignment? = CaptionAlignmentBuilder.fallback(text: "x", durationMs: 1)
        aligner.align(audioURL: URL(fileURLWithPath: "/tmp/x.wav"), scriptText: "one two three", totalDurationMs: 1500) {
            result = $0
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertNil(result, "garbage recognition must not upgrade the timeline")
    }

    func testNilRecognitionYieldsNilAlignment() {
        let aligner = SpeechForcedAligner.shared
        aligner.recognizerOverride = { _, completion in completion(nil) }
        defer { aligner.recognizerOverride = nil }

        let expectation = expectation(description: "nil")
        var result: CaptionAlignment? = CaptionAlignmentBuilder.fallback(text: "x", durationMs: 1)
        aligner.align(audioURL: URL(fileURLWithPath: "/tmp/x.wav"), scriptText: "one two three", totalDurationMs: 1500) {
            result = $0
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertNil(result)
    }

    func testEmptyScriptShortCircuits() {
        let aligner = SpeechForcedAligner.shared
        var overrideCalled = false
        aligner.recognizerOverride = { _, completion in overrideCalled = true; completion(nil) }
        defer { aligner.recognizerOverride = nil }

        let expectation = expectation(description: "empty")
        aligner.align(audioURL: URL(fileURLWithPath: "/tmp/x.wav"), scriptText: "   ", totalDurationMs: 1500) { result in
            XCTAssertNil(result)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertFalse(overrideCalled, "an empty script never invokes recognition")
    }

    /// The align call must return control to the caller immediately; the
    /// completion arrives later. This is the aligner half of the never-block
    /// guarantee (the controller half is `ForcedAlignmentPipelineTests`).
    func testAlignDoesNotBlockOnASlowRecognizer() {
        let aligner = SpeechForcedAligner.shared
        aligner.recognizerOverride = { _, completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                completion([RecognizedWord(text: "hello", startMs: 0, durationMs: 300)])
            }
        }
        defer { aligner.recognizerOverride = nil }

        let completed = expectation(description: "completed later")
        let before = Date()
        aligner.align(audioURL: URL(fileURLWithPath: "/tmp/x.wav"), scriptText: "hello", totalDurationMs: 400) { _ in
            completed.fulfill()
        }
        // The call returned effectively instantly, well before the 0.4s delay.
        XCTAssertLessThan(Date().timeIntervalSince(before), 0.2)
        wait(for: [completed], timeout: 2)
    }
}
