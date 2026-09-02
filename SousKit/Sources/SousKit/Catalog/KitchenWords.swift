import Foundation

/// The kitchen's own vocabulary: the words a cook writes on a shopping list.
///
/// One of the two lists the food data is made of, and the only one the app
/// ever *offers*. The other is the BLS — a food table, with a food table's
/// way of naming things ("Bohne, grün", "Speisezwiebel tiefgefroren,
/// geschmort ohne Fett") — and the two are kept apart on purpose. They used
/// to be poured into one vocabulary at build time, and the result was that
/// every suggestion list mixed two languages and offered eight spellings of
/// an onion to somebody who wanted one.
///
/// Kept apart means kept apart in the shipped files too: this is
/// `kitchen_words.json`, read exactly as the curation writes it, and
/// ``IngredientCuration`` is the link from these words to the table's rows.
/// Nothing joins the two lists into a third.
public struct KitchenWords: Sendable {
    /// One word, as the kitchen says it.
    public struct Word: Codable, Sendable, Hashable {
        /// The name shown and stored: "Tomate".
        public var name: String
        /// Other ways of writing the same thing: "Tomaten", "Marille".
        public var aliases: [String]
        /// What kind of thing it is — and where on the shopping list it goes.
        /// Optional since a variety inherits it (catalog target, decision B):
        /// a word with a `parent` and no `category` takes the parent's, and
        /// writing one on a variety is an override, not a requirement. A root
        /// word still needs one, and `BundledDataTests` says so.
        public var category: IngredientCategory?
        /// The word this one is a *variety* of — "Cocktailtomate" of
        /// "Tomate". Curated, never guessed: a spelling and a variety look
        /// the same from outside, and the difference decides whether the
        /// shopping list may add two lines up.
        public var parent: String?

        public init(
            name: String, aliases: [String] = [], category: IngredientCategory? = nil,
            parent: String? = nil
        ) {
            self.name = name
            self.aliases = aliases
            self.category = category
            self.parent = parent
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                name: try container.decode(String.self, forKey: .name),
                aliases: try container.decodeIfPresent([String].self, forKey: .aliases) ?? [],
                category: try container.decodeIfPresent(IngredientCategory.self, forKey: .category),
                parent: try container.decodeIfPresent(String.self, forKey: .parent)
            )
        }
    }

    public private(set) var words: [Word]

    public init(words: [Word]) {
        self.words = words
    }

    /// The list shipped with the app — `kitchen_words.json`, verbatim.
    public static let bundled: KitchenWords = {
        guard let url = Bundle.module.url(forResource: "kitchen_words", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let words = try? JSONDecoder().decode([Word].self, from: data)
        else {
            assertionFailure("The bundled kitchen words are missing or unreadable")
            return KitchenWords(words: [])
        }
        return KitchenWords(words: words)
    }()
}
