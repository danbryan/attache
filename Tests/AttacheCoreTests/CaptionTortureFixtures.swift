import Foundation

/// Deliberately hostile caption inputs (INF-364): long unbreakable tokens, full
/// URLs, checksums, identifiers, and multilingual/spaceless-script text. Used to
/// characterize `CaptionAlignmentBuilder`'s behavior against a fixed set of
/// invariants before and after the bounded oversized-token and sub-word-progress
/// fixes, and to audit multilingual caption segmentation.
enum CaptionTortureFixtures {
    struct Fixture {
        let name: String
        let text: String
    }

    /// A real sha256-length (64 hex character) checksum, embedded in a sentence
    /// the way an agent narration would actually surface one.
    static let hexChecksum = Fixture(
        name: "64-char hex checksum",
        text: "The build checksum is e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b85 and it matched."
    )

    /// A full https URL with a query string, another classically unbreakable
    /// caption token.
    static let fullURL = Fixture(
        name: "full https URL with query params",
        text: "See https://attache.fm/releases/download?version=0.4.0&channel=stable&arch=arm64 for the build."
    )

    /// A long camelCase identifier, the kind an agent reads back verbatim from a
    /// stack trace or log line.
    static let longIdentifier = Fixture(
        name: "long camelCase identifier",
        text: "The failure came from AttacheProductionRequestBrokerConfigurationValidationCoordinator during startup."
    )

    /// A long decimal number string (more digits than a normal spoken number).
    static let decimalNumber = Fixture(
        name: "long decimal number string",
        text: "Pi to fifty digits is 3.14159265358979323846264338327950288419716939937510 approximately."
    )

    /// An emoji sequence with no whitespace between glyphs.
    static let emojiSequence = Fixture(
        name: "emoji sequence",
        text: "Reaction burst incoming 🚀🔥💯😀🎉🧠🤖📈✅🔊🎯🛠️ from the team."
    )

    /// CJK text in Korean, one of the app's shipped localizations. Korean is
    /// normally written WITH spaces between words (eojeol), unlike Chinese and
    /// Japanese, so this is realistic Korean prose rather than an artificial
    /// spaceless run.
    static let cjkText = Fixture(
        name: "Korean text (ko localization)",
        text: "안녕하세요 저는 앱 개발자입니다 오늘은 날씨가 정말 좋습니다 내일 회의가 있어요"
    )

    /// Genuinely spaceless CJK text (Chinese), the script family the ticket's
    /// "words are not space-separated" audit case actually describes. Korean is
    /// a spaced language even without romanization, so this fixture is the one
    /// that exercises the spaceless-run segmenter end to end.
    static let spacelessCJKText = Fixture(
        name: "Chinese text, spaceless run",
        text: "我今天去了商店买了一些苹果和香蕉今天天气非常好我们决定去公园散步"
    )

    /// Spanish text with accented characters and inverted punctuation.
    static let spanishAccented = Fixture(
        name: "Spanish accented text",
        text: "El niño comió jalapeños en la habitación mientras tomaba café por la mañana."
    )

    /// English sentence with an embedded checksum, the mixed case Dan reported.
    static let mixedEnglishChecksum = Fixture(
        name: "mixed English plus checksum sentence",
        text: "The deploy hash is 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08 and it passed CI."
    )

    /// A single word longer than any caption line: no separators, no case
    /// boundaries, nothing for the existing technical-segment splitter to grab.
    static let wordLongerThanAnyCaptionLine = Fixture(
        name: "word longer than any caption line",
        text: "supercalifragilisticexpialidocioussupercalifragilisticexpialidocioussupercalifragilisticexpialidocious"
    )

    static let all: [Fixture] = [
        hexChecksum,
        fullURL,
        longIdentifier,
        decimalNumber,
        emojiSequence,
        cjkText,
        spacelessCJKText,
        spanishAccented,
        mixedEnglishChecksum,
        wordLongerThanAnyCaptionLine
    ]
}
