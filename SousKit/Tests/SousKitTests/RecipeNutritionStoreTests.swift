import Foundation
import SwiftData
import Testing
@testable import SousKit

@Suite("Recipe nutrition cache")
struct RecipeNutritionStoreTests {
    private func makeStore() throws -> SwiftDataRecipeNutritionStore {
        SwiftDataRecipeNutritionStore(modelContainer: try .sousContainer(inMemory: true))
    }

    private func sampleRecipe(ingredientsText: String = "1 kg Kartoffel") -> Recipe {
        Recipe(title: "Kartoffelpüree", servings: 2, ingredientsText: ingredientsText)
    }

    private func sampleNutrition() -> RecipeNutrition {
        RecipeNutrition(
            perPortion: NutritionInfo(
                kcal: 200, proteinG: 4, fatG: 0, saturatedFatG: 0, carbsG: 40, sugarG: 1, fiberG: 3, sodiumMg: 5,
                vitaminAMcg: 0, vitaminCMg: 10, vitaminDMcg: 0, vitaminEMg: 0,
                calciumMg: 10, ironMg: 1, magnesiumMg: 20, potassiumMg: 400
            ),
            servings: 2, nrf93Score: 12
        )
    }

    @Test("What is saved comes back for the same recipe")
    func roundTrip() async throws {
        let store = try makeStore()
        let recipe = sampleRecipe()
        try await store.save(sampleNutrition(), for: recipe) { _ in nil }

        let read = try await store.nutrition(for: recipe) { _ in nil }
        #expect(read == sampleNutrition())
    }

    @Test("Nothing cached yet reads as nil")
    func nothingCachedIsNil() async throws {
        let store = try makeStore()
        let read = try await store.nutrition(for: sampleRecipe()) { _ in nil }
        #expect(read == nil)
    }

    @Test("A changed ingredient text invalidates the cache")
    func changedTextInvalidatesTheCache() async throws {
        let store = try makeStore()
        let original = sampleRecipe()
        try await store.save(sampleNutrition(), for: original) { _ in nil }

        let edited = sampleRecipe(ingredientsText: "2 kg Kartoffel")
        let read = try await store.nutrition(for: edited) { _ in nil }
        #expect(read == nil)
    }

    @Test("Editing a linked sub-recipe invalidates the parent's cache, even though the parent's own text did not change")
    func linkedRecipeChangeInvalidatesTheParent() async throws {
        let store = try makeStore()
        let naanID = UUID()
        var naan = Recipe(id: naanID, title: "Naan", servings: 4, ingredientsText: "400 g Mehl")
        let curry = Recipe(
            title: "Curry", servings: 2,
            ingredientsText: "1 Portion \(RecipeLink.markdown(title: "Naan", id: naanID))"
        )
        let originalNaan = naan
        let resolve: @Sendable (UUID) -> Recipe? = { $0 == naanID ? originalNaan : nil }

        try await store.save(sampleNutrition(), for: curry, resolve: resolve)
        #expect(try await store.nutrition(for: curry, resolve: resolve) != nil)

        naan.ingredientsText = "500 g Mehl"
        let updatedNaan = naan
        let stillResolve: @Sendable (UUID) -> Recipe? = { $0 == naanID ? updatedNaan : nil }
        let read = try await store.nutrition(for: curry, resolve: stillResolve)
        #expect(read == nil)
    }

    @Test("Saving again replaces what was cached, under the same recipe id")
    func savingAgainReplaces() async throws {
        let store = try makeStore()
        let recipe = sampleRecipe()
        try await store.save(sampleNutrition(), for: recipe) { _ in nil }

        let replacement = RecipeNutrition(perPortion: .zero, servings: 2, nrf93Score: -5)
        try await store.save(replacement, for: recipe) { _ in nil }

        let read = try await store.nutrition(for: recipe) { _ in nil }
        #expect(read == replacement)
    }

    @Test("Deleting removes the cache; reading it back is the same as never having saved")
    func deleteRemovesTheCache() async throws {
        let store = try makeStore()
        let recipe = sampleRecipe()
        try await store.save(sampleNutrition(), for: recipe) { _ in nil }

        try await store.delete(recipeID: recipe.id)
        let read = try await store.nutrition(for: recipe) { _ in nil }
        #expect(read == nil)
    }
}
