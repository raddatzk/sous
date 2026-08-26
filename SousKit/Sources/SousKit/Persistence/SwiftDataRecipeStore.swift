import Foundation
import SwiftData

/// A ``RecipeStore`` backed by SwiftData.
///
/// A `ModelActor` because `@Model` instances are not `Sendable` and must not
/// leave the context that owns them — everything crossing the boundary is a
/// domain value.
@ModelActor
public actor SwiftDataRecipeStore: RecipeStore {
    public func recipes(matching query: RecipeQuery) async throws -> [Recipe] {
        var descriptor = FetchDescriptor<StoredRecipe>(predicate: Self.predicate(for: query))
        descriptor.sortBy = switch query.sort {
        case .titleAscending: [SortDescriptor(\.title, comparator: .localizedStandard)]
        case .recentlyUpdated: [SortDescriptor(\.updatedAt, order: .reverse)]
        }

        var results = try modelContext.fetch(descriptor)
        // The remaining filters are applied in memory on purpose: SwiftData
        // does not reliably translate captured booleans inside a predicate,
        // and a library of recipes is small enough that it does not matter.
        if query.onlyFavorites {
            results = results.filter(\.isFavorite)
        }
        if query.onlyWantToCook {
            results = results.filter(\.wantToCook)
        }
        // All filters must apply: two ingredients means recipes using both.
        for filter in query.filters {
            switch filter.kind {
            case .ingredient:
                results = results.filter { $0.ingredientKeys.contains(filter.key) }
            case .category:
                results = results.filter { recipe in
                    recipe.categories.contains { $0.lowercased() == filter.key }
                }
            }
        }
        return results.map(\.domainValue)
    }

    public func recipe(id: UUID) async throws -> Recipe? {
        try stored(id: id)?.domainValue
    }

    @discardableResult
    public func save(_ recipe: Recipe) async throws -> Recipe {
        var updated = recipe
        updated.updatedAt = .nowInSyncPrecision

        let groupTitle = try recipe.variantGroupID.flatMap { try storedGroup(id: $0) }?.title
        if let existing = try stored(id: recipe.id) {
            existing.apply(updated, variantGroupTitle: groupTitle)
        } else {
            modelContext.insert(StoredRecipe(updated, variantGroupTitle: groupTitle))
        }
        try modelContext.save()
        return updated
    }

    public func delete(id: UUID) async throws {
        guard let existing = try stored(id: id) else { return }
        let now = Date.nowInSyncPrecision
        existing.deletedAt = now
        existing.updatedAt = now
        try modelContext.save()
    }

    public func erase(id: UUID) async throws {
        guard let existing = try stored(id: id) else { return }
        let groupID = existing.variantGroupID
        modelContext.delete(existing)
        if let groupID { try collectVariantGroup(id: groupID) }
        try modelContext.save()
    }

    public func restore(id: UUID) async throws {
        guard let existing = try stored(id: id) else { return }
        existing.deletedAt = nil
        existing.updatedAt = .nowInSyncPrecision
        try modelContext.save()
    }

    public func categories() async throws -> [String] {
        let descriptor = FetchDescriptor<StoredRecipe>(predicate: #Predicate { $0.deletedAt == nil })
        let all = try modelContext.fetch(descriptor).flatMap(\.categories)
        return Array(Set(all)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func categoryCounts() async throws -> [(name: String, count: Int)] {
        var counts: [String: (name: String, count: Int)] = [:]
        for recipe in try liveRecipes() {
            for category in recipe.categories {
                let key = category.lowercased()
                counts[key, default: (category, 0)].count += 1
            }
        }
        return counts.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func renameCategory(_ name: String, to newName: String) async throws {
        let target = newName.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        let key = name.lowercased()

        for recipe in try liveRecipes() where recipe.categories.contains(where: { $0.lowercased() == key }) {
            var updated = recipe.domainValue
            // Renaming onto a name a recipe already has merges the two
            // rather than listing it twice.
            var renamed = updated.categories.map { $0.lowercased() == key ? target : $0 }
            var seen = Set<String>()
            renamed = renamed.filter { seen.insert($0.lowercased()).inserted }

            updated.categories = renamed
            updated.updatedAt = .nowInSyncPrecision
            // Only the categories change here. Going through `apply` would
            // also rebuild the ingredient index, and this store has no
            // access to the cook's own catalog to do that faithfully.
            recipe.categories = updated.categories
            recipe.updatedAt = updated.updatedAt
            recipe.searchText = try StoredRecipe.searchText(
                for: updated,
                variantGroupTitle: variantGroupTitle(of: recipe)
            )
        }
        try modelContext.save()
    }

    public func deleteCategory(_ name: String) async throws {
        let key = name.lowercased()

        for recipe in try liveRecipes() where recipe.categories.contains(where: { $0.lowercased() == key }) {
            var updated = recipe.domainValue
            updated.categories.removeAll { $0.lowercased() == key }
            updated.updatedAt = .nowInSyncPrecision
            recipe.categories = updated.categories
            recipe.updatedAt = updated.updatedAt
            recipe.searchText = try StoredRecipe.searchText(
                for: updated,
                variantGroupTitle: variantGroupTitle(of: recipe)
            )
        }
        try modelContext.save()
    }

    // MARK: - Variant groups

    public func variantGroups() async throws -> [(group: VariantGroup, liveMembers: Int)] {
        var counts: [UUID: Int] = [:]
        for recipe in try liveRecipes() {
            guard let groupID = recipe.variantGroupID else { continue }
            counts[groupID, default: 0] += 1
        }
        return try modelContext.fetch(FetchDescriptor<StoredVariantGroup>())
            .map { ($0.domainValue, counts[$0.id] ?? 0) }
    }

    public func variantGroup(id: UUID) async throws -> VariantGroup? {
        try storedGroup(id: id)?.domainValue
    }

    public func variantGroupMembers(id: UUID) async throws -> [Recipe] {
        try members(ofGroup: id)
            .filter { $0.deletedAt == nil }
            .map(\.domainValue)
            .sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func saveVariantGroup(_ group: VariantGroup) async throws -> VariantGroup {
        var updated = group
        updated.updatedAt = .nowInSyncPrecision

        if let existing = try storedGroup(id: group.id) {
            let wasRenamed = existing.title != updated.title
            existing.apply(updated)
            // The title lives in every member's search index too. Rewriting
            // it here rather than asking the members to notice is the same
            // bargain `renameCategory` makes.
            if wasRenamed {
                for member in try members(ofGroup: group.id) {
                    member.searchText = StoredRecipe.searchText(
                        for: member.domainValue,
                        variantGroupTitle: updated.title
                    )
                }
            }
        } else {
            modelContext.insert(StoredVariantGroup(updated))
        }
        try modelContext.save()
        return updated
    }

    public func dissolveVariantGroup(id: UUID) async throws {
        let now = Date.nowInSyncPrecision
        for member in try members(ofGroup: id) {
            member.variantGroupID = nil
            member.updatedAt = now
            member.searchText = StoredRecipe.searchText(for: member.domainValue)
        }
        if let group = try storedGroup(id: id) {
            modelContext.delete(group)
        }
        try modelContext.save()
    }

    /// Drops a group nothing is left in.
    ///
    /// Only ever called from `erase`, because that is the only moment a
    /// member stops existing rather than being marked. A group whose members
    /// are merely in the trash keeps its row: restoring one of them puts the
    /// pair back together, which clearing the survivor's field eagerly would
    /// have made impossible.
    ///
    /// A group down to a single member is left alone here too — one member
    /// simply does not draw as a group, and the row costs nothing while it
    /// waits for a second variant.
    private func collectVariantGroup(id: UUID) throws {
        let remaining = try members(ofGroup: id)
        guard remaining.count <= 1 else { return }
        for member in remaining {
            member.variantGroupID = nil
            member.updatedAt = .nowInSyncPrecision
            member.searchText = StoredRecipe.searchText(for: member.domainValue)
        }
        if let group = try storedGroup(id: id) {
            modelContext.delete(group)
        }
    }

    /// Every recipe in the group, tombstoned ones included — a deletion that
    /// can still be undone is still a member.
    private func members(ofGroup id: UUID) throws -> [StoredRecipe] {
        try modelContext.fetch(
            FetchDescriptor<StoredRecipe>(predicate: #Predicate { $0.variantGroupID == id })
        )
    }

    private func storedGroup(id: UUID) throws -> StoredVariantGroup? {
        var descriptor = FetchDescriptor<StoredVariantGroup>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func variantGroupTitle(of recipe: StoredRecipe) throws -> String? {
        try recipe.variantGroupID.flatMap { try storedGroup(id: $0) }?.title
    }

    private func liveRecipes() throws -> [StoredRecipe] {
        try modelContext.fetch(
            FetchDescriptor<StoredRecipe>(predicate: #Predicate { $0.deletedAt == nil })
        )
    }

    private func stored(id: UUID) throws -> StoredRecipe? {
        var descriptor = FetchDescriptor<StoredRecipe>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// Built explicitly per case rather than with one clever expression:
    /// SwiftData translates only a narrow subset of predicates dependably,
    /// and a captured flag or an empty `contains` is outside it.
    private static func predicate(for query: RecipeQuery) -> Predicate<StoredRecipe>? {
        let search = query.searchText?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""

        switch (query.includeDeleted, search.isEmpty) {
        case (true, true):
            return nil
        case (true, false):
            return #Predicate<StoredRecipe> { $0.searchText.contains(search) }
        case (false, true):
            return #Predicate<StoredRecipe> { $0.deletedAt == nil }
        case (false, false):
            return #Predicate<StoredRecipe> { $0.deletedAt == nil && $0.searchText.contains(search) }
        }
    }
}

extension ModelContainer {
    /// The app group the app and its share extension both read the store
    /// from. A recipe saved from Safari has to land where the app looks.
    public static let appGroup = "group.me.raddatz.sous"

    /// A container for the recipe schema.
    public static func sousContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration: ModelConfiguration = if inMemory {
            ModelConfiguration(isStoredInMemoryOnly: true)
        } else if let url = sharedStoreURL() {
            ModelConfiguration(url: url)
        } else {
            // No group container: the entitlement is missing, or this is a
            // test host. The app's own container still works — but nothing
            // the extension writes will show up in it.
            ModelConfiguration()
        }

        return try ModelContainer(
            for: StoredRecipe.self, StoredRecipeImage.self, StoredMealPlanEntry.self, StoredShoppingEntry.self,
            StoredShoppingPlanEntry.self, StoredShoppingDemand.self, StoredPantryFlag.self,
            StoredCatalogIngredient.self, StoredRecipeEnrichment.self, StoredAmountReview.self,
            StoredRecipeNutrition.self, StoredIngredientReview.self, StoredVariantGroup.self,
            StoredIngredientAliasOverride.self, StoredCatalogNutrition.self,
            StoredIngredientVocabulary.self,
            configurations: configuration
        )
    }

    /// Whether the shared container is reachable at all. The extension asks
    /// before it promises to save anything.
    public static var hasSharedContainer: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil
    }

    /// Where the shared store lives, moving an older private one across the
    /// first time it is asked for.
    private static func sharedStoreURL() -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        else { return nil }

        let shared = container.appending(path: "Sous.store")
        migratePrivateStore(to: shared)
        return shared
    }

    /// Copies a store written before the app group existed.
    ///
    /// Copy rather than move, and only when nothing is there yet: if this
    /// goes wrong, the recipes are still where they were.
    private static func migratePrivateStore(to shared: URL) {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: shared.path) else { return }

        let previous = URL.applicationSupportDirectory.appending(path: "default.store")
        guard manager.fileExists(atPath: previous.path) else { return }

        // SQLite keeps its write-ahead log beside the database; leaving that
        // behind would lose whatever had not been checkpointed.
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: previous.path + suffix)
            let to = URL(fileURLWithPath: shared.path + suffix)
            guard manager.fileExists(atPath: from.path) else { continue }
            try? manager.copyItem(at: from, to: to)
        }
    }
}
