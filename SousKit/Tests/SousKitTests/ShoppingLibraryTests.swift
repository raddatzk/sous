import Foundation
import SwiftData
import Testing
@testable import SousKit

@MainActor
@Suite("Shopping library")
struct ShoppingLibraryTests {
    private func makeLibrary(
        _ backend: StoreBackend
    ) throws -> (ShoppingLibrary, any RecipeStore, StoreBackend.StoreSet) {
        let stores = try backend.makeStores()
        let shopping = ShoppingLibrary(
            store: stores.shopping,
            recipeStore: stores.recipes,
            // The pantry flag lives on the vocabulary entry now, so the
            // catalog library is what the list asks about it.
            catalogLibrary: IngredientCatalogLibrary(store: stores.vocabulary)
        )

        return (shopping, stores.recipes, stores)
    }

    /// SwiftData only, and deliberately so: these two write pre-document rows
    /// straight into the store, and only the SwiftData one has a pass that
    /// reads them. The Core Data store is filled through the protocol, where
    /// `snapshot()` has already turned such rows into demands.
    private func makeLegacyLibrary() throws -> (ShoppingLibrary, ModelContainer) {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let shopping = ShoppingLibrary(
            store: SwiftDataShoppingListStore(modelContainer: container),
            recipeStore: SwiftDataRecipeStore(modelContainer: container),
            catalogLibrary: IngredientCatalogLibrary(
                store: SwiftDataVocabularyStore(modelContainer: container)
            )
        )
        return (shopping, container)
    }

    @Test("A recipe's ingredients are put on the list on request", arguments: StoreBackend.allCases)
    func addingARecipe(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten\nSalz")

        await shopping.add(recipe)
        // Written "300 g Tomaten", listed under the catalog's name.
        #expect(shopping.items.map(\.name) == ["Tomate", "Salz"])
        #expect(shopping.items[0].quantities == [Quantity(300, .gram)])
        #expect(shopping.items[0].originTitles == ["Salat"])
        #expect(shopping.planEntries.map(\.title) == ["Salat"])
    }

    @Test("A recipe stops counting as on the list once it is all bought", arguments: StoreBackend.allCases)
    func boughtOutMeansOffTheList(_ backend: StoreBackend) async throws {
        // What the recipe page's cart button reads. The plan entry behind a
        // recipe is never deleted by shopping it — only by taking it off the
        // list by hand — so a button that asked "is there an entry" said
        // "already on the list" for ever after, including for a recipe the
        // list itself had stopped showing.
        let (shopping, _, _) = try makeLibrary(backend)
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten\n1 Zwiebel")
        await shopping.add(recipe)
        #expect(shopping.hasOpenDemand(forRecipe: recipe.id))

        // Half shopped is still shopping.
        await shopping.toggle(try #require(shopping.items.first))
        #expect(shopping.hasOpenDemand(forRecipe: recipe.id))

        for item in shopping.items where !item.isChecked {
            await shopping.toggle(item)
        }
        #expect(!shopping.hasOpenDemand(forRecipe: recipe.id))
        // The entry is still there, which is what lets a second add mark its
        // demands as arriving late — it just no longer means "outstanding".
        #expect(shopping.planEntries.contains { $0.recipeID == recipe.id })
    }

    @Test("Clearing the bought rows does not leave the recipe claiming a place", arguments: StoreBackend.allCases)
    func clearedRowsLeaveNothingBehind(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten")
        await shopping.add(recipe)
        await shopping.toggle(try #require(shopping.items.first))
        await shopping.clearChecked()

        // The list shows nothing for it any more, so nothing may say it does.
        #expect(!shopping.byRecipe.contains { $0.planEntry?.recipeID == recipe.id })
        #expect(!shopping.hasOpenDemand(forRecipe: recipe.id))
    }

    @Test("A recipe never added has nothing outstanding", arguments: StoreBackend.allCases)
    func anUnaddedRecipeIsNotOnTheList(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        #expect(!shopping.hasOpenDemand(forRecipe: UUID()))
    }

    @Test("A stated state survives the store and annotates the line", arguments: StoreBackend.allCases)
    func statesRoundTripThroughTheStore(_ backend: StoreBackend) async throws {
        // `ShoppingDemand.state` has had a column since the document model
        // landed and has been `.unspecified` in every row ever written — so
        // nothing had ever proven the column carries anything.
        let (shopping, _, stores) = try makeLibrary(backend)
        let recipe = Recipe(
            title: "Auflauf", servings: 2,
            ingredientsText: "500 g Kartoffeln\n300 g Kartoffeln, gegart"
        )
        await shopping.add(recipe)

        // Read back through a second library on the same store: a value that
        // only survives in memory has not been stored.
        let reread = ShoppingLibrary(
            store: stores.shopping,
            recipeStore: stores.recipes,
            catalogLibrary: IngredientCatalogLibrary(store: stores.vocabulary)
        )
        await reread.reload()

        let item = try #require(reread.items.first { $0.name == "Kartoffel" })
        #expect(item.quantities == [Quantity(800, .gram)])
        #expect(item.demands.map(\.state).sorted { $0.rawValue < $1.rawValue }
            == [.cooked, .unspecified])
        let stated = try #require(item.statedQuantities.first)
        #expect(stated.state == .cooked)
        #expect(stated.quantities == [Quantity(300, .gram)])
    }

    @Test("Adding for more people scales what has to be bought", arguments: StoreBackend.allCases)
    func addingScaled(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten")

        await shopping.add(recipe, servings: 6)
        #expect(shopping.items[0].quantities == [Quantity(900, .gram)])
        #expect(shopping.planEntries[0].servingsCaptured == 6)
    }

    @Test("Adding a second recipe bundles into the line already there", arguments: StoreBackend.allCases)
    func addingTwice(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        await shopping.add(Recipe(title: "A", servings: 2, ingredientsText: "300 g Tomaten"))
        await shopping.add(Recipe(title: "B", servings: 2, ingredientsText: "200 g Tomaten"))

        #expect(shopping.items.count == 1)
        #expect(shopping.items[0].quantities == [Quantity(500, .gram)])
        #expect(shopping.items[0].originTitles == ["A", "B"])
        // Bundled for display, but stored as two demands with their origins.
        #expect(shopping.items[0].demands.count == 2)
    }

    @Test("The list stays put when a recipe changes afterwards", arguments: StoreBackend.allCases)
    func listDoesNotFollowRecipes(_ backend: StoreBackend) async throws {
        let (shopping, recipes, _) = try makeLibrary(backend)
        var recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten")
        try await recipes.save(recipe)
        await shopping.add(recipe)

        recipe.ingredientsText = "Nichts mehr"
        try await recipes.save(recipe)
        await shopping.reload()

        #expect(shopping.items.map(\.name) == ["Tomate"])
    }

    @Test("A linked recipe contributes its ingredients, not its name", arguments: StoreBackend.allCases)
    func linkedRecipes(_ backend: StoreBackend) async throws {
        let (shopping, recipes, _) = try makeLibrary(backend)
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

    @Test("Ticking and clearing behave like a shopping trip", arguments: StoreBackend.allCases)
    func tickingAndClearing(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        await shopping.add(Recipe(title: "A", servings: 2, ingredientsText: "300 g Tomaten\nSalz"))

        await shopping.toggle(try #require(shopping.items.first))
        #expect(shopping.checkedItems.map(\.name) == ["Tomate"])

        // Sweeping hides the bought line; nothing is deleted, so the
        // document keeps its memory.
        await shopping.clearChecked()
        #expect(shopping.items.map(\.name) == ["Salz"])
    }

    @Test("A line typed by hand is parsed like an ingredient", arguments: StoreBackend.allCases)
    func manualItems(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)

        await shopping.addItem("2 kg Kartoffeln")
        #expect(shopping.items.map(\.name) == ["Kartoffel"])
        #expect(shopping.items[0].quantities == [Quantity(2, .kilogram)])
        #expect(shopping.items[0].isManual)

        await shopping.remove(try #require(shopping.items.first))
        #expect(shopping.items.isEmpty)
    }
}

// MARK: - Reconciliation: check-off is never reset

extension ShoppingLibraryTests {
    @Test("Re-adding a recipe never un-checks — new demand appends late instead", arguments: StoreBackend.allCases)
    func reAddingNeverUnchecks(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten")
        await shopping.add(recipe)
        await shopping.toggle(try #require(shopping.items.first))

        await shopping.add(recipe)

        // The bought line is still bought.
        #expect(shopping.checkedItems.map(\.quantities) == [[Quantity(300, .gram)]])
        // The new wish is its own open line, marked as arriving late.
        let late = try #require(shopping.openItems.first)
        #expect(late.quantities == [Quantity(300, .gram)])
        #expect(late.isLateAddition)
        #expect(late.demands.allSatisfy { $0.isLate })
        #expect(shopping.planEntries.count == 2)
    }

    @Test("New demand under a checked ingredient lands on a fresh open item", arguments: StoreBackend.allCases)
    func newDemandUnderCheckedItem(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        await shopping.add(Recipe(title: "A", servings: 2, ingredientsText: "300 g Tomaten"))
        await shopping.toggle(try #require(shopping.items.first))

        await shopping.add(Recipe(title: "B", servings: 2, ingredientsText: "200 g Tomaten"))

        #expect(shopping.checkedItems.count == 1)
        #expect(shopping.checkedItems[0].quantities == [Quantity(300, .gram)])
        let late = try #require(shopping.openItems.first)
        #expect(late.quantities == [Quantity(200, .gram)])
        #expect(late.isLateAddition)
    }

    @Test("After sweeping, the next add starts a fresh line, not a late one", arguments: StoreBackend.allCases)
    func addingAfterClearingStartsFresh(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        await shopping.add(Recipe(title: "A", servings: 2, ingredientsText: "300 g Tomaten"))
        await shopping.toggle(try #require(shopping.items.first))
        await shopping.clearChecked()

        await shopping.add(Recipe(title: "B", servings: 2, ingredientsText: "200 g Tomaten"))
        let item = try #require(shopping.items.first)
        #expect(!item.isChecked)
        #expect(!item.isLateAddition)
        #expect(item.quantities == [Quantity(200, .gram)])
    }
}

// MARK: - Coming back to a dish already on the list

extension ShoppingLibraryTests {
    @Test("What was left out at first joins the dish already on the list", arguments: StoreBackend.allCases)
    func toppingUpKeepsOneEntry(_ backend: StoreBackend) async throws {
        // The way back from unticking something in the picker. Adding the
        // recipe again would work — and would leave the meal split across two
        // headings with two portion dials, which is the thing the cook was
        // not asking for.
        let (shopping, _, _) = try makeLibrary(backend)
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten\n1 Zwiebel")
        let tomatoes = try #require(recipe.ingredients.first)
        let onion = try #require(recipe.ingredients.last)

        await shopping.add(recipe, servings: 2, lines: [tomatoes.id])
        #expect(shopping.items.map(\.name) == ["Tomate"])

        let entry = try #require(shopping.openPlanEntry(forRecipe: recipe.id))
        #expect(shopping.listedLines(of: entry) == [tomatoes.id])

        await shopping.add(recipe, lines: [onion.id], joining: entry)

        #expect(shopping.items.map(\.name) == ["Tomate", "Zwiebel"])
        // One dish, one heading, one dial.
        #expect(shopping.planEntries.count == 1)
        #expect(shopping.byRecipe.count { $0.planEntry?.recipeID == recipe.id } == 1)
        #expect(shopping.listedLines(of: entry) == [tomatoes.id, onion.id])
    }

    @Test("A line brought along late follows the dial the dish stands on", arguments: StoreBackend.allCases)
    func toppingUpFollowsTheDial(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten\n100 g Gurke")
        let tomatoes = try #require(recipe.ingredients.first)
        let cucumber = try #require(recipe.ingredients.last)

        await shopping.add(recipe, servings: 2, lines: [tomatoes.id])
        await shopping.setServings(6, for: try #require(shopping.planEntries.first))
        #expect(shopping.items[0].quantities == [Quantity(900, .gram)])

        await shopping.add(
            recipe, lines: [cucumber.id],
            joining: try #require(shopping.openPlanEntry(forRecipe: recipe.id))
        )

        // Captured at the entry's own count and shown at its dial: 100 g for
        // two, so 300 g for the six the dish already stands at.
        let listed = try #require(shopping.items.first { $0.name == "Gurke" })
        #expect(listed.quantities == [Quantity(300, .gram)])

        // And it keeps following it, like everything else under that heading.
        await shopping.setServings(2, for: try #require(shopping.planEntries.first))
        #expect(shopping.items.map(\.quantities)
            == [[Quantity(300, .gram)], [Quantity(100, .gram)]])
    }

    @Test("A dish that is all bought is put on afresh, not topped up", arguments: StoreBackend.allCases)
    func nothingOpenLeavesNothingToJoin(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten")
        await shopping.add(recipe)
        await shopping.toggle(try #require(shopping.items.first))

        // The entry is still there — it is what marks a re-add as late — but
        // there is nothing outstanding to join, so the trolley is offering
        // the dish again rather than asking about the one on the list.
        #expect(shopping.planEntries.contains { $0.recipeID == recipe.id })
        #expect(shopping.openPlanEntry(forRecipe: recipe.id) == nil)
    }

    @Test("A recipe never added has no entry to join", arguments: StoreBackend.allCases)
    func anUnaddedRecipeHasNoEntry(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        #expect(shopping.openPlanEntry(forRecipe: UUID()) == nil)
    }
}

// MARK: - Re-scaling on the list

extension ShoppingLibraryTests {
    @Test("Scaling an open item adjusts it in place", arguments: StoreBackend.allCases)
    func rescalingOpenItems(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        await shopping.add(Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten"))

        await shopping.setServings(4, for: try #require(shopping.planEntries.first))
        #expect(shopping.items.count == 1)
        #expect(shopping.items[0].quantities == [Quantity(600, .gram)])

        // And back down again, still in place.
        await shopping.setServings(1, for: try #require(shopping.planEntries.first))
        #expect(shopping.items.count == 1)
        #expect(shopping.items[0].quantities == [Quantity(150, .gram)])
    }

    @Test("Scaling up past a checked item appends the difference as open late demand", arguments: StoreBackend.allCases)
    func rescalingUpPastChecked(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        await shopping.add(Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten"))
        await shopping.toggle(try #require(shopping.items.first))

        await shopping.setServings(4, for: try #require(shopping.planEntries.first))

        // The basket keeps its 300 g; the missing 300 g are their own line.
        #expect(shopping.checkedItems.map(\.quantities) == [[Quantity(300, .gram)]])
        let difference = try #require(shopping.openItems.first)
        #expect(difference.quantities == [Quantity(300, .gram)])
        #expect(difference.isLateAddition)

        // Turning further up grows the difference row instead of adding more.
        await shopping.setServings(6, for: try #require(shopping.planEntries.first))
        #expect(shopping.openItems.count == 1)
        #expect(shopping.openItems[0].quantities == [Quantity(600, .gram)])
    }

    @Test("Scaling down past a checked item annotates the lapse, not the check", arguments: StoreBackend.allCases)
    func rescalingDownPastChecked(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        await shopping.add(Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten"))
        await shopping.toggle(try #require(shopping.items.first))

        await shopping.setServings(1, for: try #require(shopping.planEntries.first))

        let item = try #require(shopping.items.first)
        #expect(item.isChecked)
        #expect(item.quantities == [Quantity(300, .gram)])
        #expect(item.lapsedQuantities == [Quantity(150, .gram)])

        // Scaling back up withdraws the annotation.
        await shopping.setServings(2, for: try #require(shopping.planEntries.first))
        #expect(try #require(shopping.items.first).lapsedQuantities.isEmpty)
    }

    @Test("Un-checking hands the item back to the stepper and absorbs the difference row", arguments: StoreBackend.allCases)
    func uncheckingAbsorbsDifference(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        await shopping.add(Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten"))
        await shopping.toggle(try #require(shopping.items.first))
        await shopping.setServings(4, for: try #require(shopping.planEntries.first))
        #expect(shopping.items.count == 2)

        await shopping.toggle(try #require(shopping.checkedItems.first))

        // One open line again, derived at the current scale.
        #expect(shopping.items.count == 1)
        #expect(shopping.items[0].quantities == [Quantity(600, .gram)])
        #expect(!shopping.items[0].isChecked)
    }

    @Test("Unquantified demands do not scale", arguments: StoreBackend.allCases)
    func unquantifiedDoesNotScale(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        await shopping.add(Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten\nSalz"))

        await shopping.setServings(4, for: try #require(shopping.planEntries.first))
        let salt = try #require(shopping.items.first { $0.name == "Salz" })
        #expect(salt.quantities.isEmpty)
        #expect(shopping.items.count == 2)
    }

    @Test("Subrecipe demands scale with the parent's plan entry", arguments: StoreBackend.allCases)
    func subrecipesScaleWithParent(_ backend: StoreBackend) async throws {
        let (shopping, recipes, _) = try makeLibrary(backend)
        let naan = Recipe(title: "Naan", servings: 2, ingredientsText: "250 g Mehl")
        try await recipes.save(naan)
        let curry = Recipe(
            title: "Curry",
            servings: 2,
            ingredientsText: "400 ml Kokosmilch\n2 Portionen \(RecipeLink.markdown(title: "Naan", id: naan.id))"
        )

        await shopping.add(curry)
        // One plan entry — the naan's demands hang on the curry.
        #expect(shopping.planEntries.map(\.title) == ["Curry"])

        await shopping.setServings(4, for: try #require(shopping.planEntries.first))
        let flour = try #require(shopping.items.first { $0.name == "Mehl" })
        #expect(flour.quantities == [Quantity(500, .gram)])
        // It still reads as coming from the naan.
        #expect(flour.originTitles == ["Naan"])
    }

    @Test("Removing a plan entry drops open demand and annotates checked demand", arguments: StoreBackend.allCases)
    func removingAPlanEntry(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        await shopping.add(Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten\n2 Zwiebeln"))
        let tomatoes = try #require(shopping.items.first { $0.name == "Tomate" })
        await shopping.toggle(tomatoes)

        await shopping.remove(planEntry: try #require(shopping.planEntries.first))

        // The open onions are gone with their recipe; the bought tomatoes
        // stay, struck through as lapsed.
        #expect(shopping.planEntries.isEmpty)
        #expect(shopping.items.map(\.name) == ["Tomate"])
        #expect(shopping.items[0].isChecked)
        #expect(shopping.items[0].quantities.isEmpty)
        #expect(shopping.items[0].lapsedQuantities == [Quantity(300, .gram)])
    }
}

// MARK: - Views of the document

extension ShoppingLibraryTests {
    @Test("Grouping by recipe shows each dish's own share, with its dial", arguments: StoreBackend.allCases)
    func groupedByRecipe(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        await shopping.add(Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten"))
        await shopping.add(Recipe(title: "Sauce", servings: 2, ingredientsText: "200 g Tomaten\n1 Zwiebel"))
        await shopping.addItem("Kaffee")

        // One line when shopping…
        #expect(shopping.items.map(\.name) == ["Tomate", "Zwiebel", "Kaffee"])
        #expect(shopping.items[0].quantities == [Quantity(500, .gram)])

        // …and split by dish when checking, each with its plan entry.
        let groups = shopping.byRecipe
        #expect(groups.map(\.title) == ["Salat", "Sauce", ShoppingLibrary.ungroupedTitle])
        #expect(groups[0].planEntry != nil)
        #expect(groups[0].items[0].quantities == [Quantity(300, .gram)])
        #expect(groups[1].items[0].quantities == [Quantity(200, .gram)])
        #expect(groups[1].items.map(\.name) == ["Tomate", "Zwiebel"])
        #expect(groups[2].planEntry == nil)
        #expect(groups[2].items.map(\.name) == ["Kaffee"])
    }

    @Test("Topping up a line by hand shows up in both readings", arguments: StoreBackend.allCases)
    func manualTopUpIsAccountedFor(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        await shopping.add(Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten"))
        await shopping.addItem("700 g Tomaten")

        // One line, and the total counts both.
        #expect(shopping.items.count == 1)
        #expect(shopping.items[0].quantities == [Quantity(1000, .gram)])

        // Grouped by dish, the recipe's share and the rest are both visible,
        // and together they add back up to the total.
        let groups = shopping.byRecipe
        #expect(groups.map(\.title) == ["Salat", ShoppingLibrary.ungroupedTitle])
        #expect(groups[0].items[0].quantities == [Quantity(300, .gram)])
        #expect(groups[1].items[0].quantities == [Quantity(700, .gram)])
    }

    @Test("Different spellings become one line", arguments: StoreBackend.allCases)
    func spellingsMerge(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        await shopping.add(Recipe(title: "A", servings: 2, ingredientsText: "300 g Tomaten"))
        await shopping.add(Recipe(title: "B", servings: 2, ingredientsText: "2 Tomate"))
        await shopping.addItem("500 g Tomate")

        #expect(shopping.items.count == 1)
        #expect(shopping.items[0].name == "Tomate")
        #expect(shopping.items[0].quantities == [Quantity(800, .gram), Quantity(2, .piece)])
    }

    @Test("A variety keeps its own line, in the parent's place on the list", arguments: StoreBackend.allCases)
    func varietiesGroupWithoutMerging(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        await shopping.add(Recipe(title: "Bauernsalat", servings: 2, ingredientsText: "500 g Tomaten"))
        await shopping.add(Recipe(title: "Pastasalat", servings: 2, ingredientsText: "200 g Cocktailtomaten"))

        // Two items, because two different things are being bought.
        #expect(shopping.items.map(\.name) == ["Tomate", "Cocktailtomate"])

        // One place on the list, with the total on the heading and the
        // distinction intact underneath — the concept's grouped entry.
        let groups = shopping.grouped(shopping.items)
        #expect(groups.count == 1)
        let tomatoes = try #require(groups.first)
        #expect(tomatoes.name == "Tomate")
        #expect(tomatoes.isGrouped)
        #expect(tomatoes.quantities == [Quantity(700, .gram)])
        #expect(tomatoes.items.map(\.name) == ["Tomate", "Cocktailtomate"])
    }

    @Test("A sub-line keeps the word the recipe wrote", arguments: StoreBackend.allCases)
    func varietySublinesKeepTheWrittenName(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        await shopping.add(Recipe(title: "Pastasalat", servings: 2, ingredientsText: "200 g Cocktailtomaten"))

        // Capture files the item under the catalog's spelling, which is right
        // for a heading and would destroy the sub-line. The demand keeps what
        // was written — the only moment it could have been lost in.
        let item = try #require(shopping.items.first)
        #expect(item.name == "Cocktailtomate")
        #expect(item.writtenNames == ["Cocktailtomaten"])
    }

    @Test("An ordinary ingredient is a group of one, and renders as it always did", arguments: StoreBackend.allCases)
    func plainItemsAreNotGrouped(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        await shopping.add(Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten"))

        let groups = shopping.grouped(shopping.items)
        #expect(groups.count == 1)
        #expect(groups.first?.isGrouped == false)
    }

    @Test("A named store pulls its errands out of the aisle walk")
    func preferredStoreSection() async throws {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let catalog = IngredientCatalogLibrary(
            store: SwiftDataVocabularyStore(modelContainer: container)
        )
        let shopping = ShoppingLibrary(
            store: SwiftDataShoppingListStore(modelContainer: container),
            recipeStore: SwiftDataRecipeStore(modelContainer: container),
            catalogLibrary: catalog
        )
        await shopping.add(Recipe(
            title: "Bowl",
            servings: 2,
            ingredientsText: """
            250 g Cocktailtomaten
            200 g Feta
            2 Dürüm
            """
        ))

        await catalog.setShoppingPreferences(store: "Lidl", note: "die große Packung", name: "Dürüm")
        // Set on the parent, reaching the variety on the list.
        await catalog.setShoppingPreferences(store: "Lidl", note: nil, name: "Tomate")

        let sections = shopping.bySection
        #expect(sections.map(\.section) == [.store("Lidl"), .aisle(.dairy)])
        // Inside the shop the aisle walk applies: the uncategorized Dürüm
        // surfaces first, then the tomatoes from the vegetable aisle.
        #expect(sections[0].items.map(\.name) == ["Dürüm", "Cocktailtomate"])

        let dürüm = try #require(shopping.items.first { $0.name == "Dürüm" })
        #expect(shopping.preferredStore(of: dürüm) == "Lidl")
        #expect(shopping.shoppingNote(of: dürüm) == "die große Packung")

        // Taking the store back returns everything to its aisle.
        await catalog.setShoppingPreferences(store: nil, note: nil, name: "Dürüm")
        await catalog.setShoppingPreferences(store: "", note: nil, name: "Tomate")
        #expect(shopping.bySection.map(\.section) == [.unassigned, .aisle(.vegetables), .aisle(.dairy)])
    }

    @Test("The walk starts with the unassigned, then the aisles, then the pantry", arguments: StoreBackend.allCases)
    func groupedBySection(_ backend: StoreBackend) async throws {
        let (shopping, _, _) = try makeLibrary(backend)
        await shopping.add(Recipe(
            title: "Menü",
            servings: 2,
            ingredientsText: """
            1 TL Kreuzkümmel
            300 g Tomaten
            200 g Feta
            2 Zitronen
            """
        ))
        // A line the app cannot interpret surfaces before the store.
        await shopping.addItem("Xylophonwachs")

        var sections = shopping.bySection
        #expect(sections.map(\.section) == [
            .unassigned, .aisle(.vegetables), .aisle(.fruit), .aisle(.dairy), .aisle(.spices),
        ])
        #expect(sections[0].items.map(\.name) == ["Xylophonwachs"])

        // The pantry flag moves an ingredient out of its aisle, to the end.
        let cumin = try #require(shopping.items.first { $0.name == "Kreuzkümmel" })
        await shopping.setPantry(true, name: cumin.name)
        sections = shopping.bySection
        #expect(sections.map(\.section) == [
            .unassigned, .aisle(.vegetables), .aisle(.fruit), .aisle(.dairy), .pantry,
        ])
        #expect(sections.last?.items.map(\.name) == ["Kreuzkümmel"])
    }
}

// MARK: - Migration

extension ShoppingLibraryTests {
    @Test("Migrated sources keep the order they were written in")
    func migrationKeepsSourceOrder() async throws {
        let (shopping, container) = try makeLegacyLibrary()

        // Six sources, migrated in one pass. They are all stamped within the
        // same millisecond, so ordering them by time alone leaves the fetch
        // to decide — which it did, differently from run to run, and with two
        // sources a coin flip still passed half the time. Six make the
        // difference between "ordered" and "happened to come back right"
        // impossible to miss.
        let order = ["Salat", "Sauce", "Suppe", "Auflauf", "Eintopf", "Brot"]
        let context = ModelContext(container)
        let entry = StoredShoppingEntry(key: "tomate", name: "Tomate", category: .vegetables)
        entry.itemID = nil
        entry.sortOrder = 0
        entry.sourceData = try SousCoding.encoder.encode(
            order.map { ShoppingSource(recipeTitle: $0, quantities: [Quantity(100, .gram)]) }
        )
        context.insert(entry)
        try context.save()

        await shopping.reload()

        #expect(shopping.items.count == 1)
        #expect(shopping.items[0].originTitles == order)
        #expect(shopping.byRecipe.map(\.title) == order)

        // And a second read of the same store gives the same answer — the
        // order is written down, not re-guessed.
        await shopping.reload()
        #expect(shopping.items[0].originTitles == order)
    }

    @Test("Pre-document rows carry over: checked stays checked, sources become frozen demand")
    func migrationRoundtrip() async throws {
        let (shopping, container) = try makeLegacyLibrary()

        // A store as the pre-document schema wrote it: title-keyed sources
        // in a blob, no item id, one row checked off.
        let context = ModelContext(container)
        let bought = StoredShoppingEntry(key: "tomate", name: "Tomate", category: .vegetables)
        bought.itemID = nil
        bought.isChecked = true
        bought.sortOrder = 0
        bought.sourceData = try SousCoding.encoder.encode([
            ShoppingSource(recipeTitle: "Salat", quantities: [Quantity(300, .gram)]),
            ShoppingSource(recipeTitle: "Sauce", quantities: [Quantity(200, .gram)]),
        ])
        context.insert(bought)
        let open = StoredShoppingEntry(key: "salz", name: "Salz", category: .spices)
        open.itemID = nil
        open.sortOrder = 1
        open.sourceData = try SousCoding.encoder.encode([ShoppingSource(recipeTitle: "Salat")])
        context.insert(open)
        try context.save()

        await shopping.reload()

        // Checked stays checked, amounts and origins survive.
        #expect(shopping.items.map(\.name) == ["Tomate", "Salz"])
        let tomatoes = shopping.items[0]
        #expect(tomatoes.isChecked)
        #expect(tomatoes.quantities == [Quantity(500, .gram)])
        #expect(tomatoes.originTitles == ["Salat", "Sauce"])
        // Frozen: no plan entry, so nothing offers to re-scale them.
        #expect(shopping.planEntries.isEmpty)
        #expect(tomatoes.demands.allSatisfy { $0.planEntryID == nil && !$0.scales })

        // The by-recipe view still reads them, without a dial.
        let groups = shopping.byRecipe
        #expect(groups.map(\.title) == ["Salat", "Sauce"])
        #expect(groups.allSatisfy { $0.planEntry == nil })

        // A second read migrates nothing twice.
        await shopping.reload()
        #expect(shopping.items[0].quantities == [Quantity(500, .gram)])
    }
}
