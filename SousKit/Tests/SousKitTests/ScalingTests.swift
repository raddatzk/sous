import Foundation
import Testing
@testable import SousKit

@Suite("Serving scaling")
struct ScalingTests {
    private func sampleRecipe() -> Recipe {
        Recipe(
            title: "Zucchinipfanne",
            servings: 2,
            ingredientsText: """
            300 g Zucchini
            100 g Feta
            Salz
            """
        )
    }

    @Test("Doubling servings doubles the amounts")
    func doublingServings() {
        let scaled = sampleRecipe().scaledIngredients(toServings: 4)

        #expect(scaled[0].quantity == Quantity(600, .gram))
        #expect(scaled[1].quantity == Quantity(200, .gram))
    }

    @Test("Unquantified ingredients are left alone")
    func unquantified() {
        let scaled = sampleRecipe().scaledIngredients(toServings: 6)

        #expect(scaled[2].name == "Salz")
        #expect(scaled[2].quantity == nil)
    }

    @Test("Scaling never rewrites the text the user typed")
    func textIsUntouched() {
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "3-4 Tomaten")

        // The parser only understands the lower bound of a range, so scaling
        // reads it as 3 — but the line itself must survive intact.
        #expect(recipe.scaledIngredients(toServings: 4)[0].quantity == Quantity(6, .piece))
        #expect(recipe.ingredientsText == "3-4 Tomaten")
    }

    @Test("Scaling to the same or an invalid serving count changes nothing")
    func noOpScaling() {
        let recipe = sampleRecipe()

        #expect(recipe.scaledIngredients(toServings: 2) == recipe.ingredients)
        #expect(recipe.scaledIngredients(toServings: 0) == recipe.ingredients)
        #expect(recipe.scaledIngredients(by: 1) == recipe.ingredients)
        #expect(recipe.scaledIngredients(by: -1) == recipe.ingredients)
    }
}
