import Foundation
import SwiftData
import Testing
@testable import SousKit

@Suite("Replacing a recipe by a chat model's rewrite")
struct RecipeReplacementTests {
    private let soup = Recipe(
        title: "Linsensuppe",
        summary: "Mit Speck.",
        servings: 2,
        ingredientsText: "250 g rote Linsen\n100 g Speck",
        instructionsText: "Speck anbraten.\nLinsen kochen.",
        categories: ["Suppe"],
        notes: "Aus dem Netz."
    )

    private let answer = """
    Hier die vegane Version:

    ```json
    {"titel": "Vegane Linsensuppe", "beschreibung": "Ohne Speck.", "portionen": 4,
     "kategorien": ["Suppe", "Vegan"],
     "zutaten": ["250 g rote Linsen", "1 EL Olivenöl"],
     "zubereitung": ["# Suppe", "Öl erhitzen.", "Linsen kochen."], "notizen": "Rauchsalz passt."}
    ```
    Sag Bescheid, wenn du etwas ändern willst.
    """

    @Test("The prompt carries the task, the recipe and the catalog; a placeholder says where")
    func prompt() {
        let plain = RecipeReplacementPrompt.prompt(task: "Mach es vegan.", for: soup)
        #expect(plain.contains("Mach es vegan."))
        #expect(plain.contains("100 g Speck"))
        #expect(plain.contains("Katalog (Name | Aliasse):"))
        #expect(plain.contains("JSON"))

        let placed = RecipeReplacementPrompt.prompt(task: "Vegan, ausgewogen: {{recipe}} Danke.", for: soup)
        #expect(!placed.contains("{{recipe}}"))
        #expect(placed.contains("Danke."))
    }

    @Test("The JSON block is read out of the chat around it")
    func reads() throws {
        let replacement = try RecipeReplacementPrompt.read(answer).get()
        #expect(replacement.title == "Vegane Linsensuppe")
        #expect(replacement.servings == 4)
        #expect(replacement.categories == ["Suppe", "Vegan"])
        #expect(replacement.ingredientsText == "250 g rote Linsen\n1 EL Olivenöl")
        #expect(replacement.instructionsText == "# Suppe\nÖl erhitzen.\nLinsen kochen.")
        #expect(replacement.notes == "Rauchsalz passt.")
    }

    @Test("Without a title, ingredients or steps, or without JSON, nothing is read")
    func refuses() {
        #expect(RecipeReplacementPrompt.read("Nur Text") == .failure(.noAnswer))
        #expect(RecipeReplacementPrompt.read("{ kaputt }") == .failure(.unreadable))
        #expect(RecipeReplacementPrompt.read(#"{"zutaten": ["1 Ei"], "zubereitung": ["Kochen."]}"#) == .failure(.missing("der Titel")))
        #expect(RecipeReplacementPrompt.read(#"{"titel": "A", "zubereitung": ["Kochen."]}"#) == .failure(.missing("die Zutatenliste")))
        #expect(RecipeReplacementPrompt.read(#"{"titel": "A", "zutaten": ["1 Ei"]}"#) == .failure(.missing("die Zubereitung")))
    }

    @MainActor
    @Test("Replacing keeps the title by default, can be undone one step and reset to the original")
    func library() async throws {
        let stores = try StoreBackend.coreData.makeStores()
        let enrichment = SwiftDataRecipeEnrichmentStore(modelContainer: try ModelContainer.sousContainer(inMemory: true))
        let library = RecipeLibrary(store: stores.recipes, imageStore: stores.images, enrichmentStore: enrichment)
        try await stores.recipes.save(soup)
        let replacement = try RecipeReplacementPrompt.read(answer).get()

        #expect(await library.applyReplacement(replacement, to: soup))
        let replaced = try #require(await library.recipe(id: soup.id))
        #expect(replaced.title == "Linsensuppe")
        #expect(replaced.summary == "Ohne Speck.")
        #expect(replaced.servings == 4)
        #expect(replaced.categories == ["Suppe", "Vegan"])
        #expect(replaced.ingredientsText == "250 g rote Linsen\n1 EL Olivenöl")
        #expect(replaced.original?.ingredientsText == soup.ingredientsText)
        #expect(replaced.original?.meta?.servings == 2)
        #expect(replaced.original?.previous?.meta.summary == "Mit Speck.")

        // A second round: the original stays the first, previous is round one.
        var second = replacement
        second.ingredientsText = "250 g rote Linsen"
        #expect(await library.applyReplacement(second, fields: .all, to: replaced))
        let again = try #require(await library.recipe(id: soup.id))
        #expect(again.title == "Vegane Linsensuppe")
        #expect(again.original?.ingredientsText == soup.ingredientsText)
        #expect(again.original?.previous?.ingredientsText == "250 g rote Linsen\n1 EL Olivenöl")

        // Undo one step.
        #expect(await library.undoReplacement(again))
        let undone = try #require(await library.recipe(id: soup.id))
        #expect(undone.title == "Linsensuppe")
        #expect(undone.ingredientsText == "250 g rote Linsen\n1 EL Olivenöl")
        #expect(undone.original?.previous == nil)
        #expect(await library.undoReplacement(undone) == false)

        // Back to the original, fields beside the text included.
        #expect(await library.resetToOriginal(undone))
        let reset = try #require(await library.recipe(id: soup.id))
        #expect(reset.ingredientsText == soup.ingredientsText)
        #expect(reset.summary == "Mit Speck.")
        #expect(reset.servings == 2)
        #expect(reset.categories == ["Suppe"])

        // Asked about a text that has changed since: refused.
        var stale = soup
        stale.ingredientsText = "anderes"
        #expect(await library.applyReplacement(replacement, to: stale) == false)
    }

    @MainActor
    @Test("As a new recipe or a variant, the asked recipe is left alone")
    func asNewRecipe() async throws {
        let stores = try StoreBackend.coreData.makeStores()
        let enrichment = SwiftDataRecipeEnrichmentStore(modelContainer: try ModelContainer.sousContainer(inMemory: true))
        let library = RecipeLibrary(store: stores.recipes, imageStore: stores.images, enrichmentStore: enrichment)
        try await stores.recipes.save(soup)
        let replacement = try RecipeReplacementPrompt.read(answer).get()

        let fresh = try #require(await library.addReplacement(replacement, of: soup, asVariant: false))
        #expect(fresh.id != soup.id)
        #expect(fresh.title == "Vegane Linsensuppe")
        #expect(fresh.variantGroupID == nil)

        let variant = try #require(await library.addReplacement(replacement, of: soup, asVariant: true))
        #expect(variant.variantGroupID != nil)
        #expect(variant.ingredientsText == "250 g rote Linsen\n1 EL Olivenöl")
        let untouched = try #require(await library.recipe(id: soup.id))
        #expect(untouched.ingredientsText == soup.ingredientsText)
        #expect(untouched.variantGroupID == variant.variantGroupID)
    }
}
