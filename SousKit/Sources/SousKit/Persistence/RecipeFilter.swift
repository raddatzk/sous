import Foundation

/// A recognized filter: a known ingredient or an existing category, rather
/// than free text.
///
/// Typing "Tomate" into the search field could mean the word, the ingredient,
/// or a category someone named that. Turning it into a filter makes the
/// difference explicit and lets several of them stack up.
public struct RecipeFilter: Hashable, Identifiable, Sendable {
    public enum Kind: Hashable, Sendable {
        case ingredient
        case category
    }

    public let kind: Kind
    /// What is matched against: a catalog key, or the category as written.
    public let key: String
    /// What is shown on the chip.
    public let title: String

    public var id: String { "\(kind)-\(key)" }

    public init(kind: Kind, key: String, title: String) {
        self.kind = kind
        self.key = key
        self.title = title
    }

    public static func ingredient(_ ingredient: CatalogIngredient) -> RecipeFilter {
        RecipeFilter(kind: .ingredient, key: ingredient.key, title: ingredient.name)
    }

    public static func category(_ name: String) -> RecipeFilter {
        RecipeFilter(kind: .category, key: name.lowercased(), title: name)
    }

    /// What the typed text could be filtered by, ingredients first.
    ///
    /// Anything already applied is left out — there is no point offering a
    /// filter twice.
    public static func suggestions(
        for text: String,
        catalog: IngredientCatalog,
        categories: [String],
        applied: [RecipeFilter] = [],
        limit: Int = 5
    ) -> [RecipeFilter] {
        let query = IngredientCatalog.normalize(text)
        guard query.count >= 2 else { return [] }

        let matchingCategories = categories
            .filter { $0.lowercased().contains(query) }
            .map(RecipeFilter.category)

        let matchingIngredients = catalog
            .suggestions(for: text, limit: limit)
            .map(RecipeFilter.ingredient)

        let appliedIDs = Set(applied.map(\.id))
        return Array(
            (matchingIngredients + matchingCategories)
                .filter { !appliedIDs.contains($0.id) }
                .prefix(limit)
        )
    }
}
