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

    private func sampleClaims() -> [StoredAmountClaim] {
        [StoredAmountClaim(quantityText: "300 g", modifiedNoun: "Kartoffeln", kind: .absolute, fractionValue: nil, stepNumber: 1)]
    }

    @Test("What is saved comes back for the same recipe")
    func roundTrip() async throws {
        let store = try makeStore()
        let recipe = sampleRecipe()
        try await store.save(sampleClaims(), for: recipe)

        let read = try await store.claims(for: recipe)
        #expect(read == sampleClaims())
    }

    @Test("Nothing cached yet reads as nil, not an empty list")
    func nothingCachedIsNil() async throws {
        let store = try makeStore()
        let read = try await store.claims(for: sampleRecipe())
        #expect(read == nil)
    }

    @Test("A changed instruction text invalidates the cache")
    func changedTextInvalidatesTheCache() async throws {
        let store = try makeStore()
        let original = sampleRecipe()
        try await store.save(sampleClaims(), for: original)

        let edited = sampleRecipe(instructionsText: "300 g Kartoffeln kochen und pürieren.")
        let read = try await store.claims(for: edited)
        #expect(read == nil)
    }

    @Test("Saving again replaces what was cached, under the same recipe id")
    func savingAgainReplaces() async throws {
        let store = try makeStore()
        let recipe = sampleRecipe()
        try await store.save(sampleClaims(), for: recipe)

        let replacement = [
            StoredAmountClaim(quantityText: "restlichen", modifiedNoun: "Kartoffeln", kind: .remaining, fractionValue: nil, stepNumber: 2),
        ]
        try await store.save(replacement, for: recipe)

        let read = try await store.claims(for: recipe)
        #expect(read == replacement)
    }

    @Test("Deleting removes the cache; reading it back is the same as never having saved")
    func deleteRemovesTheCache() async throws {
        let store = try makeStore()
        let recipe = sampleRecipe()
        try await store.save(sampleClaims(), for: recipe)

        try await store.delete(recipeID: recipe.id)
        let read = try await store.claims(for: recipe)
        #expect(read == nil)
    }
}
