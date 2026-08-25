import Foundation
import SwiftData

/// A ``RecipeNutritionStore`` backed by SwiftData.
@ModelActor
public actor SwiftDataRecipeNutritionStore: RecipeNutritionStore {
    public func nutrition(
        for recipe: Recipe, servings: Int, resolve: @Sendable (UUID) -> Recipe?
    ) async throws -> RecipeNutrition? {
        let hash = RecipeContentHash.hash(for: recipe, resolve: resolve)
        guard let stored = try allStored(recipeID: recipe.id)
            .first(where: { $0.servings == servings && $0.contentHash == hash })
        else { return nil }
        return stored.nutrition
    }

    public func save(_ nutrition: RecipeNutrition, for recipe: Recipe, resolve: @Sendable (UUID) -> Recipe?) async throws {
        let hash = RecipeContentHash.hash(for: recipe, resolve: resolve)
        var rows = try allStored(recipeID: recipe.id)
        // A row computed against other content is stale at every serving
        // count — pruned here so the rows per recipe stay bounded by the
        // counts actually being looked at.
        for row in rows where row.contentHash != hash {
            modelContext.delete(row)
        }
        rows.removeAll { $0.contentHash != hash }

        if let existing = rows.first(where: { $0.servings == nutrition.servings }) {
            existing.apply(contentHash: hash, nutrition: nutrition)
        } else {
            modelContext.insert(StoredRecipeNutrition(recipeID: recipe.id, contentHash: hash, nutrition: nutrition))
        }
        try modelContext.save()
    }

    public func delete(recipeID: UUID) async throws {
        let rows = try allStored(recipeID: recipeID)
        guard !rows.isEmpty else { return }
        for row in rows {
            modelContext.delete(row)
        }
        try modelContext.save()
    }

    public func invalidateAll() async throws {
        try modelContext.delete(model: StoredRecipeNutrition.self)
        try modelContext.save()
    }

    private func allStored(recipeID: UUID) throws -> [StoredRecipeNutrition] {
        let descriptor = FetchDescriptor<StoredRecipeNutrition>(predicate: #Predicate { $0.recipeID == recipeID })
        return try modelContext.fetch(descriptor)
    }
}
