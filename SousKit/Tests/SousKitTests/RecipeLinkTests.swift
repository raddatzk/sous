import Foundation
import Testing
@testable import SousKit

@Suite("Recipe links")
struct RecipeLinkTests {
    @Test("A link round-trips through its URL")
    func urlRoundTrip() throws {
        let id = UUID()
        let url = RecipeLink.url(for: id)

        #expect(RecipeLink.recipeID(from: url) == id)
    }

    @Test("Foreign URLs are not mistaken for recipe links")
    func foreignURLs() throws {
        #expect(RecipeLink.recipeID(from: try #require(URL(string: "https://example.org"))) == nil)
        #expect(RecipeLink.recipeID(from: try #require(URL(string: "sous://household/42"))) == nil)
        #expect(RecipeLink.recipeID(from: try #require(URL(string: "sous://recipe/nonsense"))) == nil)
    }

    @Test("References are found in ingredients and instructions, without duplicates")
    func referencesInRecipe() {
        let dough = UUID()
        let sauce = UUID()

        let recipe = Recipe(
            title: "Pizza",
            ingredientsText: """
            1 Portion \(RecipeLink.markdown(title: "Pizzateig", id: dough))
            200 ml \(RecipeLink.markdown(title: "Tomatensauce", id: sauce))
            """,
            instructionsText: "Den \(RecipeLink.markdown(title: "Teig", id: dough)) ausrollen"
        )

        #expect(recipe.linkedRecipeIDs == [dough, sauce])
    }

    @Test("A linked ingredient keeps its amount and reads as its title")
    func linkedIngredientParses() {
        let id = UUID()
        let ingredient = IngredientParser.parseLine("1 Portion \(RecipeLink.markdown(title: "Pizzateig", id: id))")

        #expect(ingredient.quantity == Quantity(1, .piece))
        #expect(ingredient.name.contains("Pizzateig"))
    }

    @Test("A recipe without links references nothing")
    func noLinks() {
        #expect(Recipe(title: "Salat", ingredientsText: "2 Tomaten").linkedRecipeIDs.isEmpty)
    }
}
