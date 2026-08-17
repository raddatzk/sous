import Foundation
import SwiftData
import Testing
@testable import SousKit

@MainActor
@Suite("Shopping library")
struct ShoppingLibraryTests {
    private func makeLibrary() throws -> (ShoppingLibrary, SwiftDataRecipeStore, MealPlanLibrary) {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let recipes = SwiftDataRecipeStore(modelContainer: container)
        let plan = MealPlanLibrary(
            store: SwiftDataMealPlanStore(modelContainer: container),
            recipeStore: recipes
        )
        let shopping = ShoppingLibrary(
            mealPlan: plan,
            recipeStore: recipes,
            store: SwiftDataShoppingListStore(modelContainer: container)
        )
        return (shopping, recipes, plan)
    }

    @Test("The list is built from what is planned this week")
    func listFromPlan() async throws {
        let (shopping, recipes, plan) = try makeLibrary()
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten")
        try await recipes.save(recipe)
        await plan.add(recipe, to: Date())

        await shopping.reload()
        #expect(shopping.items.map(\.name) == ["Tomaten"])
        #expect(shopping.items[0].quantities == [Quantity(300, .gram)])
    }

    @Test("Ticking something off survives a rebuild")
    func checksSurviveReload() async throws {
        let (shopping, recipes, plan) = try makeLibrary()
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten")
        try await recipes.save(recipe)
        await plan.add(recipe, to: Date())
        await shopping.reload()

        await shopping.toggle(try #require(shopping.items.first))
        await shopping.reload()

        #expect(shopping.checkedItems.map(\.name) == ["Tomaten"])
        #expect(shopping.openItems.isEmpty)
    }

    @Test("A line typed by hand is parsed like an ingredient")
    func manualItems() async throws {
        let (shopping, _, _) = try makeLibrary()

        await shopping.addItem("2 kg Kartoffeln")
        #expect(shopping.items.map(\.name) == ["Kartoffeln"])
        #expect(shopping.items[0].quantities == [Quantity(2, .kilogram)])
        #expect(shopping.items[0].isManual)

        await shopping.removeManual(try #require(shopping.items.first))
        #expect(shopping.items.isEmpty)
    }

    @Test("Clearing removes the ticks after the shopping is done")
    func clearing() async throws {
        let (shopping, recipes, plan) = try makeLibrary()
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten\nSalz")
        try await recipes.save(recipe)
        await plan.add(recipe, to: Date())
        await shopping.reload()

        await shopping.toggle(try #require(shopping.items.first))
        await shopping.clearChecked()

        #expect(shopping.checkedItems.isEmpty)
        #expect(shopping.openItems.count == 2)
    }
}
