import Foundation
import SwiftData
import Testing
@testable import SousKit

@MainActor
@Suite("Nutrition library")
struct NutritionLibraryTests {
    private func makeLibrary() throws -> (NutritionLibrary, SwiftDataRecipeStore) {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let recipes = SwiftDataRecipeStore(modelContainer: container)
        let nutrition = NutritionLibrary(
            store: SwiftDataRecipeNutritionStore(modelContainer: container),
            recipeStore: recipes
        )
        return (nutrition, recipes)
    }

    @Test("A recipe with no ingredient the catalog recognizes comes back as zero, not a crash")
    func unknownIngredientsAreZeroNotFatal() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Fantasiegericht", servings: 2, ingredientsText: "1 Prise Sternenstaub")

        let result = await nutrition.nutrition(for: recipe)
        #expect(result?.perPortion.kcal == 0)
        #expect(result?.nrf93Score == 0)
    }

    @Test("Asking twice returns the same, cached value")
    func idempotent() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Zuckerguss", servings: 2, ingredientsText: "200 g Zucker")

        let first = await nutrition.nutrition(for: recipe)
        let second = await nutrition.nutrition(for: recipe)
        #expect(first == second)
    }

    @Test("Editing the recipe's text is reflected the next time it is asked for")
    func editingInvalidatesTheCache() async throws {
        let (nutrition, recipes) = try makeLibrary()
        var recipe = Recipe(title: "Zuckerguss", servings: 2, ingredientsText: "200 g Zucker")
        try await recipes.save(recipe)

        let before = await nutrition.nutrition(for: recipe)

        recipe.ingredientsText = "400 g Zucker"
        try await recipes.save(recipe)
        let after = await nutrition.nutrition(for: recipe)

        #expect(before?.perPortion.kcal != after?.perPortion.kcal)
    }

    @Test("An invalid serving count is refused rather than dividing by zero")
    func invalidServingsIsNil() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "200 g Zucker")

        let result = await nutrition.nutrition(for: recipe, servings: 0)
        #expect(result == nil)
    }
}
