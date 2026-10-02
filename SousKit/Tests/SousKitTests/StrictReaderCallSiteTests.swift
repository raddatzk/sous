import Foundation
import SwiftData
import Testing
@testable import SousKit

/// Every place that reads an ingredient line, read through
/// ``IngredientLineReader`` (phase 5): what a line in the fixed form gives,
/// and what one outside it gives.
@MainActor
@Suite("Call sites of the strict reader")
struct StrictReaderCallSiteTests {
    private let text = """
    300 g rote Linsen, getrocknet
    300 ml dünne Kokosmilch (oder mehr)
    1 Zwiebel, rot
    """

    // MARK: - Recipe.ingredients, and scaling through it

    @Test("Recipe.ingredients reads the fixed form, and scales a line outside it by its amount")
    func recipeIngredients() {
        let recipe = Recipe(title: "Dal", servings: 2, ingredientsText: text)
        let lines = recipe.ingredients(readWith: .bundled)
        #expect(lines.map(\.isOutsideForm) == [false, true, false])
        #expect(lines[0].name == "rote Linsen")
        #expect(lines[1].name == "dünne Kokosmilch (oder mehr)")
        #expect(lines[2].preparation == "rot")

        let doubled = recipe.scaledIngredients(toServings: 4, catalog: .bundled)
        #expect(doubled.map(\.quantity) == [
            Quantity(600, .gram), Quantity(600, .milliliter), Quantity(2, .piece),
        ])
    }

    // MARK: - Nutrition

    @Test("A line outside the form gets no nutrition, even where a tolerant reading would find a row")
    func nutrition() {
        // The old parser read "Zwiebeln gegart" as cooked onions.
        let recipe = Recipe(title: "Pfanne", servings: 1, ingredientsText: "300 g Zwiebeln gegart\n300 g Zwiebeln, gegart")
        let report = NutritionAggregator.aggregate(recipe: recipe, servings: 1, catalog: .bundled) { _ in nil }
        #expect(report.lines[0].outcome == .gap(.noCatalogMatch))
        #expect(report.lines[1].outcome != .gap(.noCatalogMatch))
        #expect(report.lines[1].state == .cooked)
    }

    // MARK: - Shopping

    private func makeShopping() throws -> (ShoppingLibrary, any RecipeStore) {
        let stores = try StoreBackend.swiftData.makeStores()
        let shopping = ShoppingLibrary(
            store: stores.shopping,
            recipeStore: stores.recipes,
            catalogLibrary: IngredientCatalogLibrary(localAnswers: stores.localAnswers, household: stores.household)
        )
        return (shopping, stores.recipes)
    }

    @Test("A line outside the form goes on the list as raw text with its amount, flagged")
    func shoppingFromRecipe() async throws {
        let (shopping, recipes) = try makeShopping()
        let recipe = Recipe(title: "Dal", servings: 2, ingredientsText: text)
        try await recipes.save(recipe)
        await shopping.add(recipe, servings: 4)

        let raw = try #require(shopping.items.first { $0.name == "dünne Kokosmilch (oder mehr)" })
        #expect(raw.category == nil)
        #expect(raw.quantities == [Quantity(600, .milliliter)])
        #expect(shopping.needsOptimization(raw))

        let lentils = try #require(shopping.items.first { $0.name == "Rote Linsen" })
        #expect(!shopping.needsOptimization(lentils))
        // The annotation is not a variety: one onion, filed as an onion.
        #expect(shopping.items.contains { $0.name == "Zwiebel" })
    }

    @Test("Adding by hand reads through the strict reader, and a typed variety is still bought as one")
    func shoppingByHand() async throws {
        let (shopping, _) = try makeShopping()
        await shopping.addItem("2 kg Kartoffeln")
        await shopping.addItem("Zwiebel, rot")
        await shopping.addItem("1 Glas Einhornstaub")

        #expect(shopping.items.first { $0.name == "Kartoffeln" || $0.name == "Kartoffel" }?.quantities == [Quantity(2, .kilogram)])
        #expect(shopping.items.contains { $0.name == "Rote Zwiebel" })
        #expect(shopping.items.first { $0.name == "Einhornstaub" }?.quantities == [Quantity(1, .jar)])
    }

    // MARK: - Completion

    @Test("Completion looks at the name being typed, before any annotation")
    func completion() {
        #expect(IngredientCompletion.partialName(in: "300 g Toma", catalog: .bundled) == "Toma")
        #expect(IngredientCompletion.partialName(in: "300 g Toma, gewürfelt", catalog: .bundled) == "Toma")
        #expect(IngredientCompletion.partialName(in: "300 g Tomaten, gewürfelt", catalog: .bundled) == "Tomaten")
        let tomato = CatalogIngredient(name: "Tomate", category: .vegetables)
        #expect(IngredientCompletion.completed(line: "300 g Toma, gewürfelt", with: tomato) == "300 g Tomate, gewürfelt")
    }

    // MARK: - Step references

    @Test("An amount in an answer reads as the measure of a line would")
    func stepReferenceAmounts() {
        #expect(StepReferencesPrompt.quantity(in: "150 g")?.quantity == Quantity(150, .gram))
        #expect(StepReferencesPrompt.quantity(in: "½ TL")?.quantity == Quantity(0.5, .teaspoon))
        #expect(StepReferencesPrompt.quantity(in: "1 kleine")?.size?.degree == .small)
        #expect(StepReferencesPrompt.quantity(in: "etwa 25 g")?.quantity == Quantity(25, .gram))
        #expect(StepReferencesPrompt.quantity(in: "einer Prise")?.quantity == Quantity(1, .pinch))
        #expect(StepReferencesPrompt.quantity(in: "1 Spritzer")?.quantity == Quantity(1, .splash))
        #expect(StepReferencesPrompt.quantity(in: "etwas") == nil)
    }

    // MARK: - The catalog's unknown words

    @Test("Unknown words are the words of lines outside the form")
    func unknownIngredients() {
        let unknown = IngredientCatalog.bundled.unknownIngredients(in: text + "\n150 g Einhornstaub")
        #expect(unknown == ["dünne Kokosmilch (oder mehr)", "Einhornstaub"])
    }
}
