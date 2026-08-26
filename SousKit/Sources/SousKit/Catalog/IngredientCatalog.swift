import Foundation

/// Known ingredients, with the spellings they answer to.
///
/// Free-text recipes write the same thing many ways — "Tomate", "Tomaten",
/// "Cocktailtomaten". Resolving them to one entry is what lets a shopping
/// list add them up, group them by aisle, and later match them against a
/// nutrition database.
public struct IngredientCatalog: Sendable {
    private var byKey: [String: CatalogIngredient]
    public private(set) var ingredients: [CatalogIngredient]

    /// Both the index and the list are deduplicated by key, first occurrence
    /// winning — the caller puts the entries that should win in front (the
    /// cook's own before the bundled ones), and a name defined twice has to
    /// resolve to one entry *and* show up once in a list of them.
    public init(ingredients: [CatalogIngredient]) {
        byKey = [:]
        var representatives: [CatalogIngredient] = []
        var takenKeys = Set<String>()
        for ingredient in ingredients {
            if takenKeys.insert(ingredient.key).inserted {
                representatives.append(ingredient)
            }
            for key in ingredient.keys where byKey[key] == nil {
                byKey[key] = ingredient
            }
        }
        self.ingredients = representatives.sorted { $0.name < $1.name }
    }

    /// The catalog shipped with the app — the identity half of the synonym
    /// table, which is where the names and their spellings now live. One file
    /// for one thing: a word, what it answers to, what it means.
    public static let bundled: IngredientCatalog = {
        IngredientCatalog(ingredients: SynonymTable.bundled.catalogIngredients)
    }()

    /// Looks up an ingredient by any of its spellings.
    ///
    /// Falls back to a naive German plural: dropping a trailing "n" or "en"
    /// catches the regular cases the catalog does not list by hand.
    public func ingredient(for name: String) -> CatalogIngredient? {
        let key = Self.normalize(name)
        if let match = byKey[key] { return match }

        for suffix in ["en", "n", "e", "s"] where key.hasSuffix(suffix) {
            let stem = String(key.dropLast(suffix.count))
            if stem.count >= 3, let match = byKey[stem] { return match }
        }
        return nil
    }

    /// The canonical name for a written one, or the written one unchanged.
    public func canonicalName(for name: String) -> String {
        ingredient(for: name)?.name ?? name
    }

    public func category(for name: String) -> IngredientCategory? {
        ingredient(for: name)?.category
    }

    /// Ingredients whose name or spellings start with, or contain, `text` —
    /// for suggesting while typing. Prefix matches come first.
    public func suggestions(for text: String, limit: Int = 8) -> [CatalogIngredient] {
        let query = Self.normalize(text)
        guard query.count >= 2 else { return [] }

        /// Lower sorts first: the name itself beats an alias, a short name
        /// beats a long one. "toma" should offer Tomate before Tomatenmark,
        /// and both before Gehackte Tomaten, which only matches on an alias.
        func rank(_ ingredient: CatalogIngredient) -> (Int, Int) {
            let name = Self.normalize(ingredient.name)
            if name.hasPrefix(query) { return (0, name.count) }
            if ingredient.keys.contains(where: { $0.hasPrefix(query) }) { return (1, name.count) }
            if name.contains(query) { return (2, name.count) }
            return (3, name.count)
        }

        return ingredients
            .filter { ingredient in
                ingredient.keys.contains { $0.contains(query) }
            }
            .sorted { first, second in
                rank(first) == rank(second)
                    ? first.name < second.name
                    : rank(first) < rank(second)
            }
            .prefix(limit)
            .map { $0 }
    }

    /// The ingredients named in a piece of text that this catalog does not
    /// know — what the editor offers to add, and what a recipe's "unknown
    /// ingredients" review checks against.
    public func unknownIngredients(in text: String) -> [String] {
        var seen = Set<String>()
        return IngredientParser.parse(text, catalog: self).compactMap { ingredient in
            let name = ShoppingItem.displayName(for: ingredient.name)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count >= 2,
                  // A link points at a recipe, not at something to look up.
                  RecipeLink.referencedIDs(in: ingredient.name).isEmpty,
                  self.ingredient(for: name) == nil,
                  seen.insert(Self.normalize(name)).inserted
            else { return nil }
            return name
        }
    }

    /// Lowercased and stripped of surrounding whitespace. Comparison is on
    /// this form throughout, so "Rote Bete" and "rote bete" are one thing.
    public static func normalize(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
