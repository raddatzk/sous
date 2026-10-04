import Foundation

/// Copies a household's library from one set of stores into another.
///
/// Written against the protocols on the reading side, so it does not know
/// that SwiftData is on the other side. The writing side is the concrete Core
/// Data store, because a migration needs doors the ordinary write path does
/// not have: ones that leave `updatedAt` exactly as they found it, and that
/// write a shopping list back with its check marks and positions intact.
///
/// **Idempotent by row, finished by flag.** Every row is compared against
/// what the destination already holds and skipped when that copy is current,
/// so a run cut short halfway finishes on the next attempt. Once the cook
/// works in the destination, though, a repeat run is no longer harmless: a
/// plan entry moved or removed there, a shopping item removed, a recipe
/// erased would come back from the old store, which nothing writes to any
/// more. So the app calls ``runOnce(from:to:defaults:)``, which records the
/// first run that completes and skips every later one.
///
/// **The source is never touched.** Nothing is deleted, nothing is renamed.
/// If any of this goes wrong the library is still where it was.
public enum RecipeStoreMigration {
    /// The stores to read, any implementation.
    public struct Source: Sendable {
        public var recipes: any RecipeStore
        public var images: any RecipeImageStore
        public var mealPlan: (any MealPlanStore)?
        public var shopping: (any ShoppingListStore)?

        public init(
            recipes: any RecipeStore,
            images: any RecipeImageStore,
            mealPlan: (any MealPlanStore)? = nil,
            shopping: (any ShoppingListStore)? = nil
        ) {
            self.recipes = recipes
            self.images = images
            self.mealPlan = mealPlan
            self.shopping = shopping
        }
    }

    /// The stores to write, concrete because of the doors.
    public struct Destination: Sendable {
        public var recipes: CoreDataRecipeStore
        public var images: CoreDataRecipeImageStore
        public var mealPlan: CoreDataMealPlanStore?
        public var shopping: CoreDataShoppingListStore?

        public init(
            recipes: CoreDataRecipeStore,
            images: CoreDataRecipeImageStore,
            mealPlan: CoreDataMealPlanStore? = nil,
            shopping: CoreDataShoppingListStore? = nil
        ) {
            self.recipes = recipes
            self.images = images
            self.mealPlan = mealPlan
            self.shopping = shopping
        }
    }

    public struct Report: Hashable, Sendable {
        public var recipesCopied = 0
        public var recipesAlreadyCurrent = 0
        public var groupsCopied = 0
        public var imagesCopied = 0
        public var imagesAlreadyThere = 0
        public var planEntriesCopied = 0
        public var shoppingItemsCopied = 0

        public var isEmpty: Bool {
            recipesCopied == 0 && groupsCopied == 0 && imagesCopied == 0
                && planEntriesCopied == 0 && shoppingItemsCopied == 0
        }
    }

    /// The `UserDefaults` key that records a completed migration.
    public static let finishedKey = "recipeStoreMigration.finished"

    /// Runs the migration until one run has completed, and never after.
    ///
    /// Only a run that returns is recorded; one that throws or is cut short
    /// leaves the flag unset, and the next launch carries on from where the
    /// rows say it stopped. Returns `nil` when the migration had finished
    /// before.
    @discardableResult
    public static func runOnce(
        from source: Source, to destination: Destination, defaults: UserDefaults
    ) async throws -> Report? {
        guard !defaults.bool(forKey: finishedKey) else { return nil }
        let report = try await run(from: source, to: destination)
        defaults.set(true, forKey: finishedKey)
        return report
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
}
