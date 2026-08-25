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
            recipeStore: recipes,
            nutritionStore: SwiftDataCatalogNutritionStore(modelContainer: container)
        )
        return (nutrition, recipes)
    }

    /// One hand-entered entry, in the shape the ingredient form produces:
    /// one unspecified variant, everything not asked for left at zero.
    private func ownEntry(_ name: String, kcal: Double, gramsPerPiece: Double? = nil) -> CatalogNutrition {
        CatalogNutrition(
            name: name,
            perHundredGrams: [IngredientState.unspecified.rawValue: NutritionInfo(
                kcal: kcal, proteinG: 0, fatG: 0, saturatedFatG: 0,
                carbsG: 0, sugarG: 0, fiberG: 0, sodiumMg: 0,
                vitaminAMcg: 0, vitaminCMg: 0, vitaminDMcg: 0, vitaminEMg: 0,
                calciumMg: 0, ironMg: 0, magnesiumMg: 0, potassiumMg: 0
            )],
            unitWeightsGrams: gramsPerPiece.map { [IngredientUnit.piece.symbol: $0] } ?? [:],
            source: CatalogNutrition.ownSource
        )
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

    @Test("Own nutrition fills a gap the bundled table has")
    func ownNutritionFillsAGap() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Bratlinge", servings: 2, ingredientsText: "200 g veganes Hackfleisch")
        #expect(await nutrition.nutrition(for: recipe)?.perPortion.kcal == 0)

        await nutrition.saveIngredientNutrition(ownEntry("veganes Hackfleisch", kcal: 150))

        // 200 g at 150 kcal/100 g, over two portions.
        #expect(await nutrition.nutrition(for: recipe)?.perPortion.kcal == 150)
    }

    @Test("Own nutrition overrides the bundled entry of the same name")
    func ownNutritionWins() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Zuckerguss", servings: 2, ingredientsText: "200 g Zucker")
        let bundled = try #require(await nutrition.nutrition(for: recipe)?.perPortion.kcal)
        #expect(bundled > 0)

        await nutrition.saveIngredientNutrition(ownEntry("Zucker", kcal: 1))

        #expect(await nutrition.nutrition(for: recipe)?.perPortion.kcal == 1)
        #expect(nutrition.ownNutrition(forCanonicalName: "zucker")?.source == CatalogNutrition.ownSource)
    }

    @Test("Taking own nutrition back restores the bundled figure")
    func deletingOwnNutritionRestoresBundled() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Zuckerguss", servings: 2, ingredientsText: "200 g Zucker")
        let bundled = try #require(await nutrition.nutrition(for: recipe)?.perPortion.kcal)

        await nutrition.saveIngredientNutrition(ownEntry("Zucker", kcal: 1))
        await nutrition.deleteIngredientNutrition(name: "Zucker")

        #expect(await nutrition.nutrition(for: recipe)?.perPortion.kcal == bundled)
    }

    @Test("A hand-entered piece weight makes a counted line count")
    func ownPieceWeightResolves() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Bratlinge", servings: 1, ingredientsText: "2 Sojaküchlein")
        #expect(await nutrition.nutrition(for: recipe)?.perPortion.kcal == 0)

        await nutrition.saveIngredientNutrition(ownEntry("Sojaküchlein", kcal: 200, gramsPerPiece: 50))

        // Two pieces of 50 g, at 200 kcal/100 g.
        #expect(await nutrition.nutrition(for: recipe)?.perPortion.kcal == 200)
    }

    @Test("An invalid serving count is refused rather than dividing by zero")
    func invalidServingsIsNil() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "200 g Zucker")

        let result = await nutrition.nutrition(for: recipe, servings: 0)
        #expect(result == nil)
    }
}
