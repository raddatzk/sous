import Foundation
import Testing
@testable import SousKit

@Suite("Nutrition gram resolution")
struct NutritionResolverTests {
    private func ingredient(
        name: String, quantity: Quantity?, state: IngredientState = .unspecified
    ) -> RecipeIngredient {
        RecipeIngredient(name: name, quantity: quantity, state: state)
    }

    @Test("A mass unit resolves directly, no catalog needed")
    func massResolvesDirectly() {
        let grams = NutritionResolver.resolvedGrams(
            for: ingredient(name: "Zucchini", quantity: Quantity(300, .gram)),
            catalog: IngredientCatalog(ingredients: []),
            nutritionCatalog: NutritionCatalog(entries: [])
        )
        #expect(grams == 300)
    }

    @Test("A volume unit resolves via the ingredient's own density")
    func volumeResolvesViaDensity() {
        let nutritionCatalog = NutritionCatalog(entries: [
            CatalogNutrition(name: "Olivenöl", perHundredGrams: [:], densityGramsPerMl: 0.92),
        ])
        let grams = NutritionResolver.resolvedGrams(
            for: ingredient(name: "Olivenöl", quantity: Quantity(2, .tablespoon)), // 30 ml
            catalog: IngredientCatalog(ingredients: [CatalogIngredient(name: "Olivenöl", category: .oils)]),
            nutritionCatalog: nutritionCatalog
        )
        #expect(grams == 27.6)
    }

    @Test("A volume unit with no density on record falls back to water density rather than vanishing")
    func volumeWithoutDensityFallsBackToWater() {
        let grams = NutritionResolver.resolvedGrams(
            for: ingredient(name: "Olivenöl", quantity: Quantity(2, .tablespoon)), // 30 ml
            catalog: IngredientCatalog(ingredients: [CatalogIngredient(name: "Olivenöl", category: .oils)]),
            nutritionCatalog: NutritionCatalog(entries: [])
        )
        #expect(grams == 30) // 30 ml * 1.0 g/ml fallback
    }

    @Test("A clove resolves via the ingredient's own unit weight")
    func cloveResolvesViaUnitWeight() {
        let nutritionCatalog = NutritionCatalog(entries: [
            CatalogNutrition(name: "Knoblauch", perHundredGrams: [:], unitWeightsGrams: ["Zehe": 5]),
        ])
        let grams = NutritionResolver.resolvedGrams(
            for: ingredient(name: "Knoblauch", quantity: Quantity(2, .clove)),
            catalog: IngredientCatalog(ingredients: [CatalogIngredient(name: "Knoblauch", category: .vegetables)]),
            nutritionCatalog: nutritionCatalog
        )
        #expect(grams == 10)
    }

    @Test("A leaf with no specific weight falls back to the generic default")
    func leafFallsBackToGenericDefault() {
        let grams = NutritionResolver.resolvedGrams(
            for: ingredient(name: "Basilikum", quantity: Quantity(10, .leaf)),
            catalog: IngredientCatalog(ingredients: []),
            nutritionCatalog: NutritionCatalog(entries: [])
        )
        #expect(grams == 10) // 10 leaves * 1g generic default
    }

    @Test("An unquantified ingredient cannot be resolved")
    func unquantifiedIsNil() {
        let grams = NutritionResolver.resolvedGrams(
            for: ingredient(name: "Salz", quantity: nil),
            catalog: IngredientCatalog(ingredients: []),
            nutritionCatalog: NutritionCatalog(entries: [])
        )
        #expect(grams == nil)
    }

    @Test("A piece with no per-ingredient weight and no generic fallback stays nil")
    func pieceWithoutDataIsNil() {
        let grams = NutritionResolver.resolvedGrams(
            for: ingredient(name: "Zwiebel", quantity: Quantity(2, .piece)),
            catalog: IngredientCatalog(ingredients: []),
            nutritionCatalog: NutritionCatalog(entries: [])
        )
        #expect(grams == nil)
    }
}
