import Foundation

/// A recipe, as one self-contained aggregate.
///
/// Ingredients and instructions are stored as written text, one entry per
/// line, the same way Mela's file format does it. Text is the truth and the
/// structure is derived from it on demand, which means nothing the user typed
/// can be lost by a parser that reads a line differently than intended —
/// "3-4 Tomaten" stays "3-4 Tomaten" even though scaling only understands
/// the lower bound. It also makes importing a Mela library a direct copy.
public struct Recipe: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var summary: String?
    /// How many servings the amounts in `ingredients` refer to.
    public var servings: Int
    /// Ingredients as written, one per line. See ``IngredientParser``.
    public var ingredientsText: String
    /// Instructions as written, one step per line. See ``StepParser``.
    public var instructionsText: String
    public var categories: [String]
    public var isFavorite: Bool
    public var wantToCook: Bool
    /// A recipe that belongs to another one — the tortellini for the
    /// tortellini pan, a dough for the tart above it.
    ///
    /// Marked by hand rather than inferred from being linked: a tomato sauce
    /// can stand on its own *and* be used by the lasagne, and inferring would
    /// make it vanish from the library the moment someone references it.
    public var isComponent: Bool
    public var notes: String?
    public var source: RecipeSource
    public var prepTimeSeconds: Int?
    public var cookTimeSeconds: Int?

    /// Pictures of the dish, referenced rather than embedded — see
    /// ``RecipeImageStore`` for why they live outside the aggregate.
    public var imageIDs: [UUID]

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
        ingredientsText: String = "",
        instructionsText: String = "",
        categories: [String] = [],
        isFavorite: Bool = false,
        wantToCook: Bool = false,
        isComponent: Bool = false,
        notes: String? = nil,
        source: RecipeSource = .manual,
        prepTimeSeconds: Int? = nil,
        cookTimeSeconds: Int? = nil,
        imageIDs: [UUID] = [],
        createdBy: UUID? = nil,
        createdAt: Date = .nowInSyncPrecision,
        updatedAt: Date = .nowInSyncPrecision,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.servings = servings
        self.ingredientsText = ingredientsText
        self.instructionsText = instructionsText
        self.categories = categories
        self.isFavorite = isFavorite
        self.wantToCook = wantToCook
        self.isComponent = isComponent
        self.notes = notes
        self.source = source
        self.prepTimeSeconds = prepTimeSeconds
        self.cookTimeSeconds = cookTimeSeconds
        self.imageIDs = imageIDs
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var ingredients: [RecipeIngredient] {
        IngredientParser.parse(ingredientsText)
    }

    public var steps: [RecipeStep] {
        StepParser.parse(instructionsText)
    }

    /// Ingredient groups in the order they first appear, with ungrouped
    /// ingredients under `nil`.
    public func ingredientGroups(
        scaledToServings targetServings: Int? = nil
    ) -> [(group: String?, ingredients: [RecipeIngredient])] {
        var order: [String?] = []
        var buckets: [String?: [RecipeIngredient]] = [:]
        for ingredient in scaledIngredients(toServings: targetServings ?? servings) {
            if buckets[ingredient.group] == nil {
                order.append(ingredient.group)
                buckets[ingredient.group] = []
            }
            buckets[ingredient.group]?.append(ingredient)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// Steps grouped by their heading, in the order they appear.
    ///
    /// Numbering restarts within each group — a heading in the instructions
    /// starts a new sequence, the way Mela treats it.
    public var stepGroups: [(group: String?, steps: [RecipeStep])] {
        var order: [String?] = []
        var buckets: [String?: [RecipeStep]] = [:]
        for step in steps {
            if buckets[step.group] == nil {
                order.append(step.group)
                buckets[step.group] = []
            }
            buckets[step.group]?.append(step)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    /// Whether there is anything to show at all.
    public var isEmpty: Bool {
        ingredientsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && instructionsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
