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
            ingredients: [
                RecipeIngredient(name: "Zucchini", quantity: Quantity(300, .gram), group: "Pfanne"),
                RecipeIngredient(name: "Feta", quantity: Quantity(100, .gram)),
                RecipeIngredient(name: "Salz"),
            ],
            steps: [
                RecipeStep(text: "Zucchini schneiden"),
                RecipeStep(text: "Anbraten", durationSeconds: 480),
            ],
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
        #expect(loaded.ingredients.map(\.name) == ["Zucchini", "Feta", "Salz"])
        #expect(loaded.ingredients[0].quantity == Quantity(300, .gram))
        #expect(loaded.ingredients[0].group == "Pfanne")
        #expect(loaded.ingredients[2].quantity == nil)
        #expect(loaded.steps.map(\.text) == ["Zucchini schneiden", "Anbraten"])
        #expect(loaded.steps[1].durationSeconds == 480)
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

    @Test("Saving twice updates in place and leaves no orphaned rows")
    func saveIsIdempotentOnIdentity() async throws {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let store = SwiftDataRecipeStore(modelContainer: container)

        var recipe = sampleRecipe()
        try await store.save(recipe)

        recipe.title = "Zucchinipfanne mit Feta"
        recipe.ingredients = [RecipeIngredient(name: "Zucchini", quantity: Quantity(400, .gram))]
        try await store.save(recipe)

        let all = try await store.recipes(matching: .all)
        #expect(all.count == 1)
        #expect(all[0].title == "Zucchinipfanne mit Feta")
        #expect(all[0].ingredients.count == 1)

        let context = ModelContext(container)
        // Three ingredients became one and the two steps were replaced in
        // place — anything more would be rows the update left behind.
        let storedIngredients = try context.fetchCount(FetchDescriptor<StoredIngredient>())
        let storedSteps = try context.fetchCount(FetchDescriptor<StoredStep>())
        #expect(storedIngredients == 1)
        #expect(storedSteps == 2)
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
                ingredients: [RecipeIngredient(name: "Rote Linsen")],
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
        #expect(try await store.recipes(matching: RecipeQuery(category: "Backen")).map(\.title) == ["Geplant"])
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
