import Foundation
import SwiftData
import Testing
@testable import SousKit

@Suite("Recipe enrichment cache")
struct RecipeEnrichmentStoreTests {
    private func makeStore() throws -> SwiftDataRecipeEnrichmentStore {
        SwiftDataRecipeEnrichmentStore(modelContainer: try .sousContainer(inMemory: true))
    }

    private func sampleRecipe(instructionsText: String = "300 g Kartoffeln kochen.") -> Recipe {
        Recipe(
            title: "Kartoffelpüree",
            servings: 2,
            ingredientsText: "1 kg Kartoffel",
            instructionsText: instructionsText
        )
    }

    @Test("A declined nutrition category stays declined")
    func declinedTagRoundTrip() async throws {
        let store = try makeStore()
        let recipe = sampleRecipe()
        #expect(try await store.declinedNutritionTags(for: recipe.id).isEmpty)

        try await store.declineNutritionTag(.proteinRich, for: recipe.id)
        #expect(try await store.declinedNutritionTags(for: recipe.id) == [.proteinRich])

        try await store.declineNutritionTag(.fiberRich, for: recipe.id)
        #expect(try await store.declinedNutritionTags(for: recipe.id) == [.proteinRich, .fiberRich])
    }

    /// The point of storing declines without a content stamp: the cook said
    /// this dish is not a protein-rich one, and rewording a step does not
    /// reopen that question the way it reopens a cached guess.
    @Test("Editing the recipe does not bring a declined category back")
    func declineSurvivesAnEdit() async throws {
        let store = try makeStore()
        let recipe = sampleRecipe()
        try await store.declineNutritionTag(.proteinRich, for: recipe.id)

        var edited = recipe
        edited.instructionsText = "300 g Kartoffeln weich kochen, dann stampfen."
        #expect(try await store.declinedNutritionTags(for: edited.id) == [.proteinRich])
    }

    @Test("A suitability guess comes back for the same inputs, and an empty guess is a real answer")
    func suitabilityGuessRoundTrip() async throws {
        let store = try makeStore()
        let recipe = sampleRecipe()
        let hash = MealSuitabilityClassifier.inputHash(for: recipe)

        #expect(try await store.suitabilityGuess(for: recipe.id, inputHash: hash) == nil)

        try await store.saveSuitabilityGuess([.breakfast], for: recipe.id, inputHash: hash)
        #expect(try await store.suitabilityGuess(for: recipe.id, inputHash: hash) == [.breakfast])

        // A dessert's guess: suits nothing — cached as an answer, not as
        // absence.
        try await store.saveSuitabilityGuess([], for: recipe.id, inputHash: hash)
        #expect(try await store.suitabilityGuess(for: recipe.id, inputHash: hash) == [])

        // A retitled dish is a different question.
        #expect(try await store.suitabilityGuess(for: recipe.id, inputHash: "other") == nil)
    }

    @Test("Deleting removes the cache; reading it back is the same as never having saved")
    func deleteRemovesTheCache() async throws {
        let store = try makeStore()
        let recipe = sampleRecipe()
        let hash = MealSuitabilityClassifier.inputHash(for: recipe)
        try await store.saveSuitabilityGuess([.dinner], for: recipe.id, inputHash: hash)

        try await store.delete(recipeID: recipe.id)
        #expect(try await store.suitabilityGuess(for: recipe.id, inputHash: hash) == nil)
    }
}
