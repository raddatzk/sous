import Foundation

/// A known ingredient: one canonical name, the ways it gets written, what
/// kind of thing it is, and — for a variety — what it is a variety of.
public struct CatalogIngredient: Identifiable, Hashable, Sendable, Codable {
    public var id: String { key }

    /// The name shown and stored: "Tomate".
    public var name: String
    /// Other spellings that mean the same thing: "Tomaten", "tomate".
    ///
    /// Spellings only. A variety is not a spelling — "Cocktailtomaten" used
    /// to sit in here beside "Tomaten", which is what let the shopping list
    /// turn 200 g of cocktail tomatoes into an anonymous part of 700 g of
    /// tomatoes. Varieties are their own entries now, with `parentName` set.
    public var aliases: [String]
    public var category: IngredientCategory
    /// The ingredient this one is a variety of, by name. One level deep: a
    /// variety of a variety is a taxonomy, and the app has no use for one.
    public var parentName: String?

    /// Normalized name, used as the identity.
    public var key: String { IngredientCatalog.normalize(name) }

    /// The key this ingredient bundles under on the shopping list: its
    /// parent's, so a variety takes its place under the ingredient it is one
    /// of, rather than beside it.
    public var groupKey: String {
        parentName.map(IngredientCatalog.normalize) ?? key
    }

    public init(
        name: String, aliases: [String] = [], category: IngredientCategory,
        parentName: String? = nil
    ) {
        self.name = name
        self.aliases = aliases
        self.category = category
        self.parentName = parentName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            aliases: try container.decodeIfPresent([String].self, forKey: .aliases) ?? [],
            category: try container.decode(IngredientCategory.self, forKey: .category),
            parentName: try container.decodeIfPresent(String.self, forKey: .parentName)
        )
    }

    /// Every spelling this ingredient answers to, normalized.
    var keys: [String] {
        ([name] + aliases).map(IngredientCatalog.normalize)
    }
}
