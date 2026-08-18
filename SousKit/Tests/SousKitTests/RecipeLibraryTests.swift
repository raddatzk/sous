import Foundation
import SwiftData
import Testing
@testable import SousKit

@MainActor
@Suite("Recipe library")
struct RecipeLibraryTests {
    private func makeLibrary() throws -> (RecipeLibrary, SwiftDataRecipeStore) {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let store = SwiftDataRecipeStore(modelContainer: container)
        let images = SwiftDataRecipeImageStore(modelContainer: container)
        return (RecipeLibrary(store: store, imageStore: images), store)
    }

    @Test("The query mirrors the selected filters")
    func queryReflectsFilters() async throws {
        let (library, _) = try makeLibrary()

        #expect(library.query.searchText == nil)
        #expect(!library.query.onlyFavorites)

        library.searchText = "Linsen"
        library.filter = .favorites
        await library.apply(.category("Suppe"))

        // Applying a filter clears the field it came from.
        #expect(library.query.searchText == nil)
        #expect(library.query.onlyFavorites)
        #expect(library.query.filters.map(\.title) == ["Suppe"])

        library.filter = .wantToCook
        #expect(!library.query.onlyFavorites)
        #expect(library.query.onlyWantToCook)
    }

    @Test("Saving a recipe puts it into the list and its categories")
    func saveAppears() async throws {
        let (library, _) = try makeLibrary()
        await library.reload()
        #expect(library.recipes.isEmpty)

        await library.save(Recipe(title: "Linsensuppe", categories: ["Suppe"]))

        #expect(library.recipes.map(\.title) == ["Linsensuppe"])
        #expect(library.categories == ["Suppe"])
        #expect(library.errorMessage == nil)
    }

    @Test("Deleting removes it from the list")
    func deleteRemoves() async throws {
        let (library, _) = try makeLibrary()
        let recipe = Recipe(title: "Brot")
        await library.save(recipe)

        await library.delete(recipe)
        #expect(library.recipes.isEmpty)
    }

    @Test("Cooking a recipe through consumes its want-to-cook mark")
    func cookingClearsWantToCook() async throws {
        let (library, _) = try makeLibrary()
        await library.save(Recipe(title: "Linsensuppe", isFavorite: true, wantToCook: true))
        let recipe = try #require(library.recipes.first)

        await library.markCooked(recipe)

        let cooked = try #require(library.recipes.first)
        #expect(!cooked.wantToCook)
        // Only the wish is spent; being a favorite is not about one evening.
        #expect(cooked.isFavorite)
    }

    @Test("Cooking something that was never marked changes nothing")
    func cookingUnmarkedRecipe() async throws {
        let (library, _) = try makeLibrary()
        await library.save(Recipe(title: "Rührei"))
        let recipe = try #require(library.recipes.first)
        let before = recipe.updatedAt

        await library.markCooked(recipe)

        #expect(library.recipes.first?.updatedAt == before)
    }

    @Test("Toggling favorite and want-to-cook persists")
    func toggles() async throws {
        let (library, store) = try makeLibrary()
        let recipe = Recipe(title: "Brot")
        await library.save(recipe)

        await library.toggleFavorite(try #require(library.recipes.first))
        #expect(try await store.recipe(id: recipe.id)?.isFavorite == true)

        await library.toggleWantToCook(try #require(library.recipes.first))
        #expect(try await store.recipe(id: recipe.id)?.wantToCook == true)

        library.filter = .favorites
        await library.reload()
        #expect(library.recipes.count == 1)
    }

    @Test("Starting a new recipe opens an empty draft")
    func newRecipeDraft() throws {
        let (library, _) = try makeLibrary()
        #expect(library.editing == nil)

        library.startNewRecipe()
        #expect(library.editing?.title == "")
    }

    @Test("Typing in the search field reloads once, after a pause")
    func searchIsDebounced() async throws {
        let (library, _) = try makeLibrary()
        await library.save(Recipe(title: "Linsensuppe"))
        await library.save(Recipe(title: "Zucchinipfanne"))

        library.searchText = "L"
        library.searchText = "Li"
        library.searchText = "Linsen"
        // Still the unfiltered result: nothing has been reloaded yet.
        #expect(library.recipes.count == 2)

        try await Task.sleep(for: .milliseconds(400))
        #expect(library.recipes.map(\.title) == ["Linsensuppe"])
    }
}
