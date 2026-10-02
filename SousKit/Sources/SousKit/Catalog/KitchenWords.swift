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
        /// The word's id in the catalog: a slug fixed when the word was
        /// created ("rote-zwiebel"), which survives a new name and is never
        /// given to another word. Optional because an older file has none;
        /// an app that predates it ignores the key.
        public var id: String?
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
        /// Spellings that imply a unit, by the spelling as written:
        /// "Knoblauchzehe" → "Zehe" reads "2 Knoblauchzehen" as 2 Zehen
        /// Knoblauch. Each is also in `aliases`, so an app that predates
        /// this field still recognizes the spelling.
        public var aliasUnits: [String: String]
        /// `product` for a finished product off a label; absent for a food.
        public var kind: String?
        /// A product's brand: "ja!". What the shopping list shows beside a
        /// household's generic word when this is the product it buys.
        public var brand: String?
        /// A product's EANs, as strings: leading zeros are part of them.
        public var ean: [String]
        /// A product no longer sold. It keeps its id and values, so old
        /// recipes still compute; it only leaves the suggestions.
        public var discontinued: Bool
        /// A product without label values: the id of the generic word it
        /// counts like, as an estimate.
        public var like: String?

        public init(
            name: String, aliases: [String] = [], category: IngredientCategory? = nil,
            parent: String? = nil, aliasUnits: [String: String] = [:], id: String? = nil,
            kind: String? = nil, brand: String? = nil, ean: [String] = [], discontinued: Bool = false,
            like: String? = nil
        ) {
            self.id = id
            self.name = name
            self.aliases = aliases
            self.category = category
            self.parent = parent
            self.aliasUnits = aliasUnits
            self.kind = kind
            self.brand = brand
            self.ean = ean
            self.discontinued = discontinued
            self.like = like
        }

        /// The product half of this word, `nil` for a food.
        public var product: CatalogProduct? {
            kind == "product"
                ? CatalogProduct(brand: brand ?? name, eans: ean, isDiscontinued: discontinued, like: like)
                : nil
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                name: try container.decode(String.self, forKey: .name),
                aliases: try container.decodeIfPresent([String].self, forKey: .aliases) ?? [],
                category: try container.decodeIfPresent(IngredientCategory.self, forKey: .category),
                parent: try container.decodeIfPresent(String.self, forKey: .parent),
                aliasUnits: try container.decodeIfPresent([String: String].self, forKey: .aliasUnits) ?? [:],
                id: try container.decodeIfPresent(String.self, forKey: .id),
                kind: try container.decodeIfPresent(String.self, forKey: .kind),
                brand: try container.decodeIfPresent(String.self, forKey: .brand),
                ean: try container.decodeIfPresent([String].self, forKey: .ean) ?? [],
                discontinued: try container.decodeIfPresent(Bool.self, forKey: .discontinued) ?? false,
                like: try container.decodeIfPresent(String.self, forKey: .like)
            )
        }
    }

    public private(set) var words: [Word]

    public init(words: [Word]) {
        self.words = words
    }

    /// `kitchen_words.json`, verbatim.
    init(json: Data) throws {
        self.init(words: try JSONDecoder().decode([Word].self, from: json))
    }

    /// The list of the data set this process runs on.
    public static var current: KitchenWords { DataSet.current.kitchenWords }

    /// The list shipped with the app.
    public static var bundled: KitchenWords { DataSet.bundled.kitchenWords }
}
