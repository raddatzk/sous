import Foundation

/// Copies a household's library from one set of stores into another.
///
/// Written against the protocols on the reading side, so it does not know
/// that SwiftData is on the other side. The writing side is the concrete Core
/// Data store, because a migration needs doors the ordinary write path does
/// not have: ones that leave `updatedAt` exactly as they found it, and that
/// write a shopping list back with its check marks and positions intact.
///
/// **Idempotent by row, not by flag.** Every row is compared against what the
/// destination already holds and skipped when that copy is current. A marker
/// saying "migration done" would be a lie after a crash halfway through; this
/// can be run again, and again after the cook has kept working in the old
/// store, and it converges either way. It is the same rule the sync applies
/// later, which is not a coincidence — it is the same problem.
///
/// **The source is never touched.** Nothing is deleted, nothing is renamed.
/// If any of this goes wrong the library is still where it was.
public enum RecipeStoreMigration {
    /// The stores to read, any implementation.
    public struct Source: Sendable {
        public var recipes: any RecipeStore
        public var images: any RecipeImageStore
        public var mealPlan: (any MealPlanStore)?
        public var vocabulary: (any VocabularyStore)?
        public var shopping: (any ShoppingListStore)?
        public var amountReviews: (any RecipeAmountReviewStore)?
        public var ingredientReviews: (any RecipeIngredientReviewStore)?

        public init(
            recipes: any RecipeStore,
            images: any RecipeImageStore,
            mealPlan: (any MealPlanStore)? = nil,
            vocabulary: (any VocabularyStore)? = nil,
            shopping: (any ShoppingListStore)? = nil,
            amountReviews: (any RecipeAmountReviewStore)? = nil,
            ingredientReviews: (any RecipeIngredientReviewStore)? = nil
        ) {
            self.recipes = recipes
            self.images = images
            self.mealPlan = mealPlan
            self.vocabulary = vocabulary
            self.shopping = shopping
            self.amountReviews = amountReviews
            self.ingredientReviews = ingredientReviews
        }
    }

    /// The stores to write, concrete because of the doors.
    public struct Destination: Sendable {
        public var recipes: CoreDataRecipeStore
        public var images: CoreDataRecipeImageStore
        public var mealPlan: CoreDataMealPlanStore?
        public var vocabulary: CoreDataVocabularyStore?
        public var shopping: CoreDataShoppingListStore?
        public var amountReviews: CoreDataRecipeAmountReviewStore?
        public var ingredientReviews: CoreDataRecipeIngredientReviewStore?

        public init(
            recipes: CoreDataRecipeStore,
            images: CoreDataRecipeImageStore,
            mealPlan: CoreDataMealPlanStore? = nil,
            vocabulary: CoreDataVocabularyStore? = nil,
            shopping: CoreDataShoppingListStore? = nil,
            amountReviews: CoreDataRecipeAmountReviewStore? = nil,
            ingredientReviews: CoreDataRecipeIngredientReviewStore? = nil
        ) {
            self.recipes = recipes
            self.images = images
            self.mealPlan = mealPlan
            self.vocabulary = vocabulary
            self.shopping = shopping
            self.amountReviews = amountReviews
            self.ingredientReviews = ingredientReviews
        }
    }

    public struct Report: Hashable, Sendable {
        public var recipesCopied = 0
        public var recipesAlreadyCurrent = 0
        public var groupsCopied = 0
        public var imagesCopied = 0
        public var imagesAlreadyThere = 0
        public var planEntriesCopied = 0
        public var vocabularyCopied = 0
        public var shoppingItemsCopied = 0
        public var reviewMarksCopied = 0

        public var isEmpty: Bool {
            recipesCopied == 0 && groupsCopied == 0 && imagesCopied == 0
                && planEntriesCopied == 0 && vocabularyCopied == 0
                && shoppingItemsCopied == 0 && reviewMarksCopied == 0
        }
    }

    @discardableResult
    public static func run(from source: Source, to destination: Destination) async throws -> Report {
        var report = Report()

        // Groups first: a member's `searchText` is rebuilt on the way in and
        // folds in the group's title, so a member adopted before its group
        // would go in unfindable by the name of the dish.
        for (group, _) in try await source.recipes.variantGroups() {
            let existing = try await destination.recipes.variantGroup(id: group.id)
            guard existing.map({ $0.updatedAt < group.updatedAt }) ?? true else { continue }
            try await destination.recipes.adoptVariantGroup(group)
            report.groupsCopied += 1
        }

        // The vocabulary comes before the recipes: what a cook taught an
        // ingredient decides how a recipe's search index reads, and an index
        // built against a catalog that has not arrived yet is one word short.
        if let sourceVocabulary = source.vocabulary, let target = destination.vocabulary {
            let existing = Set(try await target.entries().map(\.key))
            for entry in try await sourceVocabulary.entries() where !existing.contains(entry.key) {
                try await target.adopt(entry)
                report.vocabularyCopied += 1
            }
        }

        // Tombstoned recipes included. A deletion that has not synced yet is
        // still something the other devices need to hear about, and one that
        // can still be undone is still in the cook's trash.
        let recipes = try await source.recipes.recipes(
            matching: RecipeQuery(includeDeleted: true, sort: .titleAscending)
        )
        for recipe in recipes {
            let existing = try await destination.recipes.recipe(id: recipe.id)
            if let existing, existing.updatedAt >= recipe.updatedAt {
                report.recipesAlreadyCurrent += 1
            } else {
                try await destination.recipes.adopt(recipe)
                report.recipesCopied += 1
            }

            // Pictures follow their recipe, in the order the source keeps
            // them — `thumbnails(for:)` is sorted, so the position in that
            // list is the sort order, and it survives the copy.
            let thumbnails = try await source.images.thumbnails(for: recipe.id)
            for (index, entry) in thumbnails.enumerated() {
                if try await destination.images.thumbnail(id: entry.id) != nil {
                    report.imagesAlreadyThere += 1
                    continue
                }
                guard let data = try await source.images.image(id: entry.id) else { continue }
                try await destination.images.adopt(
                    id: entry.id,
                    recipeID: recipe.id,
                    data: data,
                    thumbnail: entry.data,
                    sortOrder: index
                )
                report.imagesCopied += 1
            }

            report.reviewMarksCopied += try await copyReviewMarks(for: recipe, from: source, to: destination)
        }

        // Plan entries, dated and undated. Tombstoned ones do not come
        // along — the protocol does not hand them out, and unlike a recipe
        // there is no trash a plan entry can be restored from.
        if let sourcePlan = source.mealPlan, let target = destination.mealPlan {
            // Deduplicated by id rather than trusting the two calls to be
            // disjoint: asked for `distantPast...distantFuture`, the SwiftData
            // store hands back the undated entries as well — its predicate
            // coalesces a missing day to a date inside any window that wide —
            // and the pool would then be adopted twice. Harmless for the rows,
            // since adopting is an upsert, but the count would lie.
            var byID: [UUID: MealPlanEntry] = [:]
            for entry in try await sourcePlan.entries(for: [.distantPast, .distantFuture]) {
                byID[entry.id] = entry
            }
            for entry in try await sourcePlan.poolEntries() {
                byID[entry.id] = entry
            }
            for entry in byID.values {
                try await target.adopt(entry)
                report.planEntriesCopied += 1
            }
        }

        // The shopping list arrives whole or not at all: it is one document,
        // and half of it would be a list with demand pointing at recipes that
        // are not on it.
        if let sourceShopping = source.shopping, let target = destination.shopping {
            let snapshot = try await sourceShopping.snapshot()
            if !snapshot.items.isEmpty || !snapshot.planEntries.isEmpty {
                try await target.adopt(snapshot)
                report.shoppingItemsCopied += snapshot.items.count
            }
        }

        return report
    }

    /// Both review marks for one recipe.
    ///
    /// Re-marked rather than copied, and only where the stored hash still
    /// matches the text: the mark means "somebody looked at this version and
    /// settled it", so a hash that no longer matches is a question that has
    /// reopened anyway, and carrying it across would silence it wrongly.
    private static func copyReviewMarks(
        for recipe: Recipe,
        from source: Source,
        to destination: Destination
    ) async throws -> Int {
        let current = RecipeContentHash.hash(for: recipe)
        var copied = 0

        if let sourceMarks = source.amountReviews, let target = destination.amountReviews,
           try await sourceMarks.reviewedHash(for: recipe.id) == current,
           try await target.reviewedHash(for: recipe.id) != current {
            try await target.markReviewed(recipe)
            copied += 1
        }
        if let sourceMarks = source.ingredientReviews, let target = destination.ingredientReviews,
           try await sourceMarks.reviewedHash(for: recipe.id) == current,
           try await target.reviewedHash(for: recipe.id) != current {
            try await target.markReviewed(recipe)
            copied += 1
        }
        return copied
    }
}
