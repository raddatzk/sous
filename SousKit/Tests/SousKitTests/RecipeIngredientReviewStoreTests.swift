import Foundation
import SwiftData
import Testing
@testable import SousKit

@Suite("Recipe ingredient review")
struct RecipeIngredientReviewStoreTests {
    private func makeStore() throws -> SwiftDataRecipeIngredientReviewStore {
        SwiftDataRecipeIngredientReviewStore(modelContainer: try .sousContainer(inMemory: true))
    }

    private func sampleRecipe(id: UUID = UUID(), ingredientsText: String = "1 Gochujang") -> Recipe {
        Recipe(id: id, title: "Kimchi-Suppe", servings: 2, ingredientsText: ingredientsText)
    }

    @Test("Nothing reviewed yet reads as nil, not a stale match")
    func nothingReviewedIsNil() async throws {
        let store = try makeStore()
        let read = try await store.reviewedHash(for: sampleRecipe().id)
        #expect(read == nil)
    }

    @Test("What was marked reviewed comes back as the recipe's current hash")
    func roundTrip() async throws {
        let store = try makeStore()
        let recipe = sampleRecipe()
        try await store.markReviewed(recipe)

        let read = try await store.reviewedHash(for: recipe.id)
        #expect(read == RecipeContentHash.hash(for: recipe))
    }

    @Test("A changed ingredient text no longer matches the reviewed hash")
    func changedTextInvalidatesTheReview() async throws {
        let store = try makeStore()
        let id = UUID()
        let original = sampleRecipe(id: id)
        try await store.markReviewed(original)

        let edited = sampleRecipe(id: id, ingredientsText: "2 Gochujang")
        let read = try await store.reviewedHash(for: edited.id)
        #expect(read != RecipeContentHash.hash(for: edited))
    }

    @Test("Deleting removes the review; reading it back is the same as never having reviewed")
    func deleteRemovesTheReview() async throws {
        let store = try makeStore()
        let recipe = sampleRecipe()
        try await store.markReviewed(recipe)

        try await store.delete(recipeID: recipe.id)
        let read = try await store.reviewedHash(for: recipe.id)
        #expect(read == nil)
    }
}
