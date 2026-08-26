import Foundation

/// The closed list of words a line may append to an ingredient, and what each
/// of them means for the numbers.
///
/// The concept calls the preparation state "a small closed vocabulary the
/// parser reads from words like 'gegart' or 'TK'" and lists six of them: raw,
/// cooked, fried, frozen, canned, dried. **Only the first two are states
/// here**, and that is a decision the data forces rather than a shortcut:
///
/// - The pipeline (`Scripts/nutrition/state_suffix.py`) folds exactly `roh`
///   and the cooking words together into one ingredient with two bases. That
///   is the dimension a *basis* is chosen along, and `IngredientState` is the
///   key those bases are stored under.
/// - Everything else — `tiefgefroren`, `Konserve`, `getrocknet` and their
///   companions in `NONMERGE_WORDS` — stays a **name** in the shipped data:
///   649 BLS rows end in one, and the synonym table carries them as words of
///   their own ("Tomate Konserve", "Erbse grün, tiefgefroren"). Canned
///   tomatoes are not tomatoes in a state, they are a different food with
///   different numbers and a different shelf.
///
/// So the parser reads both kinds and routes them differently: a state word
/// sets ``RecipeIngredient/state``, a qualifier word is used to *resolve the
/// name* — "Tomaten, Konserve" looks its nutrition up under "Tomate Konserve"
/// and falls back to plain "Tomate" when the catalog has no such word.
///
/// The alternative — widening `IngredientState` — was rejected: it needs a
/// pipeline re-run that splits those 649 rows into (base, state), which melts
/// down names that work today and changes the bundled data for every one of
/// them.
public enum IngredientStateVocabulary {
    /// Mirrors `RAW_WORDS` in the pipeline. The two lists have to agree: this
    /// one decides which state a line asks for, that one decided which state
    /// the bases were filed under.
    static let rawWords: Set<String> = ["roh"]

    /// Mirrors `COOKED_WORDS` in the pipeline, plus "blanchiert", which a
    /// recipe writes and the catalog does not.
    ///
    /// Kept as tight as the pipeline's: every word here can end a name and
    /// be split off it, so a word that is sometimes something else — "gar",
    /// which is also half of "gar nicht" — costs more than it is worth.
    static let cookedWords: Set<String> = [
        "gekocht", "gegart", "gedünstet", "gebraten", "gebacken",
        "gegrillt", "gedämpft", "pochiert", "frittiert", "blanchiert",
    ]

    /// Written word → the word the catalog uses for it. These do *not* set a
    /// state; they pick a different ingredient (see the note on the type).
    static let qualifierWords: [String: String] = [
        "tk": "tiefgefroren",
        "tiefgefroren": "tiefgefroren",
        "tiefgekühlt": "tiefgefroren",
        "gefroren": "tiefgefroren",
        "konserve": "Konserve",
        "dose": "Konserve",
        "getrocknet": "getrocknet",
        "gedörrt": "getrocknet",
    ]

    /// The state a single word names, `nil` for anything outside the list.
    static func state(forWord word: String) -> IngredientState? {
        let word = clean(word)
        if rawWords.contains(word) { return .raw }
        if cookedWords.contains(word) { return .cooked }
        return nil
    }

    /// The catalog's word for a qualifier, `nil` for anything else.
    static func qualifier(forWord word: String) -> String? {
        qualifierWords[clean(word)]
    }

    /// Whether a word says anything at all — what the parser tests a trailing
    /// word against before splitting it off a name.
    static func isVocabulary(_ word: String) -> Bool {
        state(forWord: word) != nil || qualifier(forWord: word) != nil
    }

    /// The state a preparation names: "gegart" → cooked, "fein gehackt" →
    /// none.
    ///
    /// Only the *first* word counts, exactly as the pipeline reads a BLS
    /// name's suffix. "in Streifen gebraten" is a way of cutting something,
    /// not the claim that the amount was weighed after frying, and reading it
    /// as one would silently move the numbers of every line written that way.
    public static func state(in preparation: String?) -> IngredientState {
        guard let first = firstWord(of: preparation) else { return .unspecified }
        return state(forWord: first) ?? .unspecified
    }

    /// The qualifier a preparation names, by the same first-word rule.
    public static func qualifier(in preparation: String?) -> String? {
        guard let first = firstWord(of: preparation) else { return nil }
        return qualifier(forWord: first)
    }

    /// A name's trailing vocabulary word split off: "Kartoffeln gegart" →
    /// ("Kartoffeln", "gegart"). `nil` when the last word says nothing, or
    /// when nothing usable would be left of the name.
    ///
    /// The caller decides whether the split is allowed at all — see
    /// ``IngredientParser/parseLine(_:catalog:)``, which asks the catalog
    /// first so that a name the catalog knows whole ("Kartoffel geschält,
    /// gekocht") is never taken apart.
    static func trailingWord(in name: String) -> (stem: String, word: String)? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let spaceIndex = trimmed.lastIndex(of: " ") else { return nil }
        let word = String(trimmed[trimmed.index(after: spaceIndex)...])
        guard isVocabulary(word) else { return nil }
        let stem = String(trimmed[..<spaceIndex]).trimmingCharacters(in: .whitespaces)
        // Not a name any more, so not a split: "roh" on its own is a line
        // that says nothing, and "TK" alone is a shopping note.
        guard stem.count >= 3 else { return nil }
        return (stem, word)
    }

    private static func firstWord(of text: String?) -> String? {
        text?.split(separator: " ").first.map(String.init)
    }

    /// Lowercased and stripped of the punctuation a written line carries
    /// around a word — "(gegart)," and "gegart" are the same word.
    private static func clean(_ word: String) -> String {
        word
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .lowercased()
    }
}
