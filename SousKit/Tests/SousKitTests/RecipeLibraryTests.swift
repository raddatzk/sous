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

    @Test("A meal filter reads the recipe first and the cached guess second")
    func slotFilterUsesStatedMealsThenTheGuess() async throws {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let store = SwiftDataRecipeStore(modelContainer: container)
        let enrichment = SwiftDataRecipeEnrichmentStore(modelContainer: container)
        let library = RecipeLibrary(
            store: store,
            imageStore: SwiftDataRecipeImageStore(modelContainer: container),
            enrichmentStore: enrichment
        )

        let stated = try await store.save(Recipe(title: "Porridge", suitableSlots: [.breakfast]))
        let guessed = try await store.save(Recipe(title: "Overnight Oats"))
        let unjudged = try await store.save(Recipe(title: "Unentschieden"))
        try await enrichment.saveSuitabilityGuess(
            [.breakfast],
            for: guessed.id,
            inputHash: MealSuitabilityClassifier.inputHash(for: guessed)
        )

        let breakfast = await library.findRecipes(matching: "", filters: [.slot(.breakfast)])

        // The one that says so and the one that was guessed — and not the one
        // nobody has judged, which is why this filter is "what is known"
        // rather than "what is likely".
        #expect(breakfast.map(\.title) == ["Overnight Oats", "Porridge"])
        #expect(!breakfast.contains { $0.id == unjudged.id })
        #expect(breakfast.contains { $0.id == stated.id })
    }

    @Test("A guess made against older words does not answer for the new ones")
    func staleGuessesAreNotUsed() async throws {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let store = SwiftDataRecipeStore(modelContainer: container)
        let enrichment = SwiftDataRecipeEnrichmentStore(modelContainer: container)
        let library = RecipeLibrary(
            store: store,
            imageStore: SwiftDataRecipeImageStore(modelContainer: container),
            enrichmentStore: enrichment
        )

        var recipe = try await store.save(Recipe(title: "Overnight Oats", ingredientsText: "Haferflocken"))
        try await enrichment.saveSuitabilityGuess(
            [.breakfast],
            for: recipe.id,
            inputHash: MealSuitabilityClassifier.inputHash(for: recipe)
        )
        // Rewritten into something else entirely: the old judgment was about
        // words that are gone.
        recipe.ingredientsText = "Rinderhack, Tomaten"
        _ = try await store.save(recipe)

        let breakfast = await library.findRecipes(matching: "", filters: [.slot(.breakfast)])
        #expect(breakfast.isEmpty)
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

        // Asked for rather than waited out. The reload is debounced by 150 ms
        // and then has a store round trip to make, and a fixed sleep turns
        // that into a bet on how loaded the machine is — which is what made
        // this the suite's flakiest test. The ceiling is generous because it
        // is only ever reached when something is actually broken.
        try await untilTrue(within: .seconds(5)) {
            library.recipes.map(\.title) == ["Linsensuppe"]
        }
        #expect(library.recipes.map(\.title) == ["Linsensuppe"])
    }

    @Test("Offers say how many recipes they leave, and none that would leave nothing")
    func suggestionsAreCounted() async throws {
        let (library, store) = try makeLibrary()
        try await store.save(Recipe(
            title: "Paprika-Hähnchen", servings: 2,
            ingredientsText: "2 Paprika\n500 g Hähnchenbrust", instructionsText: "Braten.",
            categories: ["Hauptgericht"]
        ))
        try await store.save(Recipe(
            title: "Gefüllte Paprika", servings: 2,
            ingredientsText: "4 Paprika\n300 g Hackfleisch", instructionsText: "Füllen.",
            categories: ["Hauptgericht"]
        ))
        try await store.save(Recipe(
            title: "Kürbissuppe", servings: 2,
            ingredientsText: "1 Hokkaido", instructionsText: "Kochen.",
            categories: ["Suppe"]
        ))
        await library.reload()

        let offers = await library.filterSuggestions(
            for: "pa", applied: [], catalog: .bundled, limit: 4
        )
        // The catalog knows plenty starting with "pa" — Pastinake, Pak Choi —
        // but only what the library cooks with is worth a tap.
        #expect(!offers.isEmpty)
        #expect(offers.allSatisfy { $0.count > 0 })
        #expect(!offers.contains { $0.filter.title == "Pastinake" })
        let paprika = try #require(offers.first { $0.filter.title == "Paprika" })
        #expect(paprika.count == 2)

        // Counted within what is already picked: no soup has paprika in it.
        let inSoups = await library.filterSuggestions(
            for: "pa", applied: [.category("Suppe")], catalog: .bundled, limit: 4
        )
        #expect(!inSoups.contains { $0.filter.title == "Paprika" })

        #expect(await library.filterSuggestions(
            for: "Hauptg", applied: [], catalog: .bundled, limit: 4
        ).map(\.count) == [2])
    }
}

/// Waits for `condition` to hold, polling rather than sleeping a fixed span.
///
/// For assertions about work that is debounced or handed to another task:
/// the thing under test has a deadline, the test should not also have a
/// guess at one.
@MainActor
private func untilTrue(
    within limit: Duration, poll: Duration = .milliseconds(10), _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: poll)
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
@Suite("Ingredient review")
struct RecipeLibraryIngredientReviewTests {
    private func makeLibrary() async throws -> RecipeLibrary {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let catalogLibrary = IngredientCatalogLibrary(store: SwiftDataVocabularyStore(modelContainer: container))
        await catalogLibrary.reload()
        return RecipeLibrary(
            store: SwiftDataRecipeStore(modelContainer: container),
            imageStore: SwiftDataRecipeImageStore(modelContainer: container),
            enrichmentStore: SwiftDataRecipeEnrichmentStore(modelContainer: container),
            ingredientReviewStore: SwiftDataRecipeIngredientReviewStore(modelContainer: container),
            catalogLibrary: catalogLibrary
        )
    }

    @Test("A recipe with an ingredient the catalog does not know needs review")
    func unknownIngredientNeedsReview() async throws {
        let library = try await makeLibrary()
        let recipe = Recipe(title: "Kimchi-Suppe", servings: 2, ingredientsText: "300 g Tomaten\n2 EL Gochujang")

        #expect(library.unknownIngredients(in: recipe) == ["Gochujang"])
        #expect(await library.needsIngredientReview(recipe))
    }

    @Test("A recipe the catalog fully recognizes never needs review")
    func fullyKnownRecipeNeedsNoReview() async throws {
        let library = try await makeLibrary()
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "300 g Tomaten\nSalz")

        #expect(library.unknownIngredients(in: recipe).isEmpty)
        #expect(!(await library.needsIngredientReview(recipe)))
    }

    @Test("Marking reviewed settles the question for the current text")
    func markingReviewedSettlesTheQuestion() async throws {
        let library = try await makeLibrary()
        let recipe = Recipe(title: "Kimchi-Suppe", servings: 2, ingredientsText: "2 EL Gochujang")

        await library.markIngredientsReviewed(recipe)
        #expect(!(await library.needsIngredientReview(recipe)))
    }

    @Test("Editing the recipe again after a review reopens the question")
    func furtherEditingReopensTheReview() async throws {
        let library = try await makeLibrary()
        let recipe = Recipe(title: "Kimchi-Suppe", servings: 2, ingredientsText: "2 EL Gochujang")
        await library.markIngredientsReviewed(recipe)

        var edited = recipe
        edited.ingredientsText = "2 EL Gochujang\n1 Sumach"
        #expect(await library.needsIngredientReview(edited))
    }
}
