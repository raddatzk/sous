import Foundation

/// A number or relative phrase inside a step's text that might name a share
/// of one ingredient line.
///
/// Finding these only looks at shape — a number with a unit, a bare number
/// beside a word, "Hälfte", "restlich" — never at meaning. Which line, if
/// any, a mention actually belongs to is answered later, across the whole
/// recipe at once: a step reading "die restlichen Kartoffeln" only means
/// something once every other step's claim on the same line is known.
public struct AmountMention {
    public enum Kind {
        /// A written amount with a recognized unit: "300 g", "1 EL".
        case absolute(Quantity)
        /// A written amount with no unit, bound only if some ingredient
        /// counts the same thing: "2" in "2 Kartoffeln".
        case bareCount(Double)
        /// A fixed share of the line's total, independent of the number the
        /// line itself scales to: "die Hälfte der Zwiebeln" is `0.5`, "ein
        /// Drittel des Teigs" is `1.0 / 3.0`, "2/3 der Heidelbeeren" is
        /// `2.0 / 3.0`. The fraction words are a closed list — the library
        /// uses Hälfte, Drittel and Viertel and nothing else.
        case fraction(Double)
        /// "die restlichen Kartoffeln" — whatever the other mentions of the
        /// same line have not already claimed.
        case remaining
    }

    public let kind: Kind
    /// The span written in the text: the digits (and unit, for `absolute`)
    /// for a number, or just the trigger word ("Hälfte der ", "Restliche ")
    /// for `half`/`remaining` — not the name that follows, since where
    /// exactly that name ends is only known once it has been matched
    /// against a line.
    public let writtenRange: Range<String.Index>
    /// Whether a resolved amount replaces `writtenRange` outright (a
    /// written number is being corrected) or is inserted after the name in
    /// `namePhrase` that turned out to match, instead. `half` and
    /// `remaining` name no amount of their own, and wording that already
    /// reads correctly at every serving count must never be rewritten.
    public let replacesWrittenRange: Bool
    /// The words next to `writtenRange` that might name the ingredient —
    /// normally the words that follow it ("300 g **Kartoffeln**"), possibly
    /// more of them than belong to the name since how many words an
    /// ingredient name takes is not known until it is matched. See
    /// `StepAmountResolver.matchedNameEnd`.
    public let namePhrase: Substring
    /// Whether `namePhrase` sits before `writtenRange` instead of after it —
    /// "**Rapsöl** (3 EL)" rather than "300 g **Kartoffeln**". The mirror
    /// image of the usual grammar, matched by `matchedNameStart` instead of
    /// `matchedNameEnd`: the name ends right where the mention starts,
    /// rather than starting right where the mention ends.
    public let namePrecedesAmount: Bool

    public init(
        kind: Kind, writtenRange: Range<String.Index>, replacesWrittenRange: Bool, namePhrase: Substring,
        namePrecedesAmount: Bool = false
    ) {
        self.kind = kind
        self.writtenRange = writtenRange
        self.replacesWrittenRange = replacesWrittenRange
        self.namePhrase = namePhrase
        self.namePrecedesAmount = namePrecedesAmount
    }
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
        result += parenthesizedMentions(in: text)
        result += phraseMentions(of: /[Hh]älfte\s+(?:der|des|den|dem|vom|von)\s+/, kind: .fraction(0.5), in: text)
        // The other fraction words a recipe actually uses. A closed list
        // on purpose: every one of these is grammar, not language, and
        // the library holds no others — see the 2026-09-15 analysis.
        result += phraseMentions(of: /(?:[Ee]in|1)\s+[Dd]rittel\s+(?:der|des|den|dem|vom|von)\s+/, kind: .fraction(1.0 / 3.0), in: text)
        result += phraseMentions(of: /[Zz]wei\s+[Dd]rittel\s+(?:der|des|den|dem|vom|von)\s+/, kind: .fraction(2.0 / 3.0), in: text)
        result += phraseMentions(of: /(?:[Ee]in|1)\s+[Vv]iertel\s+(?:der|des|den|dem|vom|von)\s+/, kind: .fraction(0.25), in: text)
        result += phraseMentions(of: /[Dd]rei\s+[Vv]iertel\s+(?:der|des|den|dem|vom|von)\s+/, kind: .fraction(0.75), in: text)
        result += writtenFractionMentions(in: text)
        result += phraseMentions(of: /(?:[Rr]estlich|[Üü]brig)(?:e|en|es|er|em)\s+/, kind: .remaining, in: text)
        result += phraseMentions(of: /(?:[Dd]en|[Dd]er|[Dd]as)\s+Rest\s+(?:der|des|vom|von)\s+/, kind: .remaining, in: text)
        return result.sorted { $0.writtenRange.lowerBound < $1.writtenRange.lowerBound }
    }

    /// "2/3 der Heidelbeeren" — a fraction written in digits, which
    /// `numberMentions` cannot read because no unit word follows the
    /// number.
    private static func writtenFractionMentions(in text: String) -> [AmountMention] {
        let pattern = /(\d)\s*\/\s*(\d)\s+(?:der|des|den|dem|vom|von)\s+/
        var result: [AmountMention] = []
        for match in text.matches(of: pattern) {
            guard let numerator = Double(String(match.1)), let denominator = Double(String(match.2)), denominator > 0,
                  numerator < denominator
            else { continue }
            let phrase = namePhrase(afterQualifiers: match.range.upperBound, in: text)
            guard !phrase.isEmpty else { continue }
            result.append(AmountMention(
                kind: .fraction(numerator / denominator),
                writtenRange: match.range,
                replacesWrittenRange: false,
                namePhrase: phrase
            ))
        }
        return result
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

    /// "Rapsöl (3 EL)" — an amount already written right after the name it
    /// belongs to, in parentheses, instead of before it. The mirror image
    /// of `numberMentions`: the same closed, mechanical grammar, just
    /// reversed — trusted by construction exactly like the forward order
    /// is, so this resolves straight into the text like any other regex
    /// mention rather than needing AI or a confirmation. See
    /// `amount-confirmation-vs-guessing-tension`: the model could already
    /// read this word order, but doing that made every already-answered
    /// "Name (Menge)" resurface as a fresh, unconfirmed suggestion on
    /// every enrichment pass — the deterministic reading this replaces it
    /// with has no such problem, because it never asks in the first place.
    ///
    /// A word inside the parentheses that is not a recognized unit is left
    /// alone rather than guessed at — "(ca. 5 Minuten warten)" is not an
    /// amount, and there is no way to tell the two apart from shape alone.
    private static func parenthesizedMentions(in text: String) -> [AmountMention] {
        let pattern = /\(\s*(\d+(?:[.,]\d+)?|[½⅓⅔¼¾])\s*([\p{L}]+\.?)?\s*\)/
        var result: [AmountMention] = []
        for match in text.matches(of: pattern) {
            guard let value = amountValue(from: String(match.1)) else { continue }
            let phrase = namePhrase(before: match.range.lowerBound, in: text)
            guard !phrase.isEmpty else { continue }

            if let unitWord = match.2 {
                let symbol = String(unitWord).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let unit = IngredientUnit(symbol: symbol)
                guard case .custom = unit else {
                    result.append(AmountMention(
                        kind: .absolute(Quantity(value, unit)),
                        writtenRange: match.1.startIndex..<unitWord.endIndex,
                        replacesWrittenRange: true,
                        namePhrase: phrase,
                        namePrecedesAmount: true
                    ))
                    continue
                }
            } else {
                result.append(AmountMention(
                    kind: .bareCount(value),
                    writtenRange: match.1.startIndex..<match.1.endIndex,
                    replacesWrittenRange: true,
                    namePhrase: phrase,
                    namePrecedesAmount: true
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
            let phrase = namePhrase(afterQualifiers: match.range.upperBound, in: text)
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

    /// The name phrase after `index`, skipping the qualifiers a cook puts
    /// between a share word and the name: "restliche **gekühlte**
    /// Pinienkerne", "die Hälfte des **noch warmen** Milchreises". German
    /// capitalizes its nouns, so a lowercase word before another word is a
    /// qualifier and never the name itself; the last word is kept whatever
    /// its case, so a phrase is never skipped down to nothing.
    static func namePhrase(afterQualifiers index: String.Index, in text: String) -> Substring {
        var start = index
        while true {
            let word = namePhrase(after: start, in: text, maxWords: 1)
            guard let first = word.first, first.isLowercase else { break }
            let next = namePhrase(after: word.endIndex, in: text, maxWords: 1)
            guard !next.isEmpty else { break }
            start = word.endIndex
        }
        return namePhrase(after: start, in: text)
    }

    /// Up to four words right after `index` — enough for any ingredient
    /// name in the catalog, short enough not to swallow the rest of the
    /// sentence.
    ///
    /// Not `private`: `StepAmountResolver` reuses this to look for a bare
    /// ingredient name with no number to anchor on, the same word-window
    /// shape as a mention's `namePhrase` — just starting from a word
    /// boundary instead of from wherever a trigger word ended.
    static func namePhrase(after index: String.Index, in text: String, maxWords: Int = 4) -> Substring {
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

    /// Up to four words right before `index` — the mirror image of
    /// `namePhrase(after:in:maxWords:)`, for a name that comes before the
    /// number instead of after it ("Rapsöl (3 EL)"). The words come back in
    /// their original left-to-right order, ending exactly at `index`, so a
    /// multi-word name ("Rote Bete (200 g)") reads correctly rather than
    /// reversed — only which end `matchedNameStart` trims from differs.
    static func namePhrase(before index: String.Index, in text: String, maxWords: Int = 4) -> Substring {
        var cursor = index
        while cursor > text.startIndex, text[text.index(before: cursor)] == " " { cursor = text.index(before: cursor) }
        let end = cursor
        var start = cursor
        var words = 0

        while words < maxWords {
            let wordEnd = cursor
            while cursor > text.startIndex, text[text.index(before: cursor)].isLetter || text[text.index(before: cursor)] == "-" {
                cursor = text.index(before: cursor)
            }
            guard cursor < wordEnd else { break }
            start = cursor
            words += 1

            var lookbehind = cursor
            while lookbehind > text.startIndex, text[text.index(before: lookbehind)] == " " { lookbehind = text.index(before: lookbehind) }
            guard lookbehind > text.startIndex, text[text.index(before: lookbehind)].isLetter else { break }
            cursor = lookbehind
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
