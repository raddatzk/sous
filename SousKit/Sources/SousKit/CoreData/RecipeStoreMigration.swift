import Foundation

/// Copies a library from one store into another.
///
/// Written against the protocols on the reading side, so it does not know
/// that the source is SwiftData and will not have to be rewritten when the
/// remaining stores follow. The writing side is the concrete Core Data store,
/// because a migration needs a door the ordinary write path does not have:
/// one that leaves `updatedAt` exactly as it found it.
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
    public struct Report: Hashable, Sendable {
        public var recipesCopied = 0
        public var recipesAlreadyCurrent = 0
        public var groupsCopied = 0
        public var imagesCopied = 0
        public var imagesAlreadyThere = 0

        public var isEmpty: Bool {
            recipesCopied == 0 && groupsCopied == 0 && imagesCopied == 0
        }
    }

    /// - Parameters:
    ///   - source: read through the protocol; any implementation will do.
    ///   - sourceImages: the pictures belonging to `source`.
    ///   - destination: written through `adopt`, which preserves timestamps.
    @discardableResult
    public static func run(
        from source: any RecipeStore,
        images sourceImages: any RecipeImageStore,
        to destination: CoreDataRecipeStore,
        images destinationImages: CoreDataRecipeImageStore
    ) async throws -> Report {
        var report = Report()

        // Groups first: a member's `searchText` is rebuilt on the way in and
        // folds in the group's title, so a member adopted before its group
        // would go in unfindable by the name of the dish.
        for (group, _) in try await source.variantGroups() {
            let existing = try await destination.variantGroup(id: group.id)
            guard existing.map({ $0.updatedAt < group.updatedAt }) ?? true else { continue }
            try await destination.adoptVariantGroup(group)
            report.groupsCopied += 1
        }

        // Tombstoned recipes included. A deletion that has not synced yet is
        // still something the other devices need to hear about, and one that
        // can still be undone is still in the cook's trash.
        let recipes = try await source.recipes(
            matching: RecipeQuery(includeDeleted: true, sort: .titleAscending)
        )
        for recipe in recipes {
            let existing = try await destination.recipe(id: recipe.id)
            if let existing, existing.updatedAt >= recipe.updatedAt {
                report.recipesAlreadyCurrent += 1
            } else {
                try await destination.adopt(recipe)
                report.recipesCopied += 1
            }

            // Pictures follow their recipe, in the order the source keeps
            // them — `thumbnails(for:)` is sorted, so the position in that
            // list is the sort order, and it survives the copy.
            let thumbnails = try await sourceImages.thumbnails(for: recipe.id)
            for (index, entry) in thumbnails.enumerated() {
                if try await destinationImages.thumbnail(id: entry.id) != nil {
                    report.imagesAlreadyThere += 1
                    continue
                }
                guard let data = try await sourceImages.image(id: entry.id) else { continue }
                try await destinationImages.adopt(
                    id: entry.id,
                    recipeID: recipe.id,
                    data: data,
                    thumbnail: entry.data,
                    sortOrder: index
                )
                report.imagesCopied += 1
            }
        }

        return report
    }
}
