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
        let amountReview = SwiftDataRecipeAmountReviewStore(modelContainer: container)
        return (RecipeLibrary(store: store, imageStore: images, enrichmentStore: enrichment, amountReviewStore: amountReview), store)
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
            enrichmentStore: enrichment,
            amountReviewStore: SwiftDataRecipeAmountReviewStore(modelContainer: container)
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
            enrichmentStore: enrichment,
            amountReviewStore: SwiftDataRecipeAmountReviewStore(modelContainer: container)
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
                enrichmentStore: SwiftDataRecipeEnrichmentStore(modelContainer: container),
                amountReviewStore: SwiftDataRecipeAmountReviewStore(modelContainer: container)
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
            enrichmentStore: enrichment,
            amountReviewStore: SwiftDataRecipeAmountReviewStore(modelContainer: container)
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

@MainActor
@Suite("Amount review")
struct RecipeLibraryAmountReviewTests {
    private func makeLibrary() throws -> RecipeLibrary {
        let container = try ModelContainer.sousContainer(inMemory: true)
        return RecipeLibrary(
            store: SwiftDataRecipeStore(modelContainer: container),
            imageStore: SwiftDataRecipeImageStore(modelContainer: container),
            enrichmentStore: SwiftDataRecipeEnrichmentStore(modelContainer: container),
            amountReviewStore: SwiftDataRecipeAmountReviewStore(modelContainer: container)
        )
    }

    @Test("A freshly imported recipe with a bare mention needs review")
    func freshRecipeNeedsReview() async throws {
        let library = try makeLibrary()
        let recipe = Recipe(
            title: "Kartoffelpüree", servings: 2,
            ingredientsText: "150 g Butter",
            instructionsText: "Die Butter erhitzen."
        )
        #expect(await library.needsAmountReview(recipe))
    }

    @Test("A recipe with nothing bare to suggest never needs review")
    func recipeWithNoSuggestionsNeedsNoReview() async throws {
        let library = try makeLibrary()
        let recipe = Recipe(
            title: "Kartoffelpüree", servings: 2,
            ingredientsText: "150 g Butter",
            instructionsText: "150 g Butter erhitzen."
        )
        #expect(!(await library.needsAmountReview(recipe)))
    }

    @Test("Applying accepted suggestions writes them in and settles the review")
    func applyingSuggestionsSettlesTheReview() async throws {
        let library = try makeLibrary()
        let recipe = Recipe(
            title: "Kartoffelpüree", servings: 2,
            ingredientsText: "150 g Butter",
            instructionsText: "Die Butter erhitzen."
        )
        let (resolution, suggestions) = await library.amountSuggestions(for: recipe)
        #expect(suggestions.count == 1)

        await library.applyAmountSuggestions(Set(suggestions.map(\.id)), resolution: resolution, to: recipe)

        guard let saved = library.recipes.first else {
            Issue.record("Expected the recipe to be saved")
            return
        }
        #expect(saved.instructionsText.contains("Die Butter (150 g) erhitzen."))
        #expect(!(await library.needsAmountReview(saved)))
    }

    @Test("Dismissing without any change also settles the review, for the text as it stands")
    func dismissingWithoutChangesSettlesTheReview() async throws {
        let library = try makeLibrary()
        let recipe = Recipe(
            title: "Kartoffelpüree", servings: 2,
            ingredientsText: "150 g Butter",
            instructionsText: "Die Butter erhitzen."
        )
        await library.markAmountsReviewed(recipe)
        #expect(!(await library.needsAmountReview(recipe)))
    }

    @Test("Editing the recipe again after a review reopens the question")
    func furtherEditingReopensTheReview() async throws {
        let library = try makeLibrary()
        let recipe = Recipe(
            title: "Kartoffelpüree", servings: 2,
            ingredientsText: "150 g Butter",
            instructionsText: "Die Butter erhitzen."
        )
        await library.markAmountsReviewed(recipe)

        var edited = recipe
        edited.ingredientsText = "150 g Butter\n1 Ei"
        edited.instructionsText = "Die Butter erhitzen. Das Ei verquirlen."
        #expect(await library.needsAmountReview(edited))
    }

    @Test("A cached AI claim needs review too — it never resolves on its own, only through the sheet")
    func cachedAIClaimNeedsReview() async throws {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let enrichment = SwiftDataRecipeEnrichmentStore(modelContainer: container)
        let library = RecipeLibrary(
            store: SwiftDataRecipeStore(modelContainer: container),
            imageStore: SwiftDataRecipeImageStore(modelContainer: container),
            enrichmentStore: enrichment,
            amountReviewStore: SwiftDataRecipeAmountReviewStore(modelContainer: container)
        )
        let recipe = Recipe(
            title: "Ofengemüse", servings: 2,
            ingredientsText: "300 g Paprika",
            instructionsText: "Ein Drittel der Paprika in Scheiben schneiden."
        )
        try await enrichment.save(
            [StoredAmountClaim(quantityText: "Ein Drittel", modifiedNoun: "Paprika", kind: .fraction, fractionValue: 1.0 / 3.0, stepNumber: 1)],
            for: recipe
        )

        let (resolution, suggestions) = await library.amountSuggestions(for: recipe)
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.displayAmount == "100 g")
        #expect(await library.needsAmountReview(recipe))

        await library.applyAmountSuggestions(Set(suggestions.map(\.id)), resolution: resolution, to: recipe)
        guard let saved = library.recipes.first else {
            Issue.record("Expected the recipe to be saved")
            return
        }
        #expect(saved.instructionsText.contains("Ein Drittel der Paprika (100 g) in Scheiben schneiden."))
        #expect(!(await library.needsAmountReview(saved)))
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
            amountReviewStore: SwiftDataRecipeAmountReviewStore(modelContainer: container),
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
