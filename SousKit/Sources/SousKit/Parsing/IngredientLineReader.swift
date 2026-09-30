import Foundation
import Synchronization

/// Reads an ingredient list in the fixed form, and nothing else.
///
/// The fixed form is the line principle written down as grammar:
///
///     [amount] [size] [unit] name[, annotation]
///
/// - The amount is a number ("300", "1,5", "0.5"), a simple fraction ("1/2",
///   "½"), a mixed number ("1 1/2", "1 ½") or a range ("10-15", read as its
///   lower bound).
/// - A size word ("kleine", "große") belongs to the amount.
/// - The unit is any spelling from ``IngredientUnit``.
/// - The name is a writing the catalog knows exactly — the bundled words and
///   the household's own — or a recipe link. Nothing is guessed: no
///   qualifier turned round, no preparation word taken off the front.
/// - Everything after the comma that follows the name is the annotation.
///   It never becomes part of the name. A state word at its start
///   ("gekocht", "TK") still picks the basis, as it always did.
///
/// A line outside the form is not understood, and says so: it keeps its
/// words as written, its amount is still read so the line scales with the
/// recipe, and ``RecipeIngredient/isOutsideForm`` marks it for the
/// optimization. It gets no nutrition.
///
/// The fixed form is a subset of what ``IngredientParser`` reads, so a
/// household member on an older app reads a migrated line the same way.
public enum IngredientLineReader {
    // MARK: - The household's catalog

    private static let household = Mutex<IngredientCatalog>(.bundled)

    /// The catalog a recipe's lines are read against when nobody passes one:
    /// the bundled words plus the household's own, as
    /// ``IngredientCatalogLibrary`` last built them.
    ///
    /// Whether a line is in the form depends on which names are known, and
    /// `Recipe.ingredients` is asked from everywhere — a detail view, a
    /// background nutrition pass, the shopping list — none of which carries
    /// the catalog along.
    public static var catalog: IngredientCatalog {
        get { household.withLock { $0 } }
        set { household.withLock { $0 = newValue } }
    }

    // MARK: - Lists

    /// Reads a whole list, one ingredient per line, with the groups its
    /// headings open. The n-th ingredient is the n-th of
    /// ``writtenLines(in:)``.
    public static func read(_ text: String, catalog: IngredientCatalog? = nil) -> [RecipeIngredient] {
        let catalog = catalog ?? Self.catalog
        var result: [RecipeIngredient] = []
        for written in writtenLines(in: text) {
            var ingredient = readLine(written.text, catalog: catalog)
            ingredient.id = StableID.make(namespace: "ingredient", index: result.count, content: written.text)
            ingredient.group = written.group
            result.append(ingredient)
        }
        return result
    }

    /// A list's ingredient lines as written, trimmed, each with its group
    /// and where it stands in the text — the very lines ``read(_:catalog:)``
    /// reads, in the same order. For whoever has to change a line in place
    /// and leave the rest of the text as it was typed.
    ///
    /// A line that carries no amount and ends in a colon, or starts with a
    /// markdown heading, opens a group. A blank line after a group's lines
    /// closes it: what follows belongs to no group, the way "Vegane Butter"
    /// set apart under the filling is for the pan and not for the filling.
    public static func writtenLines(in text: String) -> [(text: String, group: String?, textLine: Int)] {
        var result: [(text: String, group: String?, textLine: Int)] = []
        var currentGroup: String?
        // A blank line straight under the heading is layout, not the end
        // of a group that has not had a line yet.
        var groupHasLines = false

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                if groupHasLines { currentGroup = nil }
                continue
            }
            if let heading = groupHeading(in: line) {
                currentGroup = heading
                groupHasLines = false
                continue
            }
            groupHasLines = currentGroup != nil
            result.append((line, currentGroup, index))
        }
        return result
    }

    /// Whether `line` opens a group rather than naming an ingredient.
    public static func isGroupHeading(_ line: String) -> Bool {
        groupHeading(in: line.trimmingCharacters(in: .whitespaces)) != nil
    }

    /// A group heading: "Für den Teig:" or "# Für den Teig".
    private static func groupHeading(in line: String) -> String? {
        if line.hasPrefix("#") {
            let heading = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            return heading.isEmpty ? nil : heading
        }
        guard line.hasSuffix(":") else { return nil }
        let heading = String(line.dropLast()).trimmingCharacters(in: .whitespaces)
        // "300 g Tomaten:" is a strange line, but it is not a heading.
        guard !heading.isEmpty, leadingAmount(in: Substring(heading)) == nil else { return nil }
        return heading
    }

    // MARK: - One line

    /// Reads one line. Never fails: a line outside the form comes back with
    /// its words as the name and ``RecipeIngredient/isOutsideForm`` set.
    public static func readLine(_ line: String, catalog: IngredientCatalog? = nil) -> RecipeIngredient {
        let catalog = catalog ?? Self.catalog
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let measure = measure(in: trimmed, catalog: catalog)
        let rest = measure?.rest ?? trimmed

        guard let (name, annotation) = nameAndAnnotation(in: rest, catalog: catalog) else {
            return RecipeIngredient(
                name: rest,
                quantity: measure?.quantity,
                size: measure?.size,
                isOutsideForm: true
            )
        }
        return RecipeIngredient(
            name: name,
            quantity: measure?.quantity,
            size: measure?.size,
            preparation: annotation,
            state: IngredientStateVocabulary.state(in: annotation)
        )
    }

    /// Whether `line` is in the fixed form.
    public static func isInForm(_ line: String, catalog: IngredientCatalog? = nil) -> Bool {
        !readLine(line, catalog: catalog).isOutsideForm
    }

    /// The name and the annotation of what follows the measure, or `nil`
    /// when no known name leads it.
    ///
    /// The whole rest is tried first, then every comma from the last to the
    /// first: the longest writing the catalog knows wins, so a name that
    /// carries its own comma ("Sauerrahm/Schmand, mind. 20 % Fett") stays
    /// whole and can still take an annotation after it.
    private static func nameAndAnnotation(
        in rest: String, catalog: IngredientCatalog
    ) -> (name: String, annotation: String?)? {
        if let link = leadingLink(in: rest) {
            let tail = rest[link.endIndex...].trimmingCharacters(in: .whitespaces)
            if tail.isEmpty { return (String(link), nil) }
            guard tail.hasPrefix(",") else { return nil }
            return (String(link), annotation(String(tail.dropFirst())))
        }
        if let name = knownName(rest, catalog: catalog) { return (name, nil) }

        var commas = rest.indices.filter { rest[$0] == "," }
        while let comma = commas.popLast() {
            let head = rest[..<comma].trimmingCharacters(in: .whitespaces)
            guard let name = knownName(head, catalog: catalog) else { continue }
            return (name, annotation(String(rest[rest.index(after: comma)...])))
        }
        return nil
    }

    private static func annotation(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `written` as the name it is, when the catalog knows that writing.
    ///
    /// A plural glued on in parentheses — "Aubergine(n)", as recipe sites
    /// write it — is closed grammar like "Zehe/n" and reads as the plural
    /// itself, which is also how the name then shows.
    private static func knownName(_ written: String, catalog: IngredientCatalog) -> String? {
        guard !written.isEmpty else { return nil }
        if catalog.ingredient(writtenAs: written) != nil { return written }
        guard let glued = gluedPlural(written), catalog.ingredient(writtenAs: glued) != nil
        else { return nil }
        return glued
    }

    private static let gluedPluralEndings: Set<String> = ["n", "en", "e", "s", "er", "nen"]

    /// "Aubergine(n)" → "Auberginen"; `nil` for anything else.
    private static func gluedPlural(_ written: String) -> String? {
        guard written.hasSuffix(")"), let open = written.lastIndex(of: "("),
              open > written.startIndex, written[written.index(before: open)].isLetter
        else { return nil }
        let ending = String(written[written.index(after: open)..<written.index(before: written.endIndex)])
        guard gluedPluralEndings.contains(ending) else { return nil }
        return String(written[..<open]) + ending
    }

    /// A markdown link at the start of `text`: "[Naan](sous://recipe/…)".
    private static func leadingLink(in text: String) -> Substring? {
        guard text.hasPrefix("["), let middle = text.range(of: "]("),
              let close = text[middle.upperBound...].firstIndex(of: ")")
        else { return nil }
        return text[...close]
    }

    // MARK: - The measure

    /// The amount, size word and unit a line starts with.
    public struct Measure: Hashable, Sendable {
        public var quantity: Quantity
        public var size: IngredientSize?
        /// How many leading characters of the trimmed line the measure
        /// takes, for colouring a line while it is being typed.
        public var length: Int
        /// What follows the measure, trimmed.
        public var rest: String
    }

    /// The measure `line` starts with, `nil` if it does not start with an
    /// amount. A missing unit is a count: "2 Zwiebeln" is two pieces.
    public static func measure(in line: String, catalog: IngredientCatalog? = nil) -> Measure? {
        let catalog = catalog ?? Self.catalog
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let (amount, afterAmount) = leadingAmount(in: Substring(trimmed)) else { return nil }
        var rest = afterAmount.trimmingCharacters(in: .whitespaces)

        var size: IngredientSize?
        if let (word, afterWord) = firstWord(of: rest), !afterWord.isEmpty,
           let sized = IngredientSize(word: word),
           // "Große Sandklaffmuschel" is a name, not a size and a name.
           knownName(rest, catalog: catalog) == nil {
            size = sized
            rest = afterWord
        }

        var unit = IngredientUnit.piece
        if let (word, afterWord) = firstWord(of: rest), let known = knownUnit(word) {
            unit = known
            rest = afterWord
        }
        return Measure(
            quantity: Quantity(amount, unit), size: size,
            length: trimmed.count - rest.count, rest: rest
        )
    }

    private static func firstWord(of text: String) -> (word: String, rest: String)? {
        guard !text.isEmpty else { return nil }
        guard let space = text.firstIndex(of: " ") else { return (text, "") }
        return (String(text[..<space]), text[text.index(after: space)...].trimmingCharacters(in: .whitespaces))
    }

    private static func knownUnit(_ word: String) -> IngredientUnit? {
        let unit = IngredientUnit(symbol: word)
        if case .custom = unit { return nil }
        return unit
    }

    /// Unicode fractions.
    private static let fractions: [Character: Double] = [
        "½": 0.5, "⅓": 1.0 / 3.0, "⅔": 2.0 / 3.0, "¼": 0.25, "¾": 0.75,
        "⅕": 0.2, "⅙": 1.0 / 6.0, "⅛": 0.125, "⅜": 0.375, "⅝": 0.625, "⅞": 0.875,
    ]

    /// A leading amount and what follows it: "300", "1,5", "0.5", "1/2",
    /// "½", "1 ½", "1½", "1 1/2", "10-15".
    static func leadingAmount(in text: Substring) -> (Double, Substring)? {
        var rest = text.drop { $0 == " " }
        guard let (first, afterFirst) = number(in: rest) else { return nil }
        var amount = first.value
        rest = afterFirst

        // A mixed number: a whole, then a fraction glyph ("1½", "1 ½") or a
        // written fraction ("1 1/2").
        if first.isWhole {
            let peek = rest.drop { $0 == " " }
            if let glyph = peek.first, let value = fractions[glyph] {
                amount += value
                rest = peek.dropFirst()
            } else if peek.startIndex > rest.startIndex,
                      let (fraction, afterFraction) = number(in: peek), fraction.isFraction {
                amount += fraction.value
                rest = afterFraction
            }
        }

        // A range takes its lower bound — the cook can always add more.
        if let dash = rest.first, dash == "-" || dash == "–",
           let (_, afterUpper) = number(in: rest.dropFirst()) {
            rest = afterUpper
        }
        return (amount, rest)
    }

    private struct Number {
        var value: Double
        var isWhole: Bool
        var isFraction: Bool
    }

    /// One number at the very start of `text`: a glyph, digits with an
    /// optional decimal part, or digits over digits.
    private static func number(in text: Substring) -> (Number, Substring)? {
        guard let first = text.first else { return nil }
        if let glyph = fractions[first] {
            return (Number(value: glyph, isWhole: false, isFraction: true), text.dropFirst())
        }
        let whole = text.prefix { $0.isASCII && $0.isNumber }
        guard !whole.isEmpty else { return nil }
        let rest = text[whole.endIndex...]

        if let separator = rest.first, separator == "," || separator == "." {
            let decimals = rest.dropFirst().prefix { $0.isASCII && $0.isNumber }
            if !decimals.isEmpty, let value = Double("\(whole).\(decimals)") {
                return (Number(value: value, isWhole: false, isFraction: false), rest[decimals.endIndex...])
            }
        }
        if rest.first == "/" {
            let denominator = rest.dropFirst().prefix { $0.isASCII && $0.isNumber }
            if let numerator = Double(whole), let divisor = Double(denominator), divisor != 0 {
                return (
                    Number(value: numerator / divisor, isWhole: false, isFraction: true),
                    rest[denominator.endIndex...]
                )
            }
        }
        guard let value = Double(whole) else { return nil }
        return (Number(value: value, isWhole: true, isFraction: false), rest)
    }
}
