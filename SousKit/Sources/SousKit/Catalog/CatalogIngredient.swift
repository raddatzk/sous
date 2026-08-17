import Foundation

/// A known ingredient: one canonical name, the ways it gets written, and
/// what kind of thing it is.
public struct CatalogIngredient: Identifiable, Hashable, Sendable, Codable {
    public var id: String { key }

    /// The name shown and stored: "Tomate".
    public var name: String
    /// Other spellings that mean the same thing: "Tomaten", "Cocktailtomaten".
    public var aliases: [String]
    public var category: IngredientCategory

    /// Normalized name, used as the identity.
    public var key: String { IngredientCatalog.normalize(name) }

    public init(name: String, aliases: [String] = [], category: IngredientCategory) {
        self.name = name
        self.aliases = aliases
        self.category = category
    }

    /// Every spelling this ingredient answers to, normalized.
    var keys: [String] {
        ([name] + aliases).map(IngredientCatalog.normalize)
    }
}
