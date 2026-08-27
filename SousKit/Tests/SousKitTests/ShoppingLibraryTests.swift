import Foundation
import SwiftData
import Testing
@testable import SousKit

@MainActor
@Suite("Shopping library")
struct ShoppingLibraryTests {
    private func makeLibrary() throws -> (ShoppingLibrary, SwiftDataRecipeStore, ModelContainer) {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let recipes = SwiftDataRecipeStore(modelContainer: container)
        let shopping = ShoppingLibrary(
            store: SwiftDataShoppingListStore(modelContainer: container),
            recipeStore: recipes,
            // The pantry flag lives on the vocabulary entry now, so the
            // catalog library is what the list asks about it.
            catalogLibrary: IngredientCatalogLibrary(
                store: SwiftDataVocabularyStore(modelContainer: container)
            )
        )
        return (shopping, recipes, container)
    }

    @Test("A recipe's ingredients are put on the list on request")
    func addingARecipe() async throws {
        let (shopping, _, _) = try makeLibrary()
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten\nSalz")

        await shopping.add(recipe)
        // Written "300 g Tomaten", listed under the catalog's name.
        #expect(shopping.items.map(\.name) == ["Tomate", "Salz"])
        #expect(shopping.items[0].quantities == [Quantity(300, .gram)])
        #expect(shopping.items[0].originTitles == ["Salat"])
        #expect(shopping.planEntries.map(\.title) == ["Salat"])
    }

    @Test("A stated state survives the store and annotates the line")
    func statesRoundTripThroughTheStore() async throws {
        // `ShoppingDemand.state` has had a column since the document model
        // landed and has been `.unspecified` in every row ever written — so
        // nothing had ever proven the column carries anything.
        let (shopping, _, container) = try makeLibrary()
        let recipe = Recipe(
            title: "Auflauf", servings: 2,
            ingredientsText: "500 g Kartoffeln\n300 g Kartoffeln, gegart"
        )
        await shopping.add(recipe)

        // Read back through a second library on the same store: a value that
        // only survives in memory has not been stored.
        let reread = ShoppingLibrary(
            store: SwiftDataShoppingListStore(modelContainer: container),
            recipeStore: SwiftDataRecipeStore(modelContainer: container),
            catalogLibrary: IngredientCatalogLibrary(
                store: SwiftDataVocabularyStore(modelContainer: container)
            )
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

    @Test("Adding for more people scales what has to be bought")
    func addingScaled() async throws {
        let (shopping, _, _) = try makeLibrary()
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten")

        await shopping.add(recipe, servings: 6)
        #expect(shopping.items[0].quantities == [Quantity(900, .gram)])
        #expect(shopping.planEntries[0].servingsCaptured == 6)
    }

    @Test("Adding a second recipe bundles into the line already there")
    func addingTwice() async throws {
        let (shopping, _, _) = try makeLibrary()
        await shopping.add(Recipe(title: "A", servings: 2, ingredientsText: "300 g Tomaten"))
        await shopping.add(Recipe(title: "B", servings: 2, ingredientsText: "200 g Tomaten"))

        #expect(shopping.items.count == 1)
        #expect(shopping.items[0].quantities == [Quantity(500, .gram)])
        #expect(shopping.items[0].originTitles == ["A", "B"])
        // Bundled for display, but stored as two demands with their origins.
        #expect(shopping.items[0].demands.count == 2)
    }

    @Test("The list stays put when a recipe changes afterwards")
    func listDoesNotFollowRecipes() async throws {
        let (shopping, recipes, _) = try makeLibrary()
        var recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten")
        try await recipes.save(recipe)
        await shopping.add(recipe)

        recipe.ingredientsText = "Nichts mehr"
        try await recipes.save(recipe)
        await shopping.reload()

        #expect(shopping.items.map(\.name) == ["Tomate"])
    }

    @Test("A linked recipe contributes its ingredients, not its name")
    func linkedRecipes() async throws {
        let (shopping, recipes, _) = try makeLibrary()
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
        let (shopping, _, _) = try makeLibrary()
        await shopping.add(Recipe(title: "A", servings: 2, ingredientsText: "300 g Tomaten\nSalz"))

        await shopping.toggle(try #require(shopping.items.first))
        #expect(shopping.checkedItems.map(\.name) == ["Tomate"])

        // Sweeping hides the bought line; nothing is deleted, so the
        // document keeps its memory.
        await shopping.clearChecked()
        #expect(shopping.items.map(\.name) == ["Salz"])
    }

    @Test("A line typed by hand is parsed like an ingredient")
    func manualItems() async throws {
        let (shopping, _, _) = try makeLibrary()

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
    @Test("Re-adding a recipe never un-checks — new demand appends late instead")
    func reAddingNeverUnchecks() async throws {
        let (shopping, _, _) = try makeLibrary()
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

    @Test("New demand under a checked ingredient lands on a fresh open item")
    func newDemandUnderCheckedItem() async throws {
        let (shopping, _, _) = try makeLibrary()
        await shopping.add(Recipe(title: "A", servings: 2, ingredientsText: "300 g Tomaten"))
        await shopping.toggle(try #require(shopping.items.first))

        await shopping.add(Recipe(title: "B", servings: 2, ingredientsText: "200 g Tomaten"))

        #expect(shopping.checkedItems.count == 1)
        #expect(shopping.checkedItems[0].quantities == [Quantity(300, .gram)])
        let late = try #require(shopping.openItems.first)
        #expect(late.quantities == [Quantity(200, .gram)])
        #expect(late.isLateAddition)
    }

    @Test("After sweeping, the next add starts a fresh line, not a late one")
    func addingAfterClearingStartsFresh() async throws {
        let (shopping, _, _) = try makeLibrary()
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

// MARK: - Re-scaling on the list

extension ShoppingLibraryTests {
    @Test("Scaling an open item adjusts it in place")
    func rescalingOpenItems() async throws {
        let (shopping, _, _) = try makeLibrary()
        await shopping.add(Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten"))

        await shopping.setServings(4, for: try #require(shopping.planEntries.first))
        #expect(shopping.items.count == 1)
        #expect(shopping.items[0].quantities == [Quantity(600, .gram)])

        // And back down again, still in place.
        await shopping.setServings(1, for: try #require(shopping.planEntries.first))
        #expect(shopping.items.count == 1)
        #expect(shopping.items[0].quantities == [Quantity(150, .gram)])
    }

    @Test("Scaling up past a checked item appends the difference as open late demand")
    func rescalingUpPastChecked() async throws {
        let (shopping, _, _) = try makeLibrary()
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

    @Test("Scaling down past a checked item annotates the lapse, not the check")
    func rescalingDownPastChecked() async throws {
        let (shopping, _, _) = try makeLibrary()
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

    @Test("Un-checking hands the item back to the stepper and absorbs the difference row")
    func uncheckingAbsorbsDifference() async throws {
        let (shopping, _, _) = try makeLibrary()
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

    @Test("Unquantified demands do not scale")
    func unquantifiedDoesNotScale() async throws {
        let (shopping, _, _) = try makeLibrary()
        await shopping.add(Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten\nSalz"))

        await shopping.setServings(4, for: try #require(shopping.planEntries.first))
        let salt = try #require(shopping.items.first { $0.name == "Salz" })
        #expect(salt.quantities.isEmpty)
        #expect(shopping.items.count == 2)
    }

    @Test("Subrecipe demands scale with the parent's plan entry")
    func subrecipesScaleWithParent() async throws {
        let (shopping, recipes, _) = try makeLibrary()
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

    @Test("Removing a plan entry drops open demand and annotates checked demand")
    func removingAPlanEntry() async throws {
        let (shopping, _, _) = try makeLibrary()
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
    @Test("Grouping by recipe shows each dish's own share, with its dial")
    func groupedByRecipe() async throws {
        let (shopping, _, _) = try makeLibrary()
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

    @Test("Topping up a line by hand shows up in both readings")
    func manualTopUpIsAccountedFor() async throws {
        let (shopping, _, _) = try makeLibrary()
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

    @Test("Different spellings become one line")
    func spellingsMerge() async throws {
        let (shopping, _, _) = try makeLibrary()
        await shopping.add(Recipe(title: "A", servings: 2, ingredientsText: "300 g Tomaten"))
        await shopping.add(Recipe(title: "B", servings: 2, ingredientsText: "2 Tomate"))
        await shopping.addItem("500 g Tomate")

        #expect(shopping.items.count == 1)
        #expect(shopping.items[0].name == "Tomate")
        #expect(shopping.items[0].quantities == [Quantity(800, .gram), Quantity(2, .piece)])
    }

    @Test("A variety keeps its own line, in the parent's place on the list")
    func varietiesGroupWithoutMerging() async throws {
        let (shopping, _, _) = try makeLibrary()
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

    @Test("A sub-line keeps the word the recipe wrote")
    func varietySublinesKeepTheWrittenName() async throws {
        let (shopping, _, _) = try makeLibrary()
        await shopping.add(Recipe(title: "Pastasalat", servings: 2, ingredientsText: "200 g Cocktailtomaten"))

        // Capture files the item under the catalog's spelling, which is right
        // for a heading and would destroy the sub-line. The demand keeps what
        // was written — the only moment it could have been lost in.
        let item = try #require(shopping.items.first)
        #expect(item.name == "Cocktailtomate")
        #expect(item.writtenNames == ["Cocktailtomaten"])
    }

    @Test("An ordinary ingredient is a group of one, and renders as it always did")
    func plainItemsAreNotGrouped() async throws {
        let (shopping, _, _) = try makeLibrary()
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

    @Test("The walk starts with the unassigned, then the aisles, then the pantry")
    func groupedBySection() async throws {
        let (shopping, _, _) = try makeLibrary()
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
        let (shopping, _, container) = try makeLibrary()

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
        let (shopping, _, container) = try makeLibrary()

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
