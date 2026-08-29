import Foundation
import Testing
@testable import SousKit

@Suite("Shopping list")
struct ShoppingListTests {
    private func build(_ planned: [(Recipe, Int)], recipes: [Recipe] = []) -> ShoppingCapture {
        ShoppingListBuilder.build(from: planned.map { (recipe: $0.0, servings: $0.1) }) { id in
            recipes.first { $0.id == id }
        }
    }

    /// The one item the capture's demands for `key` would bundle into —
    /// what the list shows after the store has filed them.
    private func item(_ capture: ShoppingCapture, for name: String) -> ShoppingItem {
        let key = ShoppingItem.key(for: name)
        let captured = capture.demands.filter { $0.key == key }
        return ShoppingItem(
            key: key,
            name: captured.first?.displayName ?? key,
            demands: captured.map(\.demand)
        )
    }

    private func names(_ capture: ShoppingCapture) -> [String] {
        var seen = Set<String>()
        return capture.demands.compactMap { seen.insert($0.key).inserted ? $0.displayName : nil }
    }

    /// The capture for one recipe with only some of its lines picked.
    private func build(
        _ recipe: Recipe, _ servings: Int, picking lines: Set<UUID>?, recipes: [Recipe] = []
    ) -> ShoppingCapture {
        ShoppingListBuilder.build(from: recipe, servings: servings, selecting: lines) { id in
            recipes.first { $0.id == id }
        }
    }

    @Test("Only the picked lines land on the list")
    func picksSomeLines() {
        let recipe = Recipe(
            title: "Salat", servings: 2,
            ingredientsText: "300 g Tomaten\n1 Zwiebel\n2 EL Öl"
        )
        let picked = Set(recipe.ingredients.filter { $0.name != "Zwiebel" }.map(\.id))

        let capture = build(recipe, 2, picking: picked)
        #expect(names(capture) == ["Tomate", "Öl"])
        // The recipe is on the list either way — a plan entry with a dial,
        // scaling what was picked.
        #expect(capture.planEntries.count == 1)
        #expect(capture.planEntries[0].servingsCaptured == 2)
    }

    @Test("Picking nothing is not the same as picking everything")
    func emptyPickIsNotEverything() {
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten")

        #expect(build(recipe, 2, picking: []).demands.isEmpty)
        #expect(build(recipe, 2, picking: nil).demands.count == 1)
    }

    @Test("A picked line that is a recipe brings that recipe along entire")
    func pickedLinkKeepsItsWholeRecipe() {
        let naan = Recipe(title: "Naan", servings: 2, ingredientsText: "300 g Mehl\n7 g Hefe")
        let curry = Recipe(
            title: "Curry", servings: 2,
            ingredientsText: "400 ml Kokosmilch\n2 Portionen \(RecipeLink.markdown(title: "Naan", id: naan.id))"
        )
        let link = try! #require(curry.ingredients.last)

        // Only the naan line picked: its own two ingredients arrive, the
        // coconut milk does not.
        let capture = build(curry, 2, picking: [link.id], recipes: [naan])
        #expect(names(capture) == ["Mehl", "Hefe"])
    }

    @Test("A line left out stays out however far the dial is turned")
    func unpickedLinesDoNotComeBack() {
        let recipe = Recipe(
            title: "Salat", servings: 2, ingredientsText: "300 g Tomaten\n1 Zwiebel"
        )
        let picked = Set(recipe.ingredients.filter { $0.name == "Tomaten" }.map(\.id))

        // The dial scales the captured demands and never reads the recipe
        // again, so the onion has no way back.
        let capture = build(recipe, 2, picking: picked)
        var turned = capture.planEntries[0]
        turned.servingsCurrent = 4
        let effective = capture.demands.map {
            ShoppingDemandScaling.effectiveQuantity(
                captured: $0.demand.quantity,
                scales: $0.demand.scales,
                isScaleDiff: false,
                checkedAtServings: nil,
                planEntry: turned
            )
        }
        #expect(effective == [Quantity(600, .gram)])
    }

    @Test("Amounts of the same ingredient bundle at display, as separate demands")
    func amountsAddUp() throws {
        let first = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten")
        let second = Recipe(title: "Sauce", servings: 2, ingredientsText: "200 g Tomaten")

        let capture = build([(first, 2), (second, 2)])
        let tomatoes = item(capture, for: "Tomaten")
        // Two demands stay two rows — bundling never swallows a contribution.
        #expect(tomatoes.demands.count == 2)
        #expect(tomatoes.quantities == [Quantity(500, .gram)])
        #expect(tomatoes.originTitles == ["Salat", "Sauce"])
    }

    @Test("Every planned recipe becomes a plan entry at its captured scale")
    func planEntriesAreCaptured() {
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten")

        let capture = build([(recipe, 6)])
        #expect(capture.planEntries.count == 1)
        #expect(capture.planEntries[0].recipeID == recipe.id)
        #expect(capture.planEntries[0].servingsCaptured == 6)
        #expect(capture.planEntries[0].servingsCurrent == 6)
        #expect(capture.demands[0].demand.planEntryID == capture.planEntries[0].id)
    }

    @Test("Different units of one dimension are converted before adding")
    func unitsAreConverted() {
        let first = Recipe(title: "A", servings: 2, ingredientsText: "300 g Mehl")
        let second = Recipe(title: "B", servings: 2, ingredientsText: "0,2 kg Mehl")

        let capture = build([(first, 2), (second, 2)])
        #expect(item(capture, for: "Mehl").quantities == [Quantity(500, .gram)])
    }

    @Test("Amounts that cannot be combined stay side by side")
    func incompatibleUnits() {
        let first = Recipe(title: "A", servings: 2, ingredientsText: "2 Stk. Zwiebeln")
        let second = Recipe(title: "B", servings: 2, ingredientsText: "100 g Zwiebeln")

        let capture = build([(first, 2), (second, 2)])
        #expect(item(capture, for: "Zwiebeln").quantities.count == 2)
    }

    @Test("An ingredient without an amount is still on the list, and never scales")
    func unquantified() {
        let recipe = Recipe(title: "A", servings: 2, ingredientsText: "Salz\nPfeffer")

        let capture = build([(recipe, 2)])
        #expect(names(capture) == ["Salz", "Pfeffer"])
        #expect(capture.demands[0].demand.quantity == nil)
        #expect(!capture.demands[0].demand.scales)
    }

    @Test("Planning for more people multiplies what has to be bought")
    func scaledServings() {
        let recipe = Recipe(title: "A", servings: 2, ingredientsText: "300 g Tomaten")

        #expect(build([(recipe, 6)]).demands[0].demand.quantity == Quantity(900, .gram))
    }

    @Test("A linked recipe contributes its ingredients, hung on the parent's plan entry")
    func linkedRecipesAreResolved() {
        let naan = Recipe(title: "Naan", servings: 2, ingredientsText: "250 g Mehl\n1 TL Hefe")
        let curry = Recipe(
            title: "Curry",
            servings: 2,
            ingredientsText: "400 ml Kokosmilch\n2 Portionen \(RecipeLink.markdown(title: "Naan", id: naan.id))"
        )

        let capture = build([(curry, 2)], recipes: [naan])
        #expect(names(capture) == ["Kokosmilch", "Mehl", "Hefe"])
        let flour = capture.demands[1].demand
        #expect(flour.quantity == Quantity(250, .gram))
        // Scaling the curry must take the naan along — the demand belongs
        // to the curry's plan entry, but reads as coming from the naan.
        #expect(flour.planEntryID == capture.planEntries[0].id)
        #expect(flour.originTitle == "Naan")
        #expect(flour.scales)
    }

    @Test("The amount of a linked recipe is read as its servings")
    func linkedServings() {
        let naan = Recipe(title: "Naan", servings: 2, ingredientsText: "250 g Mehl")
        let curry = Recipe(
            title: "Curry",
            servings: 2,
            ingredientsText: "4 Portionen \(RecipeLink.markdown(title: "Naan", id: naan.id))"
        )

        let capture = build([(curry, 2)], recipes: [naan])
        #expect(capture.demands[0].demand.quantity == Quantity(500, .gram))
    }

    @Test("A subrecipe wanted without an amount is taken as written and does not scale")
    func linkedWithoutServings() {
        let naan = Recipe(title: "Naan", servings: 2, ingredientsText: "250 g Mehl")
        let curry = Recipe(
            title: "Curry",
            servings: 2,
            ingredientsText: "\(RecipeLink.markdown(title: "Naan", id: naan.id))"
        )

        let capture = build([(curry, 2)], recipes: [naan])
        #expect(capture.demands[0].demand.quantity == Quantity(250, .gram))
        #expect(!capture.demands[0].demand.scales)
    }

    @Test("A recipe linking itself does not loop forever")
    func cycleSafety() {
        var recipe = Recipe(title: "Selbstbezug", servings: 2, ingredientsText: "100 g Mehl")
        recipe.ingredientsText += "\n1 Portion \(RecipeLink.markdown(title: "Selbstbezug", id: recipe.id))"

        let capture = build([(recipe, 2)], recipes: [recipe])
        #expect(names(capture) == ["Mehl", "Selbstbezug"])
    }

    @Test("A link that cannot be resolved stays as a line of its own")
    func unresolvedLink() {
        let recipe = Recipe(
            title: "Curry",
            servings: 2,
            ingredientsText: "1 Portion \(RecipeLink.markdown(title: "Naan", id: UUID()))"
        )

        let capture = build([(recipe, 2)])
        #expect(names(capture) == ["Naan"])
    }
}

extension ShoppingListTests {
    @Test("Cooking measures are written beside what is bought, not converted")
    func spoonsStaySpoons() {
        let first = Recipe(title: "A", servings: 2, ingredientsText: "100 g Mehl")
        let second = Recipe(title: "B", servings: 2, ingredientsText: "3 EL Mehl")
        let third = Recipe(title: "C", servings: 2, ingredientsText: "1 TL Mehl")

        let capture = build([(first, 2), (second, 2), (third, 2)])
        #expect(item(capture, for: "Mehl").quantities
            == [Quantity(100, .gram), Quantity(3, .tablespoon), Quantity(1, .teaspoon)])
    }

    @Test("The same spoon adds up with itself")
    func identicalSpoons() {
        let first = Recipe(title: "A", servings: 2, ingredientsText: "2 EL Öl")
        let second = Recipe(title: "B", servings: 2, ingredientsText: "1 EL Öl")

        let capture = build([(first, 2), (second, 2)])
        #expect(item(capture, for: "Öl").quantities == [Quantity(3, .tablespoon)])
    }

    @Test("Millilitres and litres are one measure, grams and kilos another")
    func groupsThatAddUp() {
        let first = Recipe(title: "A", servings: 2, ingredientsText: "500 ml Milch")
        let second = Recipe(title: "B", servings: 2, ingredientsText: "1 l Milch")

        let capture = build([(first, 2), (second, 2)])
        #expect(item(capture, for: "Milch").quantities == [Quantity(1500, .milliliter)])
    }
}

extension ShoppingListTests {
    @Test("The total is the sum of the contributions, whatever their origin")
    func totalFollowsContributions() {
        let item = ShoppingItem(
            key: "tomaten",
            name: "Tomaten",
            demands: [
                ShoppingDemand(originTitle: "Salat", quantity: Quantity(300, .gram)),
                ShoppingDemand(originTitle: "Sauce", quantity: Quantity(200, .gram)),
            ],
            manualQuantities: [Quantity(500, .gram)]
        )

        // 300 + 200 from two dishes, plus 500 added by hand.
        #expect(item.quantities == [Quantity(1000, .gram)])
    }

    @Test("Lapsed demand is annotation, not appetite")
    func lapsedStaysOutOfTheTotal() {
        let item = ShoppingItem(
            key: "tomaten",
            name: "Tomaten",
            demands: [
                ShoppingDemand(originTitle: "Salat", quantity: Quantity(300, .gram), lapsedQuantity: Quantity(100, .gram)),
                ShoppingDemand(originTitle: "Sauce", quantity: Quantity(200, .gram), isLapsed: true),
            ]
        )

        #expect(item.quantities == [Quantity(300, .gram)])
        #expect(item.lapsedQuantities == [Quantity(300, .gram)])
    }
}
