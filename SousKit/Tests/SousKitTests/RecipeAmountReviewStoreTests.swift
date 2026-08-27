import Foundation
import SwiftData
import Testing
@testable import SousKit

@Suite("Recipe amount review")
struct RecipeAmountReviewStoreTests {
    private func makeStore(_ backend: StoreBackend) throws -> any RecipeAmountReviewStore {
        try backend.makeAmountReviewStore()
    }

    private func sampleRecipe(id: UUID = UUID(), instructionsText: String = "Die Butter erhitzen.") -> Recipe {
        Recipe(
            id: id,
            title: "Kartoffelpüree",
            servings: 2,
            ingredientsText: "150 g Butter",
            instructionsText: instructionsText
        )
    }

    @Test("Nothing reviewed yet reads as nil, not a stale match", arguments: StoreBackend.allCases)
    func nothingReviewedIsNil(_ backend: StoreBackend) async throws {
        let store = try makeStore(backend)
        let read = try await store.reviewedHash(for: sampleRecipe().id)
        #expect(read == nil)
    }

    @Test("What was marked reviewed comes back as the recipe's current hash", arguments: StoreBackend.allCases)
    func roundTrip(_ backend: StoreBackend) async throws {
        let store = try makeStore(backend)
        let recipe = sampleRecipe()
        try await store.markReviewed(recipe)

        let read = try await store.reviewedHash(for: recipe.id)
        #expect(read == RecipeContentHash.hash(for: recipe))
    }

    @Test("A changed instruction text no longer matches the reviewed hash", arguments: StoreBackend.allCases)
    func changedTextInvalidatesTheReview(_ backend: StoreBackend) async throws {
        let store = try makeStore(backend)
        let id = UUID()
        let original = sampleRecipe(id: id)
        try await store.markReviewed(original)

        let edited = sampleRecipe(id: id, instructionsText: "Die Butter erhitzen und die Zwiebeln andünsten.")
        let read = try await store.reviewedHash(for: edited.id)
        #expect(read != RecipeContentHash.hash(for: edited))
    }

    @Test("Marking reviewed again replaces the stored hash, under the same recipe id", arguments: StoreBackend.allCases)
    func markingAgainReplaces(_ backend: StoreBackend) async throws {
        let store = try makeStore(backend)
        let id = UUID()
        let original = sampleRecipe(id: id)
        try await store.markReviewed(original)

        let edited = sampleRecipe(id: id, instructionsText: "Die Butter erhitzen und die Zwiebeln andünsten.")
        try await store.markReviewed(edited)

        let read = try await store.reviewedHash(for: id)
        #expect(read == RecipeContentHash.hash(for: edited))
    }

    @Test("Deleting removes the review; reading it back is the same as never having reviewed", arguments: StoreBackend.allCases)
    func deleteRemovesTheReview(_ backend: StoreBackend) async throws {
        let store = try makeStore(backend)
        let recipe = sampleRecipe()
        try await store.markReviewed(recipe)

        try await store.delete(recipeID: recipe.id)
        let read = try await store.reviewedHash(for: recipe.id)
        #expect(read == nil)
    }
}
