import Foundation
import Testing
@testable import SousKit

@Suite("Shopping list")
struct ShoppingListTests {
    private func build(_ planned: [(Recipe, Int)], recipes: [Recipe] = []) -> [ShoppingItem] {
        ShoppingListBuilder.build(from: planned.map { (recipe: $0.0, servings: $0.1) }) { id in
            recipes.first { $0.id == id }
        }
    }

    @Test("Amounts of the same ingredient are added together")
    func amountsAddUp() throws {
        let first = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten")
        let second = Recipe(title: "Sauce", servings: 2, ingredientsText: "200 g Tomaten")

        let list = build([(first, 2), (second, 2)])
        #expect(list.count == 1)
        #expect(list[0].quantities == [Quantity(500, .gram)])
        #expect(list[0].recipeTitles == ["Salat", "Sauce"])
    }

    @Test("Different units of one dimension are converted before adding")
    func unitsAreConverted() {
        let first = Recipe(title: "A", servings: 2, ingredientsText: "300 g Mehl")
        let second = Recipe(title: "B", servings: 2, ingredientsText: "0,2 kg Mehl")

        let list = build([(first, 2), (second, 2)])
        #expect(list[0].quantities == [Quantity(500, .gram)])
    }

    @Test("Amounts that cannot be combined stay side by side")
    func incompatibleUnits() {
        let first = Recipe(title: "A", servings: 2, ingredientsText: "2 Stk. Zwiebeln")
        let second = Recipe(title: "B", servings: 2, ingredientsText: "100 g Zwiebeln")

        let list = build([(first, 2), (second, 2)])
        #expect(list.count == 1)
        #expect(list[0].quantities.count == 2)
    }

    @Test("An ingredient without an amount is still on the list")
    func unquantified() {
        let recipe = Recipe(title: "A", servings: 2, ingredientsText: "Salz\nPfeffer")

        let list = build([(recipe, 2)])
        #expect(list.map(\.name) == ["Salz", "Pfeffer"])
        #expect(list[0].quantities.isEmpty)
    }

    @Test("Planning for more people multiplies what has to be bought")
    func scaledServings() {
        let recipe = Recipe(title: "A", servings: 2, ingredientsText: "300 g Tomaten")

        #expect(build([(recipe, 6)])[0].quantities == [Quantity(900, .gram)])
    }

    @Test("A linked recipe contributes its ingredients, not itself")
    func linkedRecipesAreResolved() {
        let naan = Recipe(title: "Naan", servings: 2, ingredientsText: "250 g Mehl\n1 TL Hefe")
        let curry = Recipe(
            title: "Curry",
            servings: 2,
            ingredientsText: "400 ml Kokosmilch\n2 Portionen \(RecipeLink.markdown(title: "Naan", id: naan.id))"
        )

        let list = build([(curry, 2)], recipes: [naan])
        #expect(list.map(\.name) == ["Kokosmilch", "Mehl", "Hefe"])
        #expect(list[1].quantities == [Quantity(250, .gram)])
        #expect(list[1].recipeTitles == ["Naan"])
    }

    @Test("The amount of a linked recipe is read as its servings")
    func linkedServings() {
        let naan = Recipe(title: "Naan", servings: 2, ingredientsText: "250 g Mehl")
        let curry = Recipe(
            title: "Curry",
            servings: 2,
            ingredientsText: "4 Portionen \(RecipeLink.markdown(title: "Naan", id: naan.id))"
        )

        let list = build([(curry, 2)], recipes: [naan])
        #expect(list[0].quantities == [Quantity(500, .gram)])
    }

    @Test("A recipe linking itself does not loop forever")
    func cycleSafety() {
        var recipe = Recipe(title: "Selbstbezug", servings: 2, ingredientsText: "100 g Mehl")
        recipe.ingredientsText += "\n1 Portion \(RecipeLink.markdown(title: "Selbstbezug", id: recipe.id))"

        let list = build([(recipe, 2)], recipes: [recipe])
        #expect(list.map(\.name) == ["Mehl", "Selbstbezug"])
    }

    @Test("A link that cannot be resolved stays as a line of its own")
    func unresolvedLink() {
        let recipe = Recipe(
            title: "Curry",
            servings: 2,
            ingredientsText: "1 Portion \(RecipeLink.markdown(title: "Naan", id: UUID()))"
        )

        let list = build([(recipe, 2)])
        #expect(list.map(\.name) == ["Naan"])
    }
}
