import XCTest
@testable import AttacheCore

final class AttacheCharacterManifestTests: XCTestCase {
    private func neutralOnly() -> AttacheCharacterManifest {
        AttacheCharacterManifest(name: "Dan", frames: ["neutral": "frames/neutral.png"])
    }

    private func fiveFrame() -> AttacheCharacterManifest {
        AttacheCharacterManifest(name: "Dan", frames: [
            "neutral": "n.png",
            "blink": "b.png",
            "speaking": "s.png",
            "worried": "w.png",
            "error": "e.png",
        ])
    }

    // MARK: - Validation

    func testValidateRequiresNeutral() {
        let noNeutral = AttacheCharacterManifest(name: "X", frames: ["blink": "b.png"])
        XCTAssertThrowsError(try noNeutral.validate()) { error in
            XCTAssertEqual(error as? AttacheCharacterManifest.ValidationError, .missingNeutral)
        }
        XCTAssertNoThrow(try neutralOnly().validate())
    }

    // MARK: - Neutral-only pack (Tier 0)

    func testNeutralOnlyAlwaysReturnsNeutral() {
        let m = neutralOnly()
        let states: [AtlasFaceState] = [
            AtlasFaceState(),
            AtlasFaceState(mouthOpen: 1),
            AtlasFaceState(eyeOpenness: 0),
            AtlasFaceState(browWorry: 1),
            AtlasFaceState(dizzy: 1),
            AtlasFaceState(gazeX: 1, gazeY: -1),
        ]
        for s in states {
            XCTAssertEqual(AttacheCharacterAtlas.framePath(for: s, in: m), "frames/neutral.png")
        }
    }

    // MARK: - Five-frame selection

    func testExpressionSelection() {
        let m = fiveFrame()
        XCTAssertEqual(AttacheCharacterAtlas.framePath(for: AtlasFaceState(), in: m), "n.png")
        XCTAssertEqual(AttacheCharacterAtlas.framePath(for: AtlasFaceState(mouthOpen: 0.8), in: m), "s.png")
        XCTAssertEqual(AttacheCharacterAtlas.framePath(for: AtlasFaceState(eyeOpenness: 0.05), in: m), "b.png")
        XCTAssertEqual(AttacheCharacterAtlas.framePath(for: AtlasFaceState(browWorry: 0.9), in: m), "w.png")
        XCTAssertEqual(AttacheCharacterAtlas.framePath(for: AtlasFaceState(dizzy: 0.9), in: m), "e.png")
    }

    func testSelectionPriorityDizzyWinsOverEverything() {
        let m = fiveFrame()
        let s = AtlasFaceState(eyeOpenness: 0, mouthOpen: 1, browWorry: 1, dizzy: 1)
        XCTAssertEqual(AttacheCharacterAtlas.framePath(for: s, in: m), "e.png")
    }

    func testSelectionPriorityWorryBeatsBlinkAndMouth() {
        let m = fiveFrame()
        let s = AtlasFaceState(eyeOpenness: 0, mouthOpen: 1, browWorry: 0.9)
        XCTAssertEqual(AttacheCharacterAtlas.framePath(for: s, in: m), "w.png")
    }

    // MARK: - Missing-frame fallback (progressive)

    func testMissingFrameFallsBackToNeutral() {
        // neutral + speaking only: a blink state has no blink frame -> neutral.
        let m = AttacheCharacterManifest(name: "X", frames: ["neutral": "n.png", "speaking": "s.png"])
        XCTAssertEqual(AttacheCharacterAtlas.framePath(for: AtlasFaceState(eyeOpenness: 0), in: m), "n.png")
        XCTAssertEqual(AttacheCharacterAtlas.framePath(for: AtlasFaceState(mouthOpen: 0.9), in: m), "s.png")
        XCTAssertEqual(AttacheCharacterAtlas.framePath(for: AtlasFaceState(dizzy: 1), in: m), "n.png")
    }

    // MARK: - Visemes (Tier 3)

    func testNearestVisemeChosenByOpenness() {
        var m = fiveFrame()
        m.visemes = [
            .init(open: 0.0, path: "v0.png"),
            .init(open: 0.5, path: "v5.png"),
            .init(open: 1.0, path: "v10.png"),
        ]
        // mouthOpen above threshold prefers a viseme over the plain speaking frame.
        XCTAssertEqual(AttacheCharacterAtlas.framePath(for: AtlasFaceState(mouthOpen: 0.45), in: m), "v5.png")
        XCTAssertEqual(AttacheCharacterAtlas.framePath(for: AtlasFaceState(mouthOpen: 0.95), in: m), "v10.png")
    }

    // MARK: - Gaze (Tier 2)

    func testNearestGazeChosenAndDeadzonePrefersNeutral() {
        var m = neutralOnly()
        m.gaze = [
            .init(x: -1, y: 0, path: "left.png"),
            .init(x: 1, y: 0, path: "right.png"),
            .init(x: 0, y: -1, path: "up.png"),
        ]
        // Off-center gaze snaps to the nearest frame.
        XCTAssertEqual(AttacheCharacterAtlas.framePath(for: AtlasFaceState(gazeX: 0.9, gazeY: 0.1), in: m), "right.png")
        XCTAssertEqual(AttacheCharacterAtlas.framePath(for: AtlasFaceState(gazeX: -0.8, gazeY: 0), in: m), "left.png")
        // Near-center gaze stays neutral.
        XCTAssertEqual(AttacheCharacterAtlas.framePath(for: AtlasFaceState(gazeX: 0.1, gazeY: 0.05), in: m), "frames/neutral.png")
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        var m = fiveFrame()
        m.format = 2
        m.gaze = [.init(x: -1, y: 0, path: "l.png")]
        m.visemes = [.init(open: 0.5, path: "v.png")]
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(AttacheCharacterManifest.self, from: data)
        XCTAssertEqual(decoded, m)
    }

    func testDecodesEyesAndRoundTrips() throws {
        let json = """
        {"format":3,"name":"Dan","canvas":252,"safeArea":240,
         "frames":{"neutral":"frames/neutral.png"},
         "eyes":{"left":{"x":0.43,"y":0.48,"w":0.07,"h":0.024},
                 "right":{"x":0.59,"y":0.49,"w":0.07,"h":0.024},
                 "irisColor":[0.22,0.20,0.16]}}
        """
        let m = try JSONDecoder().decode(AttacheCharacterManifest.self, from: Data(json.utf8))
        let eyes = try XCTUnwrap(m.eyes)
        XCTAssertEqual(eyes.left.x, 0.43, accuracy: 1e-9)
        XCTAssertEqual(eyes.right.y, 0.49, accuracy: 1e-9)
        XCTAssertEqual(eyes.irisColor, [0.22, 0.20, 0.16])
        // Round-trips cleanly.
        let data = try JSONEncoder().encode(m)
        XCTAssertEqual(try JSONDecoder().decode(AttacheCharacterManifest.self, from: data), m)
        // A neutral-only manifest with eyes still validates.
        XCTAssertNoThrow(try m.validate())
    }

    func testDecodesMinimalJSON() throws {
        let json = """
        {"format":1,"name":"Dan","canvas":252,"safeArea":240,"frames":{"neutral":"frames/neutral.png"}}
        """
        let m = try JSONDecoder().decode(AttacheCharacterManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.name, "Dan")
        XCTAssertEqual(m.neutralPath, "frames/neutral.png")
        XCTAssertNoThrow(try m.validate())
    }
}
