import Foundation

/// Typed search text, read the way both stores and the library read it.
///
/// Word by word rather than as one string: "Pol Pani" is the same question as
/// "Pani Pol", and "Kürbis Suppe" asks for a soup with pumpkin in it even
/// though the title only says "Suppe" and the pumpkin is an ingredient. And
/// without accents: a phone keyboard makes "kurbis" as easy to type as
/// "kürbis", and nobody typing it means anything else.
///
/// One type so that what finds a recipe and what ranks it cannot drift apart:
/// a recipe ranked for words it was never found by would be as confusing as
/// one found and then buried.
public struct RecipeSearchTerms: Sendable, Hashable {
    /// Lowercased and without accents, in the order they were typed.
    public let words: [String]

    public init(_ text: String) {
        words = text.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }
    }

    public var isEmpty: Bool { words.isEmpty }

    /// Whether every word appears somewhere in `text` — a recipe's indexed
    /// `searchText`, where a word may land in the title, a category or an
    /// ingredient.
    public func matches(_ text: String) -> Bool {
        let folded = Self.fold(text)
        return words.allSatisfy { folded.contains($0) }
    }

    /// How closely a title answers the words — lower is closer.
    ///
    /// The store finds everything that mentions the words anywhere, which for
    /// two letters is half the library: "pa" is in Spaghetti and in every
    /// recipe with Paprika. What the cook is most likely after is the recipe
    /// *called* that, so those come first: the title starting with what was
    /// typed, then a word of the title starting with each typed word, then a
    /// title merely containing them, and last the recipes found only through
    /// an ingredient or a category.
    public func rank(ofTitle title: String) -> Int {
        let folded = Self.fold(title)
        if folded.hasPrefix(words.joined(separator: " ")) { return 0 }
        let titleWords = folded.split { !$0.isLetter && !$0.isNumber }
        if words.allSatisfy({ word in titleWords.contains { $0.hasPrefix(word) } }) { return 1 }
        if words.allSatisfy({ folded.contains($0) }) { return 2 }
        return 3
    }

    /// `recipes` with the closest titles first, otherwise in the order given
    /// — which is the store's sort, so a tie still reads alphabetically.
    public func ranked(_ recipes: [Recipe]) -> [Recipe] {
        guard !isEmpty else { return recipes }
        let ranks = recipes.map { rank(ofTitle: $0.title) }
        let order = recipes.indices.sorted { first, second in
            ranks[first] == ranks[second] ? first < second : ranks[first] < ranks[second]
        }
        return order.map { recipes[$0] }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
