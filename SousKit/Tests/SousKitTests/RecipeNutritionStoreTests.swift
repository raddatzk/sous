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

    private func sampleNutrition(servings: Int = 2, kcal: Double = 200) -> RecipeNutrition {
        RecipeNutrition(
            perPortion: NutritionInfo(
                kcal: kcal, proteinG: 4, fatG: 0, saturatedFatG: 0, carbsG: 40, sugarG: 1, fiberG: 3, sodiumMg: 5,
                vitaminAMcg: 0, vitaminCMg: 10, vitaminDMcg: 0, vitaminEMg: 0,
                calciumMg: 10, ironMg: 1, magnesiumMg: 20, potassiumMg: 400
            ),
            servings: servings, nrf93Score: 12,
            coverage: NutritionCoverage(includedCount: 1, gaps: [])
        )
    }

    @Test("What is saved comes back for the same recipe and servings")
    func roundTrip() async throws {
        let store = try makeStore()
        let recipe = sampleRecipe()
        try await store.save(sampleNutrition(), for: recipe) { _ in nil }

        let read = try await store.nutrition(for: recipe, servings: 2) { _ in nil }
        #expect(read == sampleNutrition())
    }

    @Test("Nothing cached yet reads as nil")
    func nothingCachedIsNil() async throws {
        let store = try makeStore()
        let read = try await store.nutrition(for: sampleRecipe(), servings: 2) { _ in nil }
        #expect(read == nil)
    }

    @Test("Each serving count keeps its own figure — the list at base servings and the detail at a scaled count no longer overwrite each other")
    func servingCountsAreCachedSideBySide() async throws {
        let store = try makeStore()
        let recipe = sampleRecipe()
        // Per-portion figures differ across counts because seasoning does
        // not scale — that is exactly why the count is part of the key.
        try await store.save(sampleNutrition(servings: 2, kcal: 200), for: recipe) { _ in nil }
        try await store.save(sampleNutrition(servings: 4, kcal: 180), for: recipe) { _ in nil }

        let base = try await store.nutrition(for: recipe, servings: 2) { _ in nil }
        let scaled = try await store.nutrition(for: recipe, servings: 4) { _ in nil }
        #expect(base == sampleNutrition(servings: 2, kcal: 200))
        #expect(scaled == sampleNutrition(servings: 4, kcal: 180))
    }

    @Test("A serving count nothing was computed for reads as nil, not as a neighbour's figure")
    func unknownServingCountIsNil() async throws {
        let store = try makeStore()
        let recipe = sampleRecipe()
        try await store.save(sampleNutrition(servings: 2), for: recipe) { _ in nil }

        let read = try await store.nutrition(for: recipe, servings: 3) { _ in nil }
        #expect(read == nil)
    }

    @Test("A changed ingredient text invalidates the cache")
    func changedTextInvalidatesTheCache() async throws {
        let store = try makeStore()
        let original = sampleRecipe()
        try await store.save(sampleNutrition(), for: original) { _ in nil }

        let edited = sampleRecipe(ingredientsText: "2 kg Kartoffel")
        let read = try await store.nutrition(for: edited, servings: 2) { _ in nil }
        #expect(read == nil)
    }

    @Test("Saving after an edit prunes the stale rows of every other serving count")
    func savingPrunesStaleRows() async throws {
        let store = try makeStore()
        let original = sampleRecipe()
        try await store.save(sampleNutrition(servings: 2), for: original) { _ in nil }
        try await store.save(sampleNutrition(servings: 4), for: original) { _ in nil }

        var edited = original
        edited.ingredientsText = "2 kg Kartoffel"
        try await store.save(sampleNutrition(servings: 2, kcal: 400), for: edited) { _ in nil }

        // The servings-4 row was computed against the old text; it must not
        // linger and serve a stale figure if the text ever changes back.
        let read = try await store.nutrition(for: original, servings: 4) { _ in nil }
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
        #expect(try await store.nutrition(for: curry, servings: 2, resolve: resolve) != nil)

        naan.ingredientsText = "500 g Mehl"
        let updatedNaan = naan
        let stillResolve: @Sendable (UUID) -> Recipe? = { $0 == naanID ? updatedNaan : nil }
        let read = try await store.nutrition(for: curry, servings: 2, resolve: stillResolve)
        #expect(read == nil)
    }

    @Test("Saving again replaces what was cached, under the same recipe id and servings")
    func savingAgainReplaces() async throws {
        let store = try makeStore()
        let recipe = sampleRecipe()
        try await store.save(sampleNutrition(), for: recipe) { _ in nil }

        let replacement = RecipeNutrition(
            perPortion: .zero, servings: 2, nrf93Score: -5,
            coverage: NutritionCoverage(includedCount: 1, gaps: [])
        )
        try await store.save(replacement, for: recipe) { _ in nil }

        let read = try await store.nutrition(for: recipe, servings: 2) { _ in nil }
        #expect(read == replacement)
    }

    @Test("Deleting removes every serving count's row; reading back is the same as never having saved")
    func deleteRemovesTheCache() async throws {
        let store = try makeStore()
        let recipe = sampleRecipe()
        try await store.save(sampleNutrition(servings: 2), for: recipe) { _ in nil }
        try await store.save(sampleNutrition(servings: 4), for: recipe) { _ in nil }

        try await store.delete(recipeID: recipe.id)
        #expect(try await store.nutrition(for: recipe, servings: 2) { _ in nil } == nil)
        #expect(try await store.nutrition(for: recipe, servings: 4) { _ in nil } == nil)
    }
}

@Suite("Recipe content hash")
struct RecipeContentHashTests {
    @Test("The bundled data is fingerprinted, so shipping new data invalidates every cached figure")
    func bundledDataEntersTheHash() {
        #expect(!RecipeContentHash.bundledDataFingerprint.isEmpty)

        // The same recipe against other bundled data must hash differently —
        // that is the whole point of folding the fingerprint in.
        let recipe = Recipe(title: "Kartoffelpüree", servings: 2, ingredientsText: "1 kg Kartoffel")
        let today = RecipeContentHash.hash(for: recipe, dataFingerprint: "datensatz-eins")
        let afterUpdate = RecipeContentHash.hash(for: recipe, dataFingerprint: "datensatz-zwei")
        #expect(today != afterUpdate)
    }
}
