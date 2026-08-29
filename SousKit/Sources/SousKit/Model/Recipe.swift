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
    /// What a recipe can be written for. Wide enough for a tray of sixty
    /// biscuits, which is a yield like any other, and narrow enough that a
    /// misread number stays visible as one.
    public static let servingsRange = 1...200

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
    public var notes: String?
    public var source: RecipeSource
    /// Hands-on work before anything is on the heat.
    public var prepTimeSeconds: Int?
    /// Time on the stove or in the oven.
    public var cookTimeSeconds: Int?
    /// From starting to finished, waiting included.
    ///
    /// Not the sum of the other two, and that is the point: dough proves,
    /// tiramisu sets, a roast sits in the oven for two hours while the cook
    /// does nothing. Without this, a recipe cannot answer the question that
    /// decides whether it happens tonight — when do I have to start?
    public var totalTimeSeconds: Int?

    /// Pictures of the dish, referenced rather than embedded — see
    /// ``RecipeImageStore`` for why they live outside the aggregate.
    public var imageIDs: [UUID]

    /// The meals this recipe suits, where somebody said so.
    ///
    /// `nil` means nobody has: the planner falls back to a cached AI guess
    /// and, failing that, treats the recipe as dinner-eligible — main dishes
    /// are the majority, and the proposal sheet catches the strays. There is
    /// no explicit empty state: unticking every chip reads as "decide for
    /// me", so an empty set normalizes to `nil` at the door.
    public var suitableSlots: Set<MealSlot>?

    /// The cook's own word on how much work this is, where they gave one.
    ///
    /// `nil` means nobody has said, and then ``RecipeEffort`` reads it off
    /// the recipe's structure instead — the same shape as `suitableSlots`
    /// above, and for the same reason: a judgment that is usually worth
    /// deriving and occasionally worth overruling.
    ///
    /// A rung rather than a number, because that is what a person has an
    /// opinion about. Nobody looks at a dish and thinks "twenty-three"; they
    /// think "that is a Saturday". And overruling is not a correction of the
    /// arithmetic — the structure really is what it is — it is the cook
    /// saying the structure missed the point, which for effort it can: a
    /// croissant is five ingredients and hard.
    public var effortOverride: RecipeEffort.Level?

    /// The ``VariantGroup`` this recipe is one version of, if it is.
    ///
    /// On the member rather than as a list on the group, so that dissolving
    /// a group is clearing a field and nothing above has to keep two sides
    /// of a relation in step. A recipe is a full recipe either way: nothing
    /// about it is inherited from its siblings, and the group has no say in
    /// what it contains.
    public var variantGroupID: UUID?

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
        notes: String? = nil,
        source: RecipeSource = .manual,
        prepTimeSeconds: Int? = nil,
        cookTimeSeconds: Int? = nil,
        totalTimeSeconds: Int? = nil,
        imageIDs: [UUID] = [],
        suitableSlots: Set<MealSlot>? = nil,
        effortOverride: RecipeEffort.Level? = nil,
        variantGroupID: UUID? = nil,
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
        self.notes = notes
        self.source = source
        self.prepTimeSeconds = prepTimeSeconds
        self.cookTimeSeconds = cookTimeSeconds
        self.totalTimeSeconds = totalTimeSeconds
        self.imageIDs = imageIDs
        self.suitableSlots = suitableSlots.flatMap { $0.isEmpty ? nil : $0 }
        self.effortOverride = effortOverride
        self.variantGroupID = variantGroupID
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    // MARK: - Time

    /// Time the cook actually spends working, which is what decides whether
    /// a recipe fits into an evening.
    public var activeTimeSeconds: Int? {
        let total = (prepTimeSeconds ?? 0) + (cookTimeSeconds ?? 0)
        return total > 0 ? total : nil
    }

    /// How long it takes from start to finish. Falls back to the work if
    /// nobody wrote down a total, which is the best guess available.
    public var elapsedTimeSeconds: Int? {
        totalTimeSeconds ?? activeTimeSeconds
    }

    /// Time the dish needs without the cook — proving, marinating, cooling.
    /// Derived rather than entered: it is whatever the total has over the
    /// work, and asking for it twice invites the two to disagree.
    public var restingTimeSeconds: Int? {
        guard let elapsed = elapsedTimeSeconds, let active = activeTimeSeconds else { return nil }
        let resting = elapsed - active
        return resting > 0 ? resting : nil
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
