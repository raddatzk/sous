import Foundation

/// A number or relative phrase inside a step's text that might name a share
/// of one ingredient line.
///
/// Finding these only looks at shape — a number with a unit, a bare number
/// beside a word, "Hälfte", "restlich" — never at meaning. Which line, if
/// any, a mention actually belongs to is answered later, across the whole
/// recipe at once: a step reading "die restlichen Kartoffeln" only means
/// something once every other step's claim on the same line is known.
struct AmountMention {
    enum Kind {
        /// A written amount with a recognized unit: "300 g", "1 EL".
        case absolute(Quantity)
        /// A written amount with no unit, bound only if some ingredient
        /// counts the same thing: "2" in "2 Kartoffeln".
        case bareCount(Double)
        /// "die Hälfte der Zwiebeln" — always half, at every serving count.
        case half
        /// "die restlichen Kartoffeln" — whatever the other mentions of the
        /// same line have not already claimed.
        case remaining
    }

    let kind: Kind
    /// The span written in the text: the digits (and unit, for `absolute`)
    /// for a number, or just the trigger word ("Hälfte der ", "Restliche ")
    /// for `half`/`remaining` — not the name that follows, since where
    /// exactly that name ends is only known once it has been matched
    /// against a line.
    let writtenRange: Range<String.Index>
    /// Whether a resolved amount replaces `writtenRange` outright (a
    /// written number is being corrected) or is inserted after the name in
    /// `namePhrase` that turned out to match, instead. `half` and
    /// `remaining` name no amount of their own, and wording that already
    /// reads correctly at every serving count must never be rewritten.
    let replacesWrittenRange: Bool
    /// The words that follow `writtenRange`, matched against the catalog —
    /// possibly more of them than belong to the name, since how many words
    /// an ingredient name takes is not known until it is matched. See
    /// `StepAmountResolver.matchedNameEnd`.
    let namePhrase: Substring
}

/// Finds ``AmountMention``s in a step's text.
///
/// Patterns are built per call rather than held in a stored property:
/// `Regex` is not `Sendable`, so it cannot live in static state under
/// strict concurrency — the same reason ``RecipeLink`` builds its pattern
/// fresh each time.
enum AmountMentionScanner {
    static func mentions(in text: String) -> [AmountMention] {
        var result = numberMentions(in: text)
        result += phraseMentions(of: /[Hh]älfte\s+(?:der|des|von)\s+/, kind: .half, in: text)
        result += phraseMentions(of: /[Rr]estlich(?:e|en|es|er)\s+/, kind: .remaining, in: text)
        return result.sorted { $0.writtenRange.lowerBound < $1.writtenRange.lowerBound }
    }

    /// "300 g Kartoffeln" and "2 Kartoffeln" both start as a number
    /// followed by a word — the word is a unit in the first, and the start
    /// of the ingredient's name in the second.
    private static func numberMentions(in text: String) -> [AmountMention] {
        let pattern = /(\d+(?:[.,]\d+)?|[½⅓⅔¼¾])\s*([\p{L}]+\.?)/
        var result: [AmountMention] = []
        for match in text.matches(of: pattern) {
            guard let value = amountValue(from: String(match.1)) else { continue }
            let digitsRange = match.1.startIndex..<match.1.endIndex
            let word = String(match.2).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let unit = IngredientUnit(symbol: word)

            if case .custom = unit {
                let phrase = namePhrase(after: digitsRange.upperBound, in: text)
                guard !phrase.isEmpty else { continue }
                result.append(AmountMention(
                    kind: .bareCount(value),
                    writtenRange: digitsRange,
                    replacesWrittenRange: true,
                    namePhrase: phrase
                ))
            } else {
                let phrase = namePhrase(after: match.2.endIndex, in: text)
                guard !phrase.isEmpty else { continue }
                result.append(AmountMention(
                    kind: .absolute(Quantity(value, unit)),
                    writtenRange: match.range,
                    replacesWrittenRange: true,
                    namePhrase: phrase
                ))
            }
        }
        return result
    }

    private static func phraseMentions(
        of pattern: Regex<Substring>,
        kind: AmountMention.Kind,
        in text: String
    ) -> [AmountMention] {
        var result: [AmountMention] = []
        for match in text.matches(of: pattern) {
            let phrase = namePhrase(after: match.range.upperBound, in: text)
            guard !phrase.isEmpty else { continue }
            result.append(AmountMention(
                kind: kind,
                // Just the trigger word ("Hälfte der ", "Restliche ") — the
                // resolved amount is inserted after the name it turns out to
                // match, not after every word this happened to scan past.
                writtenRange: match.range,
                replacesWrittenRange: false,
                namePhrase: phrase
            ))
        }
        return result
    }

    /// Up to four words right after `index` — enough for any ingredient
    /// name in the catalog, short enough not to swallow the rest of the
    /// sentence.
    private static func namePhrase(after index: String.Index, in text: String, maxWords: Int = 4) -> Substring {
        var cursor = index
        while cursor < text.endIndex, text[cursor] == " " { cursor = text.index(after: cursor) }
        let start = cursor
        var end = cursor
        var words = 0

        while words < maxWords {
            let wordStart = cursor
            while cursor < text.endIndex, text[cursor].isLetter || text[cursor] == "-" {
                cursor = text.index(after: cursor)
            }
            guard cursor > wordStart else { break }
            end = cursor
            words += 1

            var lookahead = cursor
            while lookahead < text.endIndex, text[lookahead] == " " { lookahead = text.index(after: lookahead) }
            guard lookahead < text.endIndex, text[lookahead].isLetter else { break }
            cursor = lookahead
        }
        return text[start..<end]
    }

    /// Same fraction glyphs and decimal handling as everywhere else a
    /// written amount is read.
    static func amountValue(from token: String) -> Double? {
        switch token {
        case "½": 0.5
        case "⅓": 1.0 / 3.0
        case "⅔": 2.0 / 3.0
        case "¼": 0.25
        case "¾": 0.75
        default: Double(token.replacingOccurrences(of: ",", with: "."))
        }
    }
}
