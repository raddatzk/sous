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
            ingredients: [
                RecipeIngredient(
                    name: "Pizzateig",
                    quantity: Quantity(1, .custom("Portion")),
                    group: "Boden",
                    linkedRecipeID: UUID()
                )
            ],
            steps: [RecipeStep(text: "Backen", durationSeconds: 900)],
            categories: ["Italienisch"],
            source: RecipeSource(kind: .web, url: URL(string: "https://example.org"), name: "Example")
        )

        let data = try SousCoding.encoder.encode(recipe)
        let decoded = try SousCoding.decoder.decode(Recipe.self, from: data)
        #expect(decoded == recipe)
    }

    @Test("Ingredient groups keep the order they first appear in")
    func ingredientGrouping() {
        let recipe = Recipe(
            title: "Lasagne",
            ingredients: [
                RecipeIngredient(name: "Mehl", group: "Teig"),
                RecipeIngredient(name: "Hackfleisch", group: "Sauce"),
                RecipeIngredient(name: "Ei", group: "Teig"),
                RecipeIngredient(name: "Salz"),
            ]
        )

        let groups = recipe.ingredientGroups
        #expect(groups.map(\.group) == ["Teig", "Sauce", nil])
        #expect(groups[0].ingredients.map(\.name) == ["Mehl", "Ei"])
    }

    @Test("Linked recipes are collected from ingredients and steps")
    func linkedRecipes() {
        let dough = UUID()
        let sauce = UUID()
        let recipe = Recipe(
            title: "Pizza",
            ingredients: [RecipeIngredient(name: "Teig", linkedRecipeID: dough)],
            steps: [RecipeStep(text: "Sauce verteilen", linkedRecipeID: sauce)]
        )

        #expect(recipe.linkedRecipeIDs == [dough, sauce])
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
