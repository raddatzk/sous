import Foundation
import Testing
@testable import SousKit

@Suite("Serving scaling")
struct ScalingTests {
    private func sampleRecipe() -> Recipe {
        Recipe(
            title: "Zucchinipfanne",
            servings: 2,
            ingredients: [
                RecipeIngredient(name: "Zucchini", quantity: Quantity(300, .gram)),
                RecipeIngredient(name: "Feta", quantity: Quantity(100, .gram)),
                RecipeIngredient(name: "Salz"),
                RecipeIngredient(
                    name: "Olivenöl",
                    quantity: Quantity(2, .tablespoon),
                    scalesWithServings: false
                ),
            ]
        )
    }

    @Test("Doubling servings doubles scalable amounts")
    func doublingServings() throws {
        let scaled = sampleRecipe().scaled(toServings: 4)

        #expect(scaled.servings == 4)
        #expect(scaled.ingredients[0].quantity == Quantity(600, .gram))
        #expect(scaled.ingredients[1].quantity == Quantity(200, .gram))
    }

    @Test("Unquantified and non-scaling ingredients are left alone")
    func exemptIngredients() {
        let scaled = sampleRecipe().scaled(toServings: 6)

        #expect(scaled.ingredients[2].quantity == nil)
        #expect(scaled.ingredients[3].quantity == Quantity(2, .tablespoon))
    }

    @Test("Scaling preserves identity so it cannot be mistaken for a new recipe")
    func identityPreserved() {
        let original = sampleRecipe()
        let scaled = original.scaled(toServings: 4)

        #expect(scaled.id == original.id)
        #expect(scaled.ingredients.map(\.id) == original.ingredients.map(\.id))
    }

    @Test("Scaling to the same or an invalid serving count is a no-op")
    func noOpScaling() {
        let original = sampleRecipe()

        #expect(original.scaled(toServings: 2) == original)
        #expect(original.scaled(toServings: 0) == original)
        #expect(original.scaled(by: 1) == original)
        #expect(original.scaled(by: -1) == original)
    }

    @Test("Resolved grams scale along with the amount")
    func resolvedGramsScale() throws {
        var recipe = sampleRecipe()
        recipe.ingredients[0].resolvedGrams = 300

        let scaled = recipe.scaled(toServings: 6)
        #expect(scaled.ingredients[0].resolvedGrams == 900)
    }
}
