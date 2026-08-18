import Foundation
import SwiftData
import Testing
@testable import SousKit

@Suite("Recipe store")
struct RecipeStoreTests {
    private func makeStore() throws -> SwiftDataRecipeStore {
        SwiftDataRecipeStore(modelContainer: try .sousContainer(inMemory: true))
    }

    private func sampleRecipe(title: String = "Zucchinipfanne") -> Recipe {
        Recipe(
            title: title,
            servings: 2,
            ingredientsText: """
            Pfanne:
            300 g Zucchini
            100 g Feta
            Salz
            """,
            instructionsText: """
            Zucchini schneiden
            Anbraten
            """,
            categories: ["Schnell", "Vegetarisch"]
        )
    }

    @Test("A saved recipe comes back with its content and order intact")
    func roundTrip() async throws {
        let store = try makeStore()
        let recipe = sampleRecipe()
        try await store.save(recipe)

        let loaded = try #require(try await store.recipe(id: recipe.id))
        #expect(loaded.title == recipe.title)
        #expect(loaded.ingredientsText == recipe.ingredientsText)
        #expect(loaded.instructionsText == recipe.instructionsText)
        #expect(loaded.ingredients.map(\.name) == ["Zucchini", "Feta", "Salz"])
        #expect(loaded.ingredients[0].quantity == Quantity(300, .gram))
        #expect(loaded.ingredients[0].group == "Pfanne")
        #expect(loaded.steps.map(\.text) == ["Zucchini schneiden", "Anbraten"])
        #expect(loaded.categories == ["Schnell", "Vegetarisch"])
    }

    @Test("The store stamps updatedAt, not the caller")
    func storeStampsUpdatedAt() async throws {
        let store = try makeStore()
        var recipe = sampleRecipe()
        recipe.updatedAt = Date(timeIntervalSince1970: 0)

        let saved = try await store.save(recipe)
        #expect(saved.updatedAt > Date(timeIntervalSince1970: 0))

        let loaded = try #require(try await store.recipe(id: recipe.id))
        #expect(loaded.updatedAt == saved.updatedAt)
    }

    @Test("Saving twice updates in place instead of inserting again")
    func saveIsIdempotentOnIdentity() async throws {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let store = SwiftDataRecipeStore(modelContainer: container)

        var recipe = sampleRecipe()
        try await store.save(recipe)

        recipe.title = "Zucchinipfanne mit Feta"
        recipe.ingredientsText = "400 g Zucchini"
        try await store.save(recipe)

        let all = try await store.recipes(matching: .all)
        #expect(all.count == 1)
        #expect(all[0].title == "Zucchinipfanne mit Feta")
        #expect(all[0].ingredients.count == 1)

        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<StoredRecipe>()) == 1)
    }

    @Test("Deleting tombstones instead of erasing, and restoring brings it back")
    func deleteAndRestore() async throws {
        let store = try makeStore()
        let recipe = sampleRecipe()
        try await store.save(recipe)

        try await store.delete(id: recipe.id)
        #expect(try await store.recipes(matching: .all).isEmpty)

        let withDeleted = try await store.recipes(matching: RecipeQuery(includeDeleted: true))
        let tombstoned = try #require(withDeleted.first)
        #expect(withDeleted.count == 1)
        #expect(tombstoned.isDeleted)
        #expect(tombstoned.ingredients.count == 3)
        #expect(tombstoned.ingredientsText == recipe.ingredientsText)

        try await store.restore(id: recipe.id)
        #expect(try await store.recipes(matching: .all).count == 1)
    }

    @Test("Search matches title, category and ingredient name")
    func search() async throws {
        let store = try makeStore()
        try await store.save(sampleRecipe())
        try await store.save(
            Recipe(
                title: "Linsensuppe",
                ingredientsText: "200 g Rote Linsen",
                categories: ["Suppe"]
            )
        )

        #expect(try await store.recipes(matching: RecipeQuery(searchText: "linsen")).count == 1)
        #expect(try await store.recipes(matching: RecipeQuery(searchText: "Feta")).count == 1)
        #expect(try await store.recipes(matching: RecipeQuery(searchText: "Suppe")).count == 1)
        #expect(try await store.recipes(matching: RecipeQuery(searchText: "Pilze")).isEmpty)
        #expect(try await store.recipes(matching: RecipeQuery(searchText: "  ")).count == 2)
    }

    @Test("Filters for favorites, want-to-cook and category")
    func filters() async throws {
        let store = try makeStore()
        var favorite = sampleRecipe(title: "Favorit")
        favorite.isFavorite = true
        var planned = sampleRecipe(title: "Geplant")
        planned.wantToCook = true
        planned.categories = ["Backen"]

        try await store.save(favorite)
        try await store.save(planned)

        #expect(try await store.recipes(matching: RecipeQuery(onlyFavorites: true)).map(\.title) == ["Favorit"])
        #expect(try await store.recipes(matching: RecipeQuery(onlyWantToCook: true)).map(\.title) == ["Geplant"])
        #expect(try await store.recipes(matching: RecipeQuery(filters: [.category("Backen")])).map(\.title) == ["Geplant"])
    }

    @Test("Sorting by title and by recency")
    func sorting() async throws {
        let store = try makeStore()
        try await store.save(sampleRecipe(title: "Älpler Magronen"))
        try await store.save(sampleRecipe(title: "Brot"))
        try await store.save(sampleRecipe(title: "Auflauf"))

        let byTitle = try await store.recipes(matching: RecipeQuery(sort: .titleAscending))
        #expect(byTitle.map(\.title) == ["Älpler Magronen", "Auflauf", "Brot"])

        let byRecency = try await store.recipes(matching: RecipeQuery(sort: .recentlyUpdated))
        #expect(byRecency.first?.title == "Auflauf")
    }

    @Test("Categories are deduplicated and exclude deleted recipes")
    func categoryList() async throws {
        let store = try makeStore()
        let first = sampleRecipe(title: "A")
        var second = sampleRecipe(title: "B")
        second.categories = ["Vegetarisch", "Backen"]

        try await store.save(first)
        try await store.save(second)
        #expect(try await store.categories() == ["Backen", "Schnell", "Vegetarisch"])

        try await store.delete(id: second.id)
        #expect(try await store.categories() == ["Schnell", "Vegetarisch"])
    }
}


@Suite("Recognized search filters")
struct RecipeFilterTests {
    private func makeStore() throws -> SwiftDataRecipeStore {
        SwiftDataRecipeStore(modelContainer: try .sousContainer(inMemory: true))
    }

    @Test("Filtering by ingredient finds every spelling of it")
    func ingredientFilterMatchesSpellings() async throws {
        let store = try makeStore()
        try await store.save(Recipe(title: "Salat", ingredientsText: "300 g Cocktailtomaten"))
        try await store.save(Recipe(title: "Sauce", ingredientsText: "2 Tomate"))
        try await store.save(Recipe(title: "Brot", ingredientsText: "500 g Mehl"))

        let tomato = try #require(IngredientCatalog.bundled.ingredient(for: "Tomate"))
        let found = try await store.recipes(matching: RecipeQuery(filters: [.ingredient(tomato)]))

        #expect(found.map(\.title) == ["Salat", "Sauce"])
    }

    @Test("Several filters narrow rather than widen")
    func filtersCombine() async throws {
        let store = try makeStore()
        try await store.save(Recipe(
            title: "Beides", ingredientsText: "2 Tomaten\n1 Zwiebel", categories: ["Schnell"]
        ))
        try await store.save(Recipe(title: "Nur Tomate", ingredientsText: "2 Tomaten"))

        let tomato = try #require(IngredientCatalog.bundled.ingredient(for: "Tomate"))
        let onion = try #require(IngredientCatalog.bundled.ingredient(for: "Zwiebel"))

        let both = try await store.recipes(matching: RecipeQuery(
            filters: [.ingredient(tomato), .ingredient(onion)]
        ))
        #expect(both.map(\.title) == ["Beides"])

        let withCategory = try await store.recipes(matching: RecipeQuery(
            filters: [.ingredient(tomato), .category("Schnell")]
        ))
        #expect(withCategory.map(\.title) == ["Beides"])
    }

    @Test("Typed text is offered as the filters it could be")
    func suggestions() throws {
        let suggestions = RecipeFilter.suggestions(
            for: "toma",
            catalog: .bundled,
            categories: ["Tomatig", "Schnell"]
        )

        #expect(suggestions.contains { $0.kind == .ingredient && $0.title == "Tomate" })
        #expect(suggestions.contains { $0.kind == .category && $0.title == "Tomatig" })
    }

    @Test("Categories are ranked beside ingredients, not behind them")
    func categoriesAreNotPushedOut() throws {
        let suggestions = RecipeFilter.suggestions(
            for: "sal",
            catalog: .bundled,
            categories: ["Salate"]
        )

        // "Salat", "Salami", "Salbei" and "Salz" all start with it too, so
        // appending categories afterwards would drop "Salate" off the end.
        #expect(suggestions.contains { $0.kind == .category && $0.title == "Salate" })
        #expect(try #require(suggestions.first).title == "Salz")
    }

    @Test("A match through an alias says which spelling matched")
    func aliasMatchesAreExplained() throws {
        let suggestions = RecipeFilter.suggestions(
            for: "salatgur",
            catalog: .bundled,
            categories: []
        )

        let cucumber = try #require(suggestions.first { $0.title == "Gurke" })
        #expect(cucumber.matchedAs == "Salatgurke")
    }

    @Test("A match on the name itself needs no explanation")
    func directMatchesHaveNoSubtitle() throws {
        let suggestions = RecipeFilter.suggestions(
            for: "gurk",
            catalog: .bundled,
            categories: []
        )

        #expect(try #require(suggestions.first { $0.title == "Gurke" }).matchedAs == nil)
    }

    @Test("A filter already applied is not offered again")
    func appliedFiltersAreSkipped() throws {
        let tomato = try #require(IngredientCatalog.bundled.ingredient(for: "Tomate"))
        let suggestions = RecipeFilter.suggestions(
            for: "tomate",
            catalog: .bundled,
            categories: [],
            applied: [.ingredient(tomato)]
        )

        #expect(!suggestions.contains { $0.title == "Tomate" })
    }
}
