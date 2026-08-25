import Foundation
import Testing
@testable import SousKit

@Suite("Nutrition aggregation")
struct NutritionAggregatorTests {
    /// A small, hand-checkable catalog — not the full bundled one, so the
    /// expected numbers can be computed by hand.
    private func catalog() -> IngredientCatalog {
        IngredientCatalog(ingredients: [
            CatalogIngredient(name: "Zucchini", category: .vegetables),
            CatalogIngredient(name: "Zwiebel", category: .vegetables),
            CatalogIngredient(name: "Mehl", category: .baking),
        ])
    }

    private func nutritionCatalog() -> NutritionCatalog {
        NutritionCatalog(entries: [
            CatalogNutrition(name: "Zucchini", perHundredGrams: ["raw": info(kcal: 17)]),
            CatalogNutrition(name: "Zwiebel", perHundredGrams: ["raw": info(kcal: 40)], unitWeightsGrams: ["Stk.": 110]),
            CatalogNutrition(name: "Mehl", perHundredGrams: ["unspecified": info(kcal: 350)]),
        ])
    }

    private func info(kcal: Double) -> NutritionInfo {
        NutritionInfo(
            kcal: kcal, proteinG: 0, fatG: 0, saturatedFatG: 0, carbsG: 0, sugarG: 0, fiberG: 0, sodiumMg: 0,
            vitaminAMcg: 0, vitaminCMg: 0, vitaminDMcg: 0, vitaminEMg: 0,
            calciumMg: 0, ironMg: 0, magnesiumMg: 0, potassiumMg: 0
        )
    }

    @Test("A recipe's total matches the hand-computed sum of its lines")
    func totalsMatchHandComputedSum() {
        let recipe = Recipe(title: "Gemüsepfanne", servings: 2, ingredientsText: "300 g Zucchini\n1 Zwiebel")

        let total = NutritionAggregator.aggregate(
            recipe: recipe, servings: 2, catalog: catalog(), nutritionCatalog: nutritionCatalog()
        ) { _ in nil }

        // 300g Zucchini @ 17kcal/100g = 51; 1 Zwiebel = 110g @ 40kcal/100g = 44.
        #expect(total.kcal == 95)
    }

    @Test("Doubling the servings argument doubles the total")
    func servingsArgumentScalesTheTotal() {
        let recipe = Recipe(title: "Gemüsepfanne", servings: 2, ingredientsText: "300 g Zucchini\n1 Zwiebel")

        let doubled = NutritionAggregator.aggregate(
            recipe: recipe, servings: 4, catalog: catalog(), nutritionCatalog: nutritionCatalog()
        ) { _ in nil }

        #expect(doubled.kcal == 190)
    }

    @Test("A linked sub-recipe contributes its own nutrition, scaled to the portions asked for")
    func linkedSubRecipeContributes() {
        let naanID = UUID()
        let naan = Recipe(id: naanID, title: "Naan", servings: 4, ingredientsText: "400 g Mehl")
        let curry = Recipe(
            title: "Curry", servings: 2,
            ingredientsText: "1 Portion \(RecipeLink.markdown(title: "Naan", id: naanID))"
        )

        let total = NutritionAggregator.aggregate(
            recipe: curry, servings: 2, catalog: catalog(), nutritionCatalog: nutritionCatalog()
        ) { $0 == naanID ? naan : nil }

        // 1 portion of Naan (out of 4) is a quarter of 400g Mehl = 100g @ 350kcal/100g = 350.
        #expect(total.kcal == 350)
    }

    @Test("A recipe that links to itself does not loop forever or double-count")
    func selfLinkDoesNotLoop() {
        let recipeID = UUID()
        let recipe = Recipe(
            id: recipeID, title: "Selbstbezug", servings: 2,
            ingredientsText: "300 g Zucchini\n1 Portion \(RecipeLink.markdown(title: "Selbstbezug", id: recipeID))"
        )

        let total = NutritionAggregator.aggregate(
            recipe: recipe, servings: 2, catalog: catalog(), nutritionCatalog: nutritionCatalog()
        ) { $0 == recipeID ? recipe : nil }

        // The self-link resolves to nothing extra — only the Zucchini counts.
        #expect(total.kcal == 51)
    }

    @Test("An ingredient with no matching nutrition entry is skipped, not fatal")
    func unknownIngredientIsSkipped() {
        let recipe = Recipe(title: "Mystery", servings: 2, ingredientsText: "300 g Zucchini\n1 Prise Einhornstaub")

        let total = NutritionAggregator.aggregate(
            recipe: recipe, servings: 2, catalog: catalog(), nutritionCatalog: nutritionCatalog()
        ) { _ in nil }

        #expect(total.kcal == 51)
    }
}
