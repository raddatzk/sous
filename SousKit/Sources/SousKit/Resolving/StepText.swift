import Foundation

// What a view needs of a step's text: plain runs and amounts to accent, and
// the spans an editor marks. Worked out by ``StepReferences``.

/// One piece of a step's text, so a view can render a resolved amount
/// differently from the words around it. SousKit only splits the text;
/// turning `.amount` into an accented run is the view's job.
public enum StepAmountSegment: Hashable, Sendable {
    /// Text with nothing resolved — printed as written.
    case text(String)
    /// An amount tied to an ingredient line, already scaled and formatted.
    case amount(String)
}

/// A span of a step's own text that a recipe's references tie to an
/// ingredient line — what the editor underlays so the writer can see what
/// the app understood of the sentence. Display only: nothing is ever
/// written into the text.
///
/// Ranges point into ``RecipeStep/text``, never into the whole instructions
/// text: the step is the unit references speak about, and whoever draws the
/// marks maps them back into its own buffer.
public struct StepTextMark: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// An amount phrase tied to an ingredient line — the same thing
        /// cook mode prints accented.
        case bound
        /// An amount the scanner read but could not tie to any line. It
        /// still scales with the serving count, just blindly.
        case loose
    }

    public let kind: Kind
    public let range: Range<String.Index>
    /// The ingredient line this span speaks about, where one is known.
    public let ingredientName: String?

    init(kind: Kind, range: Range<String.Index>, ingredientName: String?) {
        self.kind = kind
        self.range = range
        self.ingredientName = ingredientName
    }

    /// The same mark with any whitespace at either edge left out, or `nil`
    /// where nothing but whitespace was there.
    ///
    /// The scanner's spans are cut where the grammar ends, not where the ink
    /// does — "die Hälfte der Zwiebeln" hands back "Hälfte der ", trailing
    /// space and all. Underlining that space is a smudge, and accenting it
    /// shows nothing.
    func trimmed(in text: String) -> StepTextMark? {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, text[lower].isWhitespace { lower = text.index(after: lower) }
        while lower < upper, text[text.index(before: upper)].isWhitespace { upper = text.index(before: upper) }
        guard lower < upper else { return nil }
        return StepTextMark(kind: kind, range: lower..<upper, ingredientName: ingredientName)
    }
}

/// Whether an amount written in a step may move with the serving count.
enum StepAmountScaling {
    /// Two shapes never do: a size ("in 3 cm große Würfel", "Ø 26 cm") and
    /// an amount given per piece ("je ca. 90 g", "Bällchen, etwa 40 g
    /// schwer", "mit je 120 g Gewicht"). Doubling the servings does not
    /// double the dice or the form.
    static func scalesWithServings(_ unit: IngredientUnit, writtenRange: Range<String.Index>, in text: String) -> Bool {
        if unit == .centimeter { return false }
        // Looking past an approximation and a "mit" in between, the way
        // "je mit ¼ TL Salz" and "je ca. 90 g" are written.
        let before = text[..<writtenRange.lowerBound]
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .suffix(3)
            .map { $0.lowercased() }
            .filter { !approximationWords.contains($0) && $0 != "mit" }
        if before.suffix(2).contains(where: { perPieceLeadWords.contains($0) }) { return false }
        let after = text[writtenRange.upperBound...]
            .split(whereSeparator: { !$0.isLetter && $0 != "-" })
            .prefix(3)
            .map { $0.lowercased() }
        if after.contains(where: { perPieceTrailWords.contains($0) }) { return false }
        return true
    }

    private static let approximationWords: Set<String> = ["ca", "ca.", "etwa", "circa", "ungefähr", "rund", "gut", "knapp"]
    private static let perPieceLeadWords: Set<String> = ["je", "jeweils", "pro", "à"]
    private static let perPieceTrailWords: Set<String> = ["schwer", "gewicht", "durchmesser", "pro", "je"]
}
