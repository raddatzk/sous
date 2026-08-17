import Foundation
import Testing
@testable import SousKit

@Suite("Recipe aggregate")
struct RecipeTests {
    @Test("The whole aggregate survives a JSON round trip")
    func aggregateRoundTrip() throws {
        let recipe = Recipe(
            title: "Pizza",
            servings: 4,
            ingredientsText: "Boden:\n1 Portion Pizzateig",
            instructionsText: "Backen",
            categories: ["Italienisch"],
            source: RecipeSource(kind: .web, url: URL(string: "https://example.org"), name: "Example"),
            createdAt: .nowInSyncPrecision,
            updatedAt: .nowInSyncPrecision
        )

        let data = try SousCoding.encoder.encode(recipe)
        let decoded = try SousCoding.decoder.decode(Recipe.self, from: data)
        #expect(decoded == recipe)
    }

    @Test("Ingredients and steps are parsed from the stored text")
    func derivedStructure() {
        let recipe = Recipe(
            title: "Pfanne",
            ingredientsText: "300 g Zucchini, gewürfelt",
            instructionsText: "1. Schneiden\n2. Anbraten"
        )

        #expect(recipe.ingredients.count == 1)
        #expect(recipe.ingredients[0].preparation == "gewürfelt")
        #expect(recipe.steps.map(\.text) == ["Schneiden", "Anbraten"])
    }

    @Test("Ingredient groups keep the order they first appear in")
    func ingredientGrouping() {
        let recipe = Recipe(
            title: "Lasagne",
            ingredientsText: """
            Teig:
            300 g Mehl
            1 Ei

            Sauce:
            500 g Hackfleisch
            """
        )

        let groups = recipe.ingredientGroups()
        #expect(groups.map(\.group) == ["Teig", "Sauce"])
        #expect(groups[0].ingredients.map(\.name) == ["Mehl", "Ei"])
    }

    @Test("Groups can be read at a different serving count")
    func scaledGroups() {
        let recipe = Recipe(title: "Teig", servings: 2, ingredientsText: "300 g Mehl")

        let groups = recipe.ingredientGroups(scaledToServings: 6)
        #expect(groups[0].ingredients[0].quantity == Quantity(900, .gram))
    }

    @Test("A recipe without ingredients or instructions reports itself empty")
    func emptiness() {
        #expect(Recipe(title: "Leer").isEmpty)
        #expect(!Recipe(title: "Voll", ingredientsText: "Salz").isEmpty)
    }

    @Test("A tombstoned recipe reports itself as deleted")
    func tombstone() throws {
        var recipe = Recipe(title: "Alt")
        #expect(!recipe.isDeleted)

        recipe.deletedAt = .nowInSyncPrecision
        #expect(recipe.isDeleted)

        let data = try SousCoding.encoder.encode(recipe)
        let decoded = try SousCoding.decoder.decode(Recipe.self, from: data)
        #expect(decoded.deletedAt == recipe.deletedAt)
    }
}
