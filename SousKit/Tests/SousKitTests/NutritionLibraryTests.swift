import Foundation
import SwiftData
import Testing
@testable import SousKit

/// The nutrition library since phase 6b: the data set's table with the
/// household's local answers laid over it (INGREDIENTS-DATA §3 B). Nothing is
/// confirmed, picked or orphaned any more; own values and weights are a local
/// answer's.
@MainActor
@Suite("Nutrition library")
struct NutritionLibraryTests {
    private func makeLibrary() throws -> (NutritionLibrary, SwiftDataRecipeStore) {
        let (nutrition, recipes, _) = try makeLibraries()
        return (nutrition, recipes)
    }

    private func makeLibraries() throws -> (NutritionLibrary, SwiftDataRecipeStore, IngredientCatalogLibrary) {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let recipes = SwiftDataRecipeStore(modelContainer: container)
        let catalog = IngredientCatalogLibrary()
        let nutrition = NutritionLibrary(
            store: SwiftDataRecipeNutritionStore(modelContainer: container),
            recipeStore: recipes,
            catalogLibrary: catalog
        )
        return (nutrition, recipes, catalog)
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

    @Test("A local answer's own values fill a gap the catalog has")
    func ownValuesFillAGap() async throws {
        let (nutrition, _, catalog) = try makeLibraries()
        let recipe = Recipe(title: "Bratlinge", servings: 2, ingredientsText: "200 g veganes Hackfleisch")
        #expect(await nutrition.nutrition(for: recipe)?.perPortion.kcal == 0)

        await catalog.saveLocalAnswer(LocalAnswer(
            name: "veganes Hackfleisch", values: info(kcal: 150), valuesSource: "Packung"
        ))

        // 200 g at 150 kcal/100 g, over two portions — and the cache missed,
        // since its key carries the answers.
        #expect(await nutrition.nutrition(for: recipe)?.perPortion.kcal == 150)
    }

    @Test("Own values beat the catalog's basis, and taking them back restores it")
    func ownValuesWinAndGo() async throws {
        let (nutrition, _, catalog) = try makeLibraries()
        let recipe = Recipe(title: "Zuckerguss", servings: 2, ingredientsText: "200 g Zucker")
        let bundled = try #require(await nutrition.nutrition(for: recipe)?.perPortion.kcal)
        #expect(bundled > 0)

        await catalog.saveLocalAnswer(LocalAnswer(name: "Zucker", values: info(kcal: 1)))
        #expect(await nutrition.nutrition(for: recipe)?.perPortion.kcal == 1)

        let answer = try #require(catalog.localAnswer(for: "Zucker"))
        await catalog.deleteLocalAnswer(answer)
        #expect(await nutrition.nutrition(for: recipe)?.perPortion.kcal == bundled)
    }

    @Test("An own piece weight makes a counted line count")
    func ownPieceWeightResolves() async throws {
        let (nutrition, _, catalog) = try makeLibraries()
        let recipe = Recipe(title: "Bratlinge", servings: 1, ingredientsText: "2 Sojaküchlein")
        #expect(await nutrition.nutrition(for: recipe)?.perPortion.kcal == 0)

        await catalog.saveLocalAnswer(LocalAnswer(
            name: "Sojaküchlein", values: info(kcal: 200),
            weights: [IngredientUnit.piece.symbol: LocalAnswer.Weight(grams: 50)]
        ))

        // Two pieces of 50 g, at 200 kcal/100 g.
        #expect(await nutrition.nutrition(for: recipe)?.perPortion.kcal == 200)
    }

    @Test("A correction to a spoon beats the shipped density, for that unit alone")
    func ownUnitWeightBeatsTheGenericValue() async throws {
        // The concept's "the cook can override any value on their
        // ingredient", past the single `Stk.` weight that used to be the only
        // one anybody could write. The storage was always a dictionary keyed
        // by unit — only the callers and the form were piece-only.
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Dressing", servings: 1, ingredientsText: "2 EL Olivenöl")

        let byDensity = try #require(await nutrition.nutrition(for: recipe))
        // 30 ml × 0.92 g/ml, against olive oil's ~900 kcal/100 g.
        #expect(byDensity.perPortion.kcal > 200)

        await nutrition.setUnitWeight(5, unit: .tablespoon, forName: "Olivenöl")
        let corrected = try #require(await nutrition.nutrition(for: recipe))

        // 10 g instead of 27.6 g — and the figure moved, which means the
        // cache noticed a write that never touched a recipe's text.
        #expect(corrected.perPortion.kcal < byDensity.perPortion.kcal / 2)
        #expect(nutrition.unitWeight(.tablespoon, forName: "Olivenöl") == 5)
        #expect(nutrition.hasOwnUnitWeight(.tablespoon, forName: "Olivenöl"))

        // …and only for the spoon: a millilitre still pours as oil pours.
        let byVolume = Recipe(title: "Marinade", servings: 1, ingredientsText: "100 ml Olivenöl")
        let volume = try #require(await nutrition.nutrition(for: byVolume))
        #expect(volume.perPortion.kcal > 700)
    }

    @Test("Taking a measure correction back leaves the shipped one standing")
    func clearingAUnitWeightRestoresTheShippedOne() async throws {
        let (nutrition, _) = try makeLibrary()
        await nutrition.ensureLoaded()
        let shipped = nutrition.unitWeight(.piece, forName: "Zwiebel")
        #expect(shipped == 110)

        await nutrition.setUnitWeight(200, unit: .piece, forName: "Zwiebel")
        #expect(nutrition.unitWeight(.piece, forName: "Zwiebel") == 200)

        await nutrition.setUnitWeight(nil, unit: .piece, forName: "Zwiebel")
        #expect(nutrition.unitWeight(.piece, forName: "Zwiebel") == 110)
        #expect(!nutrition.hasOwnUnitWeight(.piece, forName: "Zwiebel"))
    }

    @Test("A shipped mapping simply counts, and the figure is complete")
    func aShippedMappingCounts() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten")

        let figure = try #require(await nutrition.nutrition(for: recipe))
        // The catalog answers (§3 A): no "unbestätigt", nothing to confirm.
        #expect(figure.perPortion.kcal > 0)
        #expect(figure.coverage.gaps.isEmpty)
        #expect(figure.coverage.isComplete)
    }

    @Test("A word the catalog settles as without values is no defect")
    func catalogsWithoutIsAnAnswer() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Milchreis", servings: 2, ingredientsText: "1 TL Zimt\n200 g Zucker")

        let figure = try #require(await nutrition.nutrition(for: recipe))
        #expect(figure.coverage.gaps.first { $0.ingredientName == "Zimt" }?.reason == .deliberatelyWithout)
        #expect(figure.coverage.defects.isEmpty)
        #expect(figure.coverage.isComplete)
    }

    @Test("A variety computes with its parent's basis, names it, and is complete")
    func varietiesInheritTheBasis() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Pastasalat", servings: 2, ingredientsText: "200 g Cocktailtomaten")

        let figure = try #require(await nutrition.nutrition(for: recipe))
        #expect(figure.coverage.contributions.first?.inheritedFrom == "Tomate")
        #expect(figure.coverage.isComplete)
    }

    @Test("An invalid serving count is refused rather than dividing by zero")
    func invalidServingsIsNil() async throws {
        let (nutrition, _) = try makeLibrary()
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "200 g Zucker")

        let result = await nutrition.nutrition(for: recipe, servings: 0)
        #expect(result == nil)
    }
}
