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
    /// What kind of thing this is, *resolved*: the category written for it,
    /// or — for a variety that says nothing — the nearest ancestor's. Every
    /// reader that sorts, groups or filters by category reads this one, and
    /// none of them has to know where it came from. Filled in by
    /// ``IngredientCatalog``; until then it is `ownCategory ?? .other`.
    public var category: IngredientCategory
    /// The category as written for this ingredient, `nil` where it inherits.
    /// Set means overridden, empty means inherited — one rule for every field
    /// a variety takes from its parent (catalog target, decision B). Of the
    /// 60 shipped varieties not one differed from its parent, so none of them
    /// writes one any more.
    public var ownCategory: IngredientCategory?
    /// The ingredient this one is a variety of, by name. Any depth: a variety
    /// inherits from the nearest ancestor that has what it lacks.
    public var parentName: String?

    /// Normalized name, used as the identity.
    public var key: String { IngredientCatalog.normalize(name) }

    /// The key this ingredient bundles under on the shopping list: its
    /// parent's, so a variety takes its place under the ingredient it is one
    /// of, rather than beside it.
    public var groupKey: String {
        parentName.map(IngredientCatalog.normalize) ?? key
    }

    /// `category` here is the *written* one; pass `nil` for a variety that
    /// should take its parent's. A non-optional value still reads naturally
    /// at every call site that names one.
    public init(
        name: String, aliases: [String] = [], category: IngredientCategory? = nil,
        parentName: String? = nil
    ) {
        self.name = name
        self.aliases = aliases
        self.ownCategory = category
        self.category = category ?? .other
        self.parentName = parentName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            aliases: try container.decodeIfPresent([String].self, forKey: .aliases) ?? [],
            // The written one where a file carries both; an older file carries
            // only `category`, which was the written one by definition.
            category: try container.decodeIfPresent(IngredientCategory.self, forKey: .ownCategory)
                ?? container.decodeIfPresent(IngredientCategory.self, forKey: .category),
            parentName: try container.decodeIfPresent(String.self, forKey: .parentName)
        )
    }

    /// Every spelling this ingredient answers to, normalized.
    var keys: [String] {
        ([name] + aliases).map(IngredientCatalog.normalize)
    }
}
