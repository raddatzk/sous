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
        let enrichment = SwiftDataRecipeEnrichmentStore(modelContainer: container)
        return (RecipeLibrary(store: store, imageStore: images, enrichmentStore: enrichment), store)
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

@MainActor
@Suite("The trash")
struct RecipeTrashTests {
    private func makeLibrary() throws -> (RecipeLibrary, SwiftDataRecipeImageStore) {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let images = SwiftDataRecipeImageStore(modelContainer: container)
        return (
            RecipeLibrary(
                store: SwiftDataRecipeStore(modelContainer: container),
                imageStore: images,
                enrichmentStore: SwiftDataRecipeEnrichmentStore(modelContainer: container)
            ),
            images
        )
    }

    @Test("A deleted recipe leaves the list but waits in the trash")
    func deletedGoesToTrash() async throws {
        let (library, _) = try makeLibrary()
        await library.save(Recipe(title: "Linsensuppe"))
        let recipe = try #require(library.recipes.first)

        await library.delete(recipe)

        #expect(library.recipes.isEmpty)
        #expect(await library.deletedRecipes().map(\.title) == ["Linsensuppe"])
    }

    @Test("Restoring puts it back the way it was")
    func restore() async throws {
        let (library, _) = try makeLibrary()
        await library.save(Recipe(title: "Linsensuppe", categories: ["Suppe"], isFavorite: true))
        let recipe = try #require(library.recipes.first)
        await library.delete(recipe)

        await library.restore(recipe)

        let back = try #require(library.recipes.first)
        #expect(back.title == "Linsensuppe")
        #expect(back.isFavorite)
        #expect(library.categories.contains("Suppe"))
        #expect(await library.deletedRecipes().isEmpty)
    }

    @Test("Emptying the trash takes the pictures with it")
    func emptyingTrashFreesImages() async throws {
        let (library, images) = try makeLibrary()
        let picture = try #require(pngData())
        await library.save(Recipe(title: "Linsensuppe"))
        var recipe = try #require(library.recipes.first)
        let imageID = try #require(await library.addImage(picture, to: recipe.id))
        recipe.imageIDs = [imageID]
        await library.save(recipe)
        await library.delete(recipe)

        let emptied = await library.emptyTrash()

        #expect(emptied == 1)
        #expect(await library.deletedRecipes().isEmpty)
        #expect(library.recipes.isEmpty)
        // The blob is gone too, which is the point of emptying it.
        #expect(try await images.image(id: imageID) == nil)
    }

    /// A one-pixel PNG, since the image store insists on something readable.
    private func pngData() -> Data? {
        Data(
            base64Encoded: """
            iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
            """
        )
    }
}

@MainActor
@Suite("AI mentions caching")
struct RecipeLibraryAIMentionsTests {
    private func makeLibrary() throws -> (library: RecipeLibrary, enrichment: SwiftDataRecipeEnrichmentStore) {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let enrichment = SwiftDataRecipeEnrichmentStore(modelContainer: container)
        let library = RecipeLibrary(
            store: SwiftDataRecipeStore(modelContainer: container),
            imageStore: SwiftDataRecipeImageStore(modelContainer: container),
            enrichmentStore: enrichment
        )
        return (library, enrichment)
    }

    @Test("A cached mention comes back through the library, resolved for the current recipe")
    func readsWhatIsCached() async throws {
        let (library, enrichment) = try makeLibrary()
        let recipe = Recipe(
            title: "Kartoffelpüree", servings: 2,
            ingredientsText: "1 kg Kartoffel",
            instructionsText: "300 g Kartoffeln kochen."
        )
        try await enrichment.save(
            [StoredAmountClaim(quantityText: "300 g", modifiedNoun: "Kartoffeln", kind: .absolute, fractionValue: nil, stepNumber: 1)],
            for: recipe
        )

        let mentions = await library.aiMentions(for: recipe)
        #expect(mentions[recipe.steps[0].id]?.count == 1)
    }

    @Test("Nothing cached yet is an empty result, not an error")
    func emptyWhenNothingCached() async throws {
        let (library, _) = try makeLibrary()
        let recipe = Recipe(title: "Ofengemüse", instructionsText: "Gemüse schneiden.")
        #expect(await library.aiMentions(for: recipe).isEmpty)
    }

    @Test("A metadata-only save — toggling a favorite — leaves an already-cached result untouched")
    func metadataOnlySaveDoesNotDisturbTheCache() async throws {
        let (library, enrichment) = try makeLibrary()
        let recipe = Recipe(
            title: "Kartoffelpüree", servings: 2,
            ingredientsText: "1 kg Kartoffel",
            instructionsText: "300 g Kartoffeln kochen."
        )
        await library.save(recipe)
        let claims = [StoredAmountClaim(quantityText: "300 g", modifiedNoun: "Kartoffeln", kind: .absolute, fractionValue: nil, stepNumber: 1)]
        try await enrichment.save(claims, for: recipe)

        // Toggling a favorite goes through `save(_:)` too, but never touches
        // the ingredients or instructions — the cache must still match.
        guard let stored = library.recipes.first else {
            Issue.record("Expected the saved recipe to be in the library")
            return
        }
        await library.toggleFavorite(stored)

        #expect(try await enrichment.claims(for: recipe) == claims)
    }

    @Test("Two enrichments of the same recipe are never equal, so a still-open view's onChange always fires")
    func enrichmentEventsForTheSameRecipeAreDistinct() {
        let recipeID = UUID()
        let first = RecipeLibrary.EnrichmentEvent(recipeID: recipeID, generation: 1)
        let second = RecipeLibrary.EnrichmentEvent(recipeID: recipeID, generation: 2)
        #expect(first != second)
    }
}
