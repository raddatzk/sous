import Foundation

/// A recipe, as one self-contained aggregate.
///
/// Ingredients and steps are stored inline rather than referenced: the whole
/// recipe serializes as a single unit, which is what the sync layer needs in
/// order to encrypt it as one blob.
public struct Recipe: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var summary: String?
    /// How many servings the amounts in `ingredients` refer to.
    public var servings: Int
    public var ingredients: [RecipeIngredient]
    public var steps: [RecipeStep]
    public var categories: [String]
    public var isFavorite: Bool
    public var wantToCook: Bool
    public var notes: String?
    public var source: RecipeSource
    public var prepTimeSeconds: Int?
    public var cookTimeSeconds: Int?

    /// The user who created it. Optional until user management exists.
    public var createdBy: UUID?
    public var createdAt: Date
    public var updatedAt: Date
    /// Tombstone. A deleted recipe keeps its row so the deletion can sync.
    public var deletedAt: Date?

    public var isDeleted: Bool { deletedAt != nil }

    public init(
        id: UUID = UUID(),
        title: String,
        summary: String? = nil,
        servings: Int = 2,
        ingredients: [RecipeIngredient] = [],
        steps: [RecipeStep] = [],
        categories: [String] = [],
        isFavorite: Bool = false,
        wantToCook: Bool = false,
        notes: String? = nil,
        source: RecipeSource = .manual,
        prepTimeSeconds: Int? = nil,
        cookTimeSeconds: Int? = nil,
        createdBy: UUID? = nil,
        createdAt: Date = .nowInSyncPrecision,
        updatedAt: Date = .nowInSyncPrecision,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.servings = servings
        self.ingredients = ingredients
        self.steps = steps
        self.categories = categories
        self.isFavorite = isFavorite
        self.wantToCook = wantToCook
        self.notes = notes
        self.source = source
        self.prepTimeSeconds = prepTimeSeconds
        self.cookTimeSeconds = cookTimeSeconds
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// Ingredient groups in the order they first appear, with ungrouped
    /// ingredients under `nil`.
    public var ingredientGroups: [(group: String?, ingredients: [RecipeIngredient])] {
        var order: [String?] = []
        var buckets: [String?: [RecipeIngredient]] = [:]
        for ingredient in ingredients {
            if buckets[ingredient.group] == nil {
                order.append(ingredient.group)
                buckets[ingredient.group] = []
            }
            buckets[ingredient.group]?.append(ingredient)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// Recipes this one references, through either ingredients or steps.
    public var linkedRecipeIDs: Set<UUID> {
        var ids = Set(ingredients.compactMap(\.linkedRecipeID))
        ids.formUnion(steps.compactMap(\.linkedRecipeID))
        return ids
    }
}
