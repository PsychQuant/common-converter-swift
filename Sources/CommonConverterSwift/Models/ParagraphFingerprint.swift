import Foundation

/// Deterministic, cross-process-stable content fingerprint of a paragraph's
/// visible run text — the shared primitive behind Tier 3 metadata-sidecar
/// paragraph-misalignment detection and per-run offset-safety verification
/// (PsychQuant/macdoc#220).
///
/// ## Why this lives in `CommonConverterSwift`
///
/// Two independent packages need to compute and compare this fingerprint
/// against each other's output: `word-to-md-swift`'s `MetadataCollector`
/// (forward: docx → markdown + `.meta.yaml` sidecar) writes it, and
/// `md-to-word-swift`'s `Tier3MetadataRestorer` (reverse: markdown +
/// sidecar → docx) recomputes it to verify a sidecar entry still applies.
/// Before this package existed, each side carried its own hand-duplicated
/// copy of the same algorithm — which drifted out of sync in practice (see
/// PsychQuant/macdoc#220's implementation history: a Codex cross-model
/// review round caught a real divergence between the two copies). Both
/// packages already depend on `CommonConverterSwift` (this package) as
/// their Layer 2 protocol/model dependency, so hosting the single
/// implementation here — instead of a third option like a new
/// fingerprint-only package — adds no new dependency edge to either
/// consumer.
///
/// ## Two fingerprints, two different guarantees — do not conflate them
///
/// `loose(_:)` and `exact(_:)` serve different purposes and are meant to be
/// stored as two separate sidecar fields by callers (in word-to-md-swift's
/// schema: `ParagraphMeta.textFingerprint` / `.exactTextFingerprint`):
///
/// - `loose(_:)` tolerates markdown-round-trip noise (whitespace
///   collapsing, typographic canonicalization — see below) — appropriate
///   for "is this still roughly the same paragraph" misalignment detection,
///   which gates paragraph-*level* fields (alignment/spacing/etc., none of
///   which depend on character or scalar offsets).
/// - `exact(_:)` requires byte-for-byte identical text. This is the ONLY
///   fingerprint safe to gate per-run, offset-based restoration on (e.g. a
///   sidecar's `RunMeta.range`, defined as a `[start, end)` pair of Unicode
///   **scalar** offsets — not `Character`/grapheme-cluster offsets, which
///   are not additive across a run boundary when a combining-character
///   sequence spans it): `loose(_:)`'s normalization steps are
///   length-changing (e.g. `"  "` → `" "`, or `"---"` (3 chars) ↔ `"—"`
///   (1 char)), so two texts can share a loose match while having different
///   lengths or character positions — silently invalidating, or worse
///   shifting, offsets captured against the *other* text onto the wrong
///   characters. Concretely: original text `"a---bc"` with an offset range
///   of `[4, 5)` (targeting `"b"`) round-trips through markdown to `"a—bc"`
///   (smart-punctuation substitution, unrelated to any real edit); the
///   loose fingerprint of both strings is identical, but `[4, 5)` against
///   `"a—bc"` (length 4) is out of bounds — or, with more trailing text,
///   could land on a *different* character than `"b"` entirely, silently
///   formatting the wrong text. `exact(_:)` closes that gap.
///
/// ## Normalization (`loose(_:)` only — `exact(_:)` applies none of it)
///
/// 1. Unicode NFC normalize (`precomposedStringWithCanonicalMapping`).
/// 2. **Typographic canonicalization**: fold "smart punctuation" variants
///    down to their plain-ASCII equivalents — curly single/double quotes to
///    `'`/`"`, en dash (U+2013) to `--`, em dash (U+2014) to `---`,
///    horizontal ellipsis (U+2026) to `...`. This step exists because
///    swift-markdown's `Document(parsing:)` (as used by `md-to-word-swift`'s
///    `MarkdownToWordConverter`, no `.disableSmartOpts` passed) enables
///    cmark's "smart" option set by default: parsing markdown containing a
///    literal straight apostrophe/quote, or an ASCII `--`/`---`/`...`
///    sequence, silently rewrites it to the corresponding Unicode
///    typographic character. Without folding both forms to the same
///    canonical ASCII representation, `loose(_:)` would mismatch on nearly
///    every ordinary paragraph containing a contraction or possessive —
///    verified empirically by round-tripping `"This paragraph's real
///    text."` through `MarkdownToWordConverter.convertMarkdown` and
///    observing the straight `'` come back as U+2019.
///    - **Residual, documented gap**: this canonicalization is
///      intentionally lossy — a paragraph that genuinely started with a
///      literal Unicode em dash will now fingerprint identically to one
///      that started with literal `---`. That is an accepted trade-off
///      (misalignment detection needs to tolerate this one parser
///      behavior; distinguishing those two literal inputs is not a goal).
///      Other smart-punctuation-adjacent substitutions cmark may perform in
///      less common contexts are not separately inventoried here; if a
///      future false-mismatch is traced to one, extend this list (and its
///      test vectors — see "Versioning" below) accordingly rather than
///      special-casing it downstream.
/// 3. Collapse every run of Unicode whitespace/newline characters to a
///    single ASCII space.
/// 4. Trim leading/trailing whitespace.
/// 5. Hash the normalized text with FNV-1a (64-bit), rendered as 16
///    lowercase hex digits.
///
/// `exact(_:)` skips all five steps above except the final hash — it
/// hashes the input `runsText` completely unmodified.
///
/// ## What text callers should pass
///
/// Both functions take an already-concatenated `String` — callers own the
/// decision of what text that is (e.g. `paragraph.runs.map(\.text).joined()`
/// for a top-level-runs-only scope, matching `RunMeta.range`'s existing
/// scope in word-to-md-swift's schema: hyperlink/footnote/SDT text is
/// deliberately excluded). This type has no dependency on any specific
/// document model and does not impose a scope itself.
///
/// ## Hash collisions
///
/// FNV-1a 64-bit is not a cryptographic hash and is not injective: two
/// different texts could, in principle, hash to the same digest. A match on
/// either function is therefore strong practical evidence of equality (over
/// the relevant text universe, a 64-bit digest makes an accidental
/// collision astronomically unlikely), not a mathematical proof. This is an
/// acceptable trade-off for a misalignment/offset-safety check — not a
/// security boundary.
///
/// ## Versioning (CRITICAL for consumers)
///
/// This is a **shared cross-repo contract**: a fingerprint written by one
/// package's copy of `word-to-md-swift` (or any other future producer) MUST
/// be reproducible by every consumer's `CommonConverterSwift` dependency.
/// Any change to the normalization rule, the typographic-canonicalization
/// table, or the hash algorithm/constants is a **breaking change** to this
/// type's contract (even though it may not change the Swift API signature)
/// and MUST ship as a new major version of `CommonConverterSwift`, with the
/// literal test vectors in `ParagraphFingerprintTests.swift` updated in the
/// same release. Consumers pin an exact-enough lower bound specifically so
/// a silent algorithm change can never reach them without an explicit
/// version bump on their side.
public enum ParagraphFingerprint: Sendable {
    /// Unicode "smart punctuation" scalar → canonical ASCII replacement.
    /// See the type's doc comment for why each entry exists.
    private static let typographicCanonicalization: [Unicode.Scalar: String] = [
        "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{201B}": "'", // single quote family
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{201F}": "\"", // double quote family
        "\u{2013}": "--",   // en dash
        "\u{2014}": "---",  // em dash
        "\u{2026}": "...",  // horizontal ellipsis
    ]

    /// The "loose" fingerprint: tolerant of whitespace-collapsing and
    /// typographic-canonicalization noise. Appropriate for "is this
    /// roughly the same paragraph" misalignment detection — NOT sufficient
    /// on its own for validating that offset-based restoration (e.g. a
    /// `RunMeta.range`-style scalar offset pair) is still safe to apply.
    /// See `exact(_:)` for that.
    public static func loose(_ text: String) -> String {
        fnv1a64Hex(normalize(text))
    }

    /// The "exact" fingerprint: hashes `text` with NO normalization at all
    /// (not NFC, not whitespace collapsing, not typographic
    /// canonicalization). A match is strong practical evidence (see "Hash
    /// collisions" above) that two texts are scalar-for-scalar identical —
    /// the guarantee offset-based restoration needs.
    public static func exact(_ text: String) -> String {
        fnv1a64Hex(text)
    }

    /// Exposed for callers' own characterization tests that want to assert
    /// against the normalized text directly, not just the final hash.
    public static func normalize(_ text: String) -> String {
        let nfc = text.precomposedStringWithCanonicalMapping
        var result = ""
        result.reserveCapacity(nfc.count)
        var lastWasWhitespace = false
        for scalar in nfc.unicodeScalars {
            if let replacement = typographicCanonicalization[scalar] {
                result += replacement
                lastWasWhitespace = false
                continue
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasWhitespace {
                    result.unicodeScalars.append(" ")
                }
                lastWasWhitespace = true
            } else {
                result.unicodeScalars.append(scalar)
                lastWasWhitespace = false
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// FNV-1a 64-bit — chosen over a cryptographic hash because this is a
    /// content-drift/offset-safety equality check, not a security boundary:
    /// no import beyond Foundation, fully deterministic across
    /// processes/platforms (unlike Swift's `Hasher`, which is
    /// per-process-salted and unsuitable for a value written to a durable
    /// file and read back elsewhere).
    private static func fnv1a64Hex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%016llx", hash)
    }
}
