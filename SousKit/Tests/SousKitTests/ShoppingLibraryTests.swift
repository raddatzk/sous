import Foundation
import SwiftData
import Testing
@testable import SousKit

@MainActor
@Suite("Shopping library")
struct ShoppingLibraryTests {
    private func makeLibrary() throws -> (ShoppingLibrary, SwiftDataRecipeStore) {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let recipes = SwiftDataRecipeStore(modelContainer: container)
        let shopping = ShoppingLibrary(
            store: SwiftDataShoppingListStore(modelContainer: container),
            recipeStore: recipes
        )
        return (shopping, recipes)
    }

    @Test("A recipe's ingredients are put on the list on request")
    func addingARecipe() async throws {
        let (shopping, _) = try makeLibrary()
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten\nSalz")

        await shopping.add(recipe)
        #expect(shopping.items.map(\.name) == ["Tomaten", "Salz"])
        #expect(shopping.items[0].quantities == [Quantity(300, .gram)])
        #expect(shopping.items[0].recipeTitles == ["Salat"])
        #expect(shopping.items[0].sources[0].quantities == [Quantity(300, .gram)])
    }

    @Test("Adding for more people scales what has to be bought")
    func addingScaled() async throws {
        let (shopping, _) = try makeLibrary()
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten")

        await shopping.add(recipe, servings: 6)
        #expect(shopping.items[0].quantities == [Quantity(900, .gram)])
    }

    @Test("Adding a second recipe folds amounts into the lines already there")
    func addingTwice() async throws {
        let (shopping, _) = try makeLibrary()
        await shopping.add(Recipe(title: "A", servings: 2, ingredientsText: "300 g Tomaten"))
        await shopping.add(Recipe(title: "B", servings: 2, ingredientsText: "200 g Tomaten"))

        #expect(shopping.items.count == 1)
        #expect(shopping.items[0].quantities == [Quantity(500, .gram)])
        #expect(shopping.items[0].recipeTitles == ["A", "B"])
    }

    @Test("The list stays put when a recipe changes afterwards")
    func listDoesNotFollowRecipes() async throws {
        let (shopping, recipes) = try makeLibrary()
        var recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten")
        try await recipes.save(recipe)
        await shopping.add(recipe)

        recipe.ingredientsText = "Nichts mehr"
        try await recipes.save(recipe)
        await shopping.reload()

        #expect(shopping.items.map(\.name) == ["Tomaten"])
    }

    @Test("A linked recipe contributes its ingredients, not its name")
    func linkedRecipes() async throws {
        let (shopping, recipes) = try makeLibrary()
        let naan = Recipe(title: "Naan", servings: 2, ingredientsText: "250 g Mehl")
        try await recipes.save(naan)
        let curry = Recipe(
            title: "Curry",
            servings: 2,
            ingredientsText: "400 ml Kokosmilch\n2 Portionen \(RecipeLink.markdown(title: "Naan", id: naan.id))"
        )

        await shopping.add(curry)
        #expect(shopping.items.map(\.name) == ["Kokosmilch", "Mehl"])
    }

    @Test("Ticking and clearing behave like a shopping trip")
    func tickingAndClearing() async throws {
        let (shopping, _) = try makeLibrary()
        await shopping.add(Recipe(title: "A", servings: 2, ingredientsText: "300 g Tomaten\nSalz"))

        await shopping.toggle(try #require(shopping.items.first))
        await shopping.reload()
        #expect(shopping.checkedItems.map(\.name) == ["Tomaten"])

        await shopping.clearChecked()
        #expect(shopping.items.map(\.name) == ["Salz"])
    }

    @Test("Adding something again puts a ticked-off line back in play")
    func addingUnchecks() async throws {
        let (shopping, _) = try makeLibrary()
        await shopping.add(Recipe(title: "A", servings: 2, ingredientsText: "300 g Tomaten"))
        await shopping.toggle(try #require(shopping.items.first))

        await shopping.add(Recipe(title: "B", servings: 2, ingredientsText: "200 g Tomaten"))
        #expect(shopping.openItems.map(\.name) == ["Tomaten"])
        #expect(shopping.items[0].quantities == [Quantity(500, .gram)])
    }

    @Test("A line typed by hand is parsed like an ingredient")
    func manualItems() async throws {
        let (shopping, _) = try makeLibrary()

        await shopping.addItem("2 kg Kartoffeln")
        #expect(shopping.items.map(\.name) == ["Kartoffeln"])
        #expect(shopping.items[0].quantities == [Quantity(2, .kilogram)])
        #expect(shopping.items[0].isManual)

        await shopping.remove(try #require(shopping.items.first))
        #expect(shopping.items.isEmpty)
    }
}

extension ShoppingLibraryTests {
    @Test("Grouping by recipe shows each dish's own share")
    func groupedByRecipe() async throws {
        let (shopping, _) = try makeLibrary()
        await shopping.add(Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten"))
        await shopping.add(Recipe(title: "Sauce", servings: 2, ingredientsText: "200 g Tomaten\n1 Zwiebel"))
        await shopping.addItem("Kaffee")

        // One line when shopping…
        #expect(shopping.items.map(\.name) == ["Tomaten", "Zwiebel", "Kaffee"])
        #expect(shopping.items[0].quantities == [Quantity(500, .gram)])

        // …and split by dish when checking.
        let groups = shopping.byRecipe
        #expect(groups.map(\.recipe) == ["Salat", "Sauce", ShoppingLibrary.ungroupedTitle])
        #expect(groups[0].items[0].quantities == [Quantity(300, .gram)])
        #expect(groups[1].items[0].quantities == [Quantity(200, .gram)])
        #expect(groups[1].items.map(\.name) == ["Tomaten", "Zwiebel"])
        #expect(groups[2].items.map(\.name) == ["Kaffee"])
    }
}

extension ShoppingLibraryTests {
    @Test("Topping up a line by hand shows up in both readings")
    func manualTopUpIsAccountedFor() async throws {
        let (shopping, _) = try makeLibrary()
        await shopping.add(Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten"))
        await shopping.addItem("700 g Tomaten")

        // One line, and the total counts both.
        #expect(shopping.items.count == 1)
        #expect(shopping.items[0].quantities == [Quantity(1000, .gram)])

        // Grouped by dish, the recipe's share and the rest are both visible,
        // and together they add back up to the total.
        let groups = shopping.byRecipe
        #expect(groups.map(\.recipe) == ["Salat", ShoppingLibrary.ungroupedTitle])
        #expect(groups[0].items[0].quantities == [Quantity(300, .gram)])
        #expect(groups[1].items[0].quantities == [Quantity(700, .gram)])
    }
}
