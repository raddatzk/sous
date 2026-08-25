import Foundation
import SwiftData

/// A ``RecipeNutritionStore`` backed by SwiftData.
@ModelActor
public actor SwiftDataRecipeNutritionStore: RecipeNutritionStore {
    public func nutrition(for recipe: Recipe, resolve: @Sendable (UUID) -> Recipe?) async throws -> RecipeNutrition? {
        guard let stored = try stored(recipeID: recipe.id),
              stored.contentHash == RecipeContentHash.hash(for: recipe, resolve: resolve)
        else { return nil }
        return stored.nutrition
    }

    public func save(_ nutrition: RecipeNutrition, for recipe: Recipe, resolve: @Sendable (UUID) -> Recipe?) async throws {
        let hash = RecipeContentHash.hash(for: recipe, resolve: resolve)
        if let existing = try stored(recipeID: recipe.id) {
            existing.apply(contentHash: hash, nutrition: nutrition)
        } else {
            modelContext.insert(StoredRecipeNutrition(recipeID: recipe.id, contentHash: hash, nutrition: nutrition))
        }
        try modelContext.save()
    }

    public func delete(recipeID: UUID) async throws {
        guard let existing = try stored(recipeID: recipeID) else { return }
        modelContext.delete(existing)
        try modelContext.save()
    }

    private func stored(recipeID: UUID) throws -> StoredRecipeNutrition? {
        var descriptor = FetchDescriptor<StoredRecipeNutrition>(predicate: #Predicate { $0.recipeID == recipeID })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
