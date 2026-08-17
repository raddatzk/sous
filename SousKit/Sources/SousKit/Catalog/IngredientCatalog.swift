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

    public init(ingredients: [CatalogIngredient]) {
        self.ingredients = ingredients.sorted { $0.name < $1.name }
        byKey = [:]
        for ingredient in ingredients {
            for key in ingredient.keys where byKey[key] == nil {
                byKey[key] = ingredient
            }
        }
    }

    /// The catalog shipped with the app.
    public static let bundled: IngredientCatalog = {
        guard let url = Bundle.module.url(forResource: "ingredients", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([CatalogIngredient].self, from: data)
        else {
            assertionFailure("The bundled ingredient catalog is missing or unreadable")
            return IngredientCatalog(ingredients: [])
        }
        return IngredientCatalog(ingredients: entries)
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

        var prefixed: [CatalogIngredient] = []
        var contained: [CatalogIngredient] = []
        for ingredient in ingredients {
            if ingredient.keys.contains(where: { $0.hasPrefix(query) }) {
                prefixed.append(ingredient)
            } else if ingredient.keys.contains(where: { $0.contains(query) }) {
                contained.append(ingredient)
            }
        }
        return Array((prefixed + contained).prefix(limit))
    }

    /// Lowercased and stripped of surrounding whitespace. Comparison is on
    /// this form throughout, so "Rote Bete" and "rote bete" are one thing.
    public static func normalize(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
