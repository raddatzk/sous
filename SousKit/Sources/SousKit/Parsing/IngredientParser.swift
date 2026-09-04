import Foundation

/// Turns a written ingredient list into structured lines, and back.
///
/// Typing "300 g Zucchini, fein gehackt" is how a recipe is actually
/// written down, and how it arrives from an import or from the model. The
/// structure is still what gets stored — scaling, nutrition and shopping
/// lists all need the amount as a number.
public enum IngredientParser {
    /// Unicode fractions, and the ASCII forms people type instead.
    private static let fractions: [String: Double] = [
        "½": 0.5, "⅓": 1.0 / 3.0, "⅔": 2.0 / 3.0, "¼": 0.25, "¾": 0.75,
        "⅕": 0.2, "⅙": 1.0 / 6.0, "⅛": 0.125, "⅜": 0.375, "⅝": 0.625, "⅞": 0.875,
    ]

    /// Parses a whole list, one ingredient per line.
    ///
    /// A line that carries no amount and ends in a colon — or starts with a
    /// markdown heading — opens a group that the following lines belong to.
    ///
    /// `catalog` is consulted only to tell a name that happens to contain a
    /// comma from a name followed by a preparation — see `parseLine`.
    public static func parse(_ text: String, catalog: IngredientCatalog = .bundled) -> [RecipeIngredient] {
        var result: [RecipeIngredient] = []
        var currentGroup: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if let heading = groupHeading(in: line) {
                currentGroup = heading
                continue
            }

            var ingredient = parseLine(line, catalog: catalog)
            ingredient.id = StableID.make(namespace: "ingredient", index: result.count, content: line)
            ingredient.group = currentGroup
            result.append(ingredient)
        }
        return result
    }

    /// Renders lines back into the text the user edits.
    public static func text(for ingredients: [RecipeIngredient], formatter: QuantityFormatter = QuantityFormatter()) -> String {
        var lines: [String] = []
        var lastGroup: String??

        for ingredient in ingredients {
            if lastGroup == nil || lastGroup! != ingredient.group {
                if let group = ingredient.group {
                    if !lines.isEmpty { lines.append("") }
                    lines.append("# \(group)")
                }
                lastGroup = ingredient.group
            }
            lines.append(formatter.string(for: ingredient))
        }
        return lines.joined(separator: "\n")
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
        guard !heading.isEmpty, leadingAmount(in: heading) == nil else { return nil }
        return heading
    }

    /// Parses one line into an ingredient.
    ///
    /// `catalog` settles a genuine ambiguity in the comma: "Zucchini, fein
    /// gehackt" is a name and a preparation, but "Sauerrahm/Schmand, mind.
    /// 20 % Fett" is one name that carries its own qualifier — and so are
    /// 974 of the 2661 bundled names, since that is how the BLS writes
    /// them. Nothing in the line itself tells the two apart, so the only
    /// honest answer is to ask what is a known ingredient. A name the
    /// catalog knows whole is left whole; everything else splits as before.
    public static func parseLine(_ line: String, catalog: IngredientCatalog = .bundled) -> RecipeIngredient {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))

        var quantity: Quantity?
        var size: IngredientSize?
        if let (amount, remainder) = leadingAmount(in: String(rest)) {
            rest = Substring(remainder)
            let (parsedSize, afterSize) = leadingSize(in: String(rest), catalog: catalog)
            size = parsedSize
            rest = Substring(afterSize)
            let (unit, afterUnit) = leadingUnit(in: String(rest))
            rest = Substring(afterUnit)
            quantity = Quantity(amount, unit ?? .piece)
        }

        // How it is prepared is written either in trailing parentheses, the
        // way Mela does it, or after a comma, the way people type.
        var name = String(rest).trimmingCharacters(in: .whitespaces)
        var preparation: String?

        if name.hasSuffix(")"), let openIndex = name.lastIndex(of: "("),
           !isMarkdownLink(closingAt: openIndex, in: name) {
            preparation = String(name[name.index(after: openIndex)..<name.index(before: name.endIndex)])
                .trimmingCharacters(in: .whitespaces)
            name = String(name[..<openIndex]).trimmingCharacters(in: .whitespaces)
        } else if let commaIndex = name.firstIndex(of: ","), catalog.ingredient(for: name) == nil {
            preparation = String(name[name.index(after: commaIndex)...])
                .trimmingCharacters(in: .whitespaces)
            name = String(name[..<commaIndex]).trimmingCharacters(in: .whitespaces)
        }

        // "nach Geschmack" is an amount written in words, not part of the
        // name — left in place it would keep "Salz nach Geschmack" from ever
        // matching the catalog. Split off, but remembered, so the line
        // renders back exactly as typed.
        var unquantifiedPhrase: UnquantifiedPhrase?
        if let (stripped, phrase) = trailingUnquantifiedPhrase(in: name) {
            name = stripped
            unquantifiedPhrase = phrase
        } else if quantity == nil, let (stripped, phrase) = leadingUnquantifiedWord(in: name) {
            name = stripped
            unquantifiedPhrase = phrase
        }

        // A state word may stand after the comma, where the two branches
        // above already put it, or bare at the end of the name — "500 g
        // Kartoffeln gegart". The second writing is moved into the
        // preparation so that both arrive in one shape, and so that the name
        // is a name again and can be found in the catalog at all.
        //
        // Never for a name the catalog knows whole: 649 of the shipped names
        // end in a word from this vocabulary ("Erbse grün, tiefgefroren"),
        // and taking those apart is the very thing the comma rule above
        // exists to prevent.
        if catalog.ingredient(for: name) == nil,
           let (stem, word) = IngredientStateVocabulary.trailingWord(in: name) {
            name = stem
            preparation = [word, preparation].compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }

        return RecipeIngredient(
            name: name,
            quantity: quantity,
            size: size,
            unquantifiedPhrase: unquantifiedPhrase,
            preparation: preparation?.isEmpty == false ? preparation : nil,
            // Read, not consumed: the words stay where they were written, so
            // the line still renders as it was typed. What the state adds is
            // which of an ingredient's bases the numbers come from.
            state: IngredientStateVocabulary.state(in: preparation)
        )
    }

    /// The phrases that trail a name in place of a number. A closed list on
    /// purpose: this is grammar, not open language, and every entry must
    /// round-trip through `text(for:)` unchanged.
    private static let trailingUnquantifiedPhrases = ["nach Geschmack", "nach Belieben"]
    /// The words that lead a name in place of a number: "etwas Salz".
    private static let leadingUnquantifiedWords = ["etwas", "einige"]

    /// Splits a trailing "nach Geschmack" off `name`, keeping the phrase as
    /// written. `nil` when no phrase trails it, or nothing would remain.
    private static func trailingUnquantifiedPhrase(in name: String) -> (String, UnquantifiedPhrase)? {
        for phrase in trailingUnquantifiedPhrases {
            guard let range = name.range(of: " " + phrase, options: [.caseInsensitive, .anchored, .backwards])
            else { continue }
            let stripped = String(name[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else { continue }
            let written = String(name[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
            return (stripped, UnquantifiedPhrase(phrase: written, placement: .afterName))
        }
        return nil
    }

    /// Splits a leading "etwas" off `name`, keeping the word as written.
    /// Only consulted when the line carries no number of its own.
    private static func leadingUnquantifiedWord(in name: String) -> (String, UnquantifiedPhrase)? {
        for word in leadingUnquantifiedWords {
            guard let range = name.range(of: word + " ", options: [.caseInsensitive, .anchored])
            else { continue }
            let stripped = String(name[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else { continue }
            let written = String(name[..<range.upperBound]).trimmingCharacters(in: .whitespaces)
            return (stripped, UnquantifiedPhrase(phrase: written, placement: .beforeName))
        }
        return nil
    }

    /// Whether the parenthesis at `index` opens a markdown link's target
    /// rather than a comment.
    ///
    /// "300 g Zucchini (fein gehackt)" is a comment; "1 Portion
    /// [Naan](sous://recipe/…)" is a link, and splitting it would leave a
    /// stray "[Naan]" behind that no longer renders as one.
    private static func isMarkdownLink(closingAt index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return false }
        return text[text.index(before: index)] == "]"
    }

    /// Reads a leading amount: "300", "1,5", "1/2", "½", "1 ½", "3-4".
    /// A range takes its lower bound — the cook can always add more.
    private static func leadingAmount(in text: String) -> (Double, String)? {
        var scanner = Substring(text)
        var total: Double?

        while let (value, rest) = nextNumber(in: scanner) {
            total = (total ?? 0) + value
            scanner = rest

            // "1 ½" is one and a half; "2 Eier" is not.
            let peek = scanner.drop(while: { $0 == " " })
            guard let first = peek.first, fractions[String(first)] != nil else { break }
            scanner = peek
        }

        guard let total else { return nil }
        return (total, String(scanner).trimmingCharacters(in: .whitespaces))
    }

    private static func nextNumber(in text: Substring) -> (Double, Substring)? {
        let trimmed = text.drop(while: { $0 == " " })
        guard let first = trimmed.first else { return nil }

        if let fraction = fractions[String(first)] {
            return (fraction, trimmed.dropFirst())
        }

        guard first.isNumber else { return nil }
        let digits = trimmed.prefix { $0.isNumber || $0 == "," || $0 == "." || $0 == "/" || $0 == "-" }
        var remainder = trimmed[digits.endIndex...]
        var token = String(digits)

        // A trailing separator belongs to the text, not the number: "2, fein"
        while let last = token.last, !last.isNumber {
            token.removeLast()
            remainder = trimmed[trimmed.index(digits.startIndex, offsetBy: token.count)...]
        }

        if let slash = token.firstIndex(of: "/") {
            let numerator = Double(token[..<slash].replacingOccurrences(of: ",", with: "."))
            let denominator = Double(token[token.index(after: slash)...].replacingOccurrences(of: ",", with: "."))
            guard let numerator, let denominator, denominator != 0 else { return nil }
            return (numerator / denominator, remainder)
        }
        if let dash = token.firstIndex(of: "-") {
            token = String(token[..<dash])
        }
        guard let value = Double(token.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return (value, remainder)
    }

    /// Reads a leading size word: "1 kleine Zimtstange", "3 große EL
    /// Mandelmus". It stands between the amount and whatever follows, so it
    /// is read before the unit — otherwise "große" hides the "EL" behind it
    /// and the whole rest of the line becomes a name.
    ///
    /// Only ever after an amount, which is why the caller asks from inside
    /// that branch: without a number in front of it the word is as likely to
    /// name the thing as to measure it.
    ///
    /// A name the catalog knows whole keeps its word. "Große
    /// Sandklaffmuschel" is one of the shipped names, and taking it apart is
    /// the mistake the comma rule in ``parseLine(_:catalog:)`` exists to
    /// prevent, made in a second place.
    private static func leadingSize(
        in text: String, catalog: IngredientCatalog
    ) -> (IngredientSize?, String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard catalog.ingredient(for: trimmed) == nil,
              let spaceIndex = trimmed.firstIndex(of: " "),
              let size = IngredientSize(word: String(trimmed[..<spaceIndex]))
        else { return (nil, trimmed) }

        let rest = String(trimmed[trimmed.index(after: spaceIndex)...])
            .trimmingCharacters(in: .whitespaces)
        // "2 kleine" is an amount and nothing else; the word stays where it
        // was rather than leaving a line with no name at all.
        guard !rest.isEmpty else { return (nil, trimmed) }
        return (size, rest)
    }

    /// Reads a unit if the next word is one. An unknown word is the
    /// ingredient's name, not a unit — "2 Zwiebeln" has no unit.
    private static func leadingUnit(in text: String) -> (IngredientUnit?, String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let spaceIndex = trimmed.firstIndex(of: " ") else {
            // A line may be only an amount and a unit, e.g. "2 EL".
            let candidate = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if let unit = knownUnit(candidate) { return (unit, "") }
            return (nil, trimmed)
        }

        let word = String(trimmed[..<spaceIndex])
        let rest = String(trimmed[trimmed.index(after: spaceIndex)...])
        if let unit = knownUnit(word.trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            return (unit, rest)
        }
        return (nil, trimmed)
    }

    /// How many leading characters of a trimmed line are its measure —
    /// amount, size word and unit — for colouring a line while it is still
    /// being typed, without waiting for it to parse into a full ingredient.
    /// `nil` if the line does not start with an amount at all.
    public static func leadingAmountAndUnitLength(
        in line: String, catalog: IngredientCatalog = .bundled
    ) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let (_, afterAmount) = leadingAmount(in: trimmed) else { return nil }
        let (_, afterSize) = leadingSize(in: afterAmount, catalog: catalog)
        let (_, afterUnit) = leadingUnit(in: afterSize)
        return trimmed.count - afterUnit.count
    }

    private static func knownUnit(_ word: String) -> IngredientUnit? {
        guard !word.isEmpty else { return nil }
        let unit = IngredientUnit(symbol: word)
        // `custom` means it was not recognized — treat it as part of the name.
        if case .custom = unit { return nil }
        return unit
    }
}
