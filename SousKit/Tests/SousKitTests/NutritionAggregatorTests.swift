import Foundation
import Testing
@testable import SousKit

@Suite("Nutrition aggregation")
struct NutritionAggregatorTests {
    /// A small, hand-checkable catalog — not the full bundled one, so the
    /// expected numbers can be computed by hand. "Safran" is deliberately a
    /// catalog ingredient without any nutrition entry, the case that used to
    /// vanish without a trace.
    private func catalog() -> IngredientCatalog {
        IngredientCatalog(ingredients: [
            CatalogIngredient(name: "Zucchini", category: .vegetables),
            CatalogIngredient(name: "Zwiebel", category: .vegetables),
            CatalogIngredient(name: "Mehl", category: .baking),
            CatalogIngredient(name: "Salz", category: .spices),
            CatalogIngredient(name: "Safran", category: .spices),
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

    private func aggregate(_ recipe: Recipe, servings: Int? = nil, resolve: (UUID) -> Recipe? = { _ in nil }) -> NutritionReport {
        NutritionAggregator.aggregate(
            recipe: recipe, servings: servings ?? recipe.servings,
            catalog: catalog(), nutritionCatalog: nutritionCatalog(), resolve: resolve
        )
    }

    @Test("A recipe's total matches the hand-computed sum of its lines")
    func totalsMatchHandComputedSum() {
        let recipe = Recipe(title: "Gemüsepfanne", servings: 2, ingredientsText: "300 g Zucchini\n1 Zwiebel")

        let report = aggregate(recipe)

        // 300g Zucchini @ 17kcal/100g = 51; 1 Zwiebel = 110g @ 40kcal/100g = 44.
        #expect(report.total.kcal == 95)
    }

    @Test("Doubling the servings argument doubles the total")
    func servingsArgumentScalesTheTotal() {
        let recipe = Recipe(title: "Gemüsepfanne", servings: 2, ingredientsText: "300 g Zucchini\n1 Zwiebel")

        let doubled = aggregate(recipe, servings: 4)

        #expect(doubled.total.kcal == 190)
    }

    @Test("A linked sub-recipe contributes its own nutrition, scaled to the portions asked for")
    func linkedSubRecipeContributes() {
        let naanID = UUID()
        let naan = Recipe(id: naanID, title: "Naan", servings: 4, ingredientsText: "400 g Mehl")
        let curry = Recipe(
            title: "Curry", servings: 2,
            ingredientsText: "1 Portion \(RecipeLink.markdown(title: "Naan", id: naanID))"
        )

        let report = aggregate(curry) { $0 == naanID ? naan : nil }

        // 1 portion of Naan (out of 4) is a quarter of 400g Mehl = 100g @ 350kcal/100g = 350.
        #expect(report.total.kcal == 350)
    }

    @Test("A recipe that links to itself does not loop forever or double-count")
    func selfLinkDoesNotLoop() {
        let recipeID = UUID()
        let recipe = Recipe(
            id: recipeID, title: "Selbstbezug", servings: 2,
            ingredientsText: "300 g Zucchini\n1 Portion \(RecipeLink.markdown(title: "Selbstbezug", id: recipeID))"
        )

        let report = aggregate(recipe) { $0 == recipeID ? recipe : nil }

        // The self-link resolves to nothing extra — only the Zucchini counts.
        #expect(report.total.kcal == 51)
        // But it does not vanish either: the loop is a visible gap.
        #expect(report.coverage.gaps == [
            NutritionCoverage.Gap(ingredientName: "Selbstbezug", reason: .unresolvedLink)
        ])
    }

    @Test("An ingredient with no matching nutrition entry is skipped from the sum, not fatal")
    func unknownIngredientIsSkipped() {
        let recipe = Recipe(title: "Mystery", servings: 2, ingredientsText: "300 g Zucchini\n1 Prise Einhornstaub")

        let report = aggregate(recipe)

        #expect(report.total.kcal == 51)
    }

    // MARK: - Coverage

    @Test("When every line contributes, coverage says so and is complete")
    func fullCoverageIsComplete() {
        let recipe = Recipe(title: "Gemüsepfanne", servings: 2, ingredientsText: "300 g Zucchini\n1 Zwiebel")

        let coverage = aggregate(recipe).coverage

        #expect(coverage.includedCount == 2)
        #expect(coverage.accountableCount == 2)
        #expect(coverage.gaps.isEmpty)
        #expect(coverage.isComplete)
    }

    @Test("Every way a line can fail gets its own reason, and the count stays honest")
    func gapReasonsAreDistinguished() {
        let recipe = Recipe(
            title: "Lückentext", servings: 2,
            ingredientsText: """
            300 g Zucchini
            200 g Einhornstaub
            1 Prise Safran
            2 Stk. Zucchini
            """
        )

        let coverage = aggregate(recipe).coverage

        // Einhornstaub: nobody knows the name. Safran: the catalog knows it,
        // nobody has values. 2 Stk. Zucchini: values exist, but no piece
        // weight turns "Stk." into grams.
        #expect(coverage.includedCount == 1)
        #expect(coverage.accountableCount == 4)
        #expect(!coverage.isComplete)
        #expect(coverage.gaps == [
            NutritionCoverage.Gap(ingredientName: "Einhornstaub", reason: .noCatalogMatch),
            NutritionCoverage.Gap(ingredientName: "Safran", reason: .noNutritionValues),
            NutritionCoverage.Gap(ingredientName: "Zucchini", reason: .noGramEquivalent),
        ])
    }

    @Test("An unquantified line is listed but never a defect")
    func unquantifiedLineIsNotADefect() {
        let recipe = Recipe(
            title: "Gemüsepfanne", servings: 2,
            ingredientsText: "300 g Zucchini\nSalz nach Geschmack"
        )

        let coverage = aggregate(recipe).coverage

        // "Salz nach Geschmack" is recognized — it does not shrink the
        // covered share, and it does not block completeness.
        #expect(coverage.includedCount == 1)
        #expect(coverage.accountableCount == 1)
        #expect(coverage.isComplete)
        #expect(coverage.gaps == [
            NutritionCoverage.Gap(ingredientName: "Salz", reason: .unquantified)
        ])
    }

    @Test("A sum nothing contributed to is not complete")
    func emptySumIsNotComplete() {
        let recipe = Recipe(title: "Nur Salz", servings: 2, ingredientsText: "Salz nach Geschmack")

        let coverage = aggregate(recipe).coverage

        #expect(coverage.includedCount == 0)
        #expect(!coverage.isComplete)
    }

    @Test("A linked sub-recipe's gaps propagate, named after where they sit")
    func linkedRecipeCoveragePropagates() {
        let naanID = UUID()
        let naan = Recipe(id: naanID, title: "Naan", servings: 4, ingredientsText: "400 g Mehl\n1 Prise Safran")
        let curry = Recipe(
            title: "Curry", servings: 2,
            ingredientsText: "300 g Zucchini\n1 Portion \(RecipeLink.markdown(title: "Naan", id: naanID))"
        )

        let coverage = aggregate(curry) { $0 == naanID ? naan : nil }.coverage

        // The naan's flour counts as an included line of the curry; its
        // missing Safran values surface on the curry, marked "aus Naan".
        #expect(coverage.includedCount == 2)
        #expect(coverage.accountableCount == 3)
        #expect(!coverage.isComplete)
        #expect(coverage.gaps == [
            NutritionCoverage.Gap(ingredientName: "Safran", reason: .noNutritionValues, sourceRecipeTitle: "Naan")
        ])
    }

    @Test("A link to a recipe that no longer resolves is a visible gap")
    func unresolvableLinkIsAGap() {
        let goneID = UUID()
        let recipe = Recipe(
            title: "Curry", servings: 2,
            ingredientsText: "300 g Zucchini\n1 Portion \(RecipeLink.markdown(title: "Naan", id: goneID))"
        )

        let coverage = aggregate(recipe).coverage

        #expect(!coverage.isComplete)
        #expect(coverage.gaps == [
            NutritionCoverage.Gap(ingredientName: "Naan", reason: .unresolvedLink)
        ])
    }
}
