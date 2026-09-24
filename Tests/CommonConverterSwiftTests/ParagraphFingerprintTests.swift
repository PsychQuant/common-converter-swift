import XCTest
@testable import CommonConverterSwift

/// Characterization tests for `ParagraphFingerprint` (PsychQuant/macdoc#220,
/// moved here from two hand-duplicated copies in word-to-md-swift and
/// md-to-word-swift after a Codex cross-model review round caught them
/// drifting out of sync — see the type's doc comment, "Versioning" section).
///
/// These literal expected hex digests ARE the contract every consumer
/// relies on: word-to-md-swift's forward `MetadataCollector` writes a
/// fingerprint, and macdoc's `Tier3MetadataRestorer` recomputes one to
/// compare against it — they only agree if both sides resolve to the same
/// `CommonConverterSwift` version and that version's algorithm matches what
/// is pinned here. Any change to `ParagraphFingerprint.normalize` or the
/// hash algorithm that doesn't also update these vectors is a red flag,
/// caught by this file failing.
final class ParagraphFingerprintTests: XCTestCase {

    // MARK: - loose(_:) — shared literal test vectors

    func testLooseFingerprintOfPlainASCIIText() {
        XCTAssertEqual(ParagraphFingerprint.loose("Hello, world!"), "38d1334144987bf4")
    }

    func testLooseFingerprintCollapsesInteriorWhitespace() {
        XCTAssertEqual(ParagraphFingerprint.loose("café  naïve   text"), "f3e75da59db3cbf4")
    }

    func testLooseFingerprintTrimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(ParagraphFingerprint.loose("  leading and trailing space  "), "4fd2d393b0def7d6")
    }

    func testLooseFingerprintCollapsesNewlinesAndTabs() {
        XCTAssertEqual(ParagraphFingerprint.loose("line1\nline2\ttabbed"), "fa9bc3e805bb5524")
    }

    func testLooseFingerprintOfEmptyString() {
        XCTAssertEqual(ParagraphFingerprint.loose(""), "cbf29ce484222325")
    }

    func testLooseFingerprintOfSingleWord() {
        XCTAssertEqual(ParagraphFingerprint.loose("important"), "4f2844fb7985d8e5")
    }

    // MARK: - loose(_:) — typographic canonicalization (swift-markdown's
    // default "smart punctuation" — see ParagraphFingerprint's doc comment)

    func testLooseFingerprintCanonicalizesApostrophe() {
        XCTAssertEqual(ParagraphFingerprint.loose("This paragraph's real text."), "dea38bc387d1a018")
    }

    func testLooseFingerprintOfCurlyApostropheMatchesStraightApostrophe() {
        // U+2019 RIGHT SINGLE QUOTATION MARK — what swift-markdown produces
        // when it re-parses a straight apostrophe under its default "smart"
        // option set.
        XCTAssertEqual(
            ParagraphFingerprint.loose("This paragraph\u{2019}s real text."),
            "dea38bc387d1a018"
        )
    }

    func testLooseFingerprintCanonicalizesDashesAndEllipsisAndDoubleQuotes() {
        XCTAssertEqual(
            ParagraphFingerprint.loose("He said \"hello\" -- then left..."),
            "a00291c1039d1aab"
        )
    }

    func testLooseFingerprintOfFullyTypographicVariantMatchesASCIIVariant() {
        // U+201C/U+201D curly double quotes, U+2013 en dash, U+2026 ellipsis
        // — exactly what swift-markdown produces from the ASCII sequence
        // above under its default "smart" option set.
        XCTAssertEqual(
            ParagraphFingerprint.loose("He said \u{201C}hello\u{201D} \u{2013} then left\u{2026}"),
            "a00291c1039d1aab"
        )
    }

    // MARK: - loose(_:) — content-drift sensitivity (the actual purpose)

    func testLooseFingerprintDifferentTextProducesDifferentFingerprint() {
        XCTAssertNotEqual(
            ParagraphFingerprint.loose("First paragraph."),
            ParagraphFingerprint.loose("Second paragraph.")
        )
    }

    func testLooseFingerprintSameTextProducesSameFingerprintDeterministically() {
        let text = "Repeat this exact sentence."
        XCTAssertEqual(ParagraphFingerprint.loose(text), ParagraphFingerprint.loose(text))
    }

    func testLooseFingerprintInsertedWordChangesFingerprint() {
        // The scenario the "loose" fingerprint exists to catch: a paragraph
        // inserted earlier in a document must not look identical to the
        // original text at the same index.
        XCTAssertNotEqual(
            ParagraphFingerprint.loose("The quick fox jumps."),
            ParagraphFingerprint.loose("The quick brown fox jumps.")
        )
    }

    func testLooseFingerprintWhitespaceOnlyDifferenceProducesSameFingerprint() {
        XCTAssertEqual(
            ParagraphFingerprint.loose("Same   content"),
            ParagraphFingerprint.loose("Same content")
        )
        XCTAssertEqual(
            ParagraphFingerprint.loose("Trailing space "),
            ParagraphFingerprint.loose("Trailing space")
        )
    }

    // MARK: - exact(_:) — shared literal test vectors

    func testExactFingerprintSharedLiteralVectors() {
        XCTAssertEqual(ParagraphFingerprint.exact("Hello, world!"), "38d1334144987bf4")
        XCTAssertEqual(ParagraphFingerprint.exact("This paragraph's real text."), "dea38bc387d1a018")
        XCTAssertEqual(ParagraphFingerprint.exact("A  B"), "96396e8c37aad7ca")
        XCTAssertEqual(ParagraphFingerprint.exact("A B"), "fa95d919a0cae6d2")
        XCTAssertEqual(ParagraphFingerprint.exact("a---bc"), "733503084b18a8c2")
        XCTAssertEqual(ParagraphFingerprint.exact("a\u{2014}bc"), "ba79b701407cd4b5")
        XCTAssertEqual(ParagraphFingerprint.exact(""), "cbf29ce484222325")
    }

    // MARK: - exact(_:) vs loose(_:) — the documented divergence that
    // motivated splitting them into two functions in the first place
    // (PsychQuant/macdoc#220 — a Codex cross-model review round found that
    // a loose-fingerprint match alone is not safe evidence for offset-based
    // restoration)

    func testExactFingerprintDoesNotTolerateWhitespaceDifferences() {
        XCTAssertNotEqual(
            ParagraphFingerprint.exact("A  B"),
            ParagraphFingerprint.exact("A B")
        )
        // Sanity: the loose fingerprint DOES still consider them equal.
        XCTAssertEqual(
            ParagraphFingerprint.loose("A  B"),
            ParagraphFingerprint.loose("A B")
        )
    }

    func testExactFingerprintDoesNotTolerateTypographicSubstitution() {
        XCTAssertNotEqual(
            ParagraphFingerprint.exact("a---bc"),
            ParagraphFingerprint.exact("a\u{2014}bc")
        )
        XCTAssertEqual(
            ParagraphFingerprint.loose("a---bc"),
            ParagraphFingerprint.loose("a\u{2014}bc")
        )
    }

    func testExactFingerprintMatchesForByteIdenticalText() {
        let text = "Byte-identical text, unchanged."
        XCTAssertEqual(ParagraphFingerprint.exact(text), ParagraphFingerprint.exact(text))
    }
}
