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
        if let category = query.category {
            results = results.filter { $0.categories.contains(category) }
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

        if let existing = try stored(id: recipe.id) {
            existing.apply(updated)
        } else {
            modelContext.insert(StoredRecipe(updated))
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
    /// A container for the recipe schema.
    public static func sousContainer(inMemory: Bool = false) throws -> ModelContainer {
        try ModelContainer(
            for: StoredRecipe.self, StoredRecipeImage.self, StoredMealPlanEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory)
        )
    }
}
