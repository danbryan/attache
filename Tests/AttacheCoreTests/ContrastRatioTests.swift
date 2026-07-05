import XCTest
@testable import AttacheCore

final class ContrastRatioTests: XCTestCase {
    func testBlackOnWhiteIsMaximal() {
        let ratio = WCAGContrast.ratio(red1: 0, green1: 0, blue1: 0,
                                       red2: 1, green2: 1, blue2: 1)
        XCTAssertEqual(ratio, 21.0, accuracy: 0.01)
    }

    func testIdenticalColorsAreMinimal() {
        let ratio = WCAGContrast.ratio(red1: 0.5, green1: 0.5, blue1: 0.5,
                                       red2: 0.5, green2: 0.5, blue2: 0.5)
        XCTAssertEqual(ratio, 1.0, accuracy: 0.001)
    }

    func testRatioIsSymmetric() {
        let forward = WCAGContrast.ratio(red1: 0.98, green1: 0.26, blue1: 0.66,
                                         red2: 0, green2: 0, blue2: 0)
        let backward = WCAGContrast.ratio(red1: 0, green1: 0, blue1: 0,
                                          red2: 0.98, green2: 0.26, blue2: 0.66)
        XCTAssertEqual(forward, backward, accuracy: 0.0001)
    }

    func testKnownMidGreyPassesBothPlates() {
        // #767676 is the classic dual-plate grey: ~4.5 on both black and white.
        let grey = 118.0 / 255.0
        let onWhite = WCAGContrast.ratio(red1: grey, green1: grey, blue1: grey,
                                         red2: 1, green2: 1, blue2: 1)
        let onBlack = WCAGContrast.ratio(red1: grey, green1: grey, blue1: grey,
                                         red2: 0, green2: 0, blue2: 0)
        XCTAssertGreaterThan(onWhite, 4.4)
        XCTAssertGreaterThan(onBlack, 4.4)
    }
}
