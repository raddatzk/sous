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

    @Test("The household's categories go into the prompt, most used first as given, when there are any")
    func promptCarriesCategories() {
        let with = RecipeReplacementPrompt.prompt(task: "x", for: soup, categories: ["Suppe", "Vegan", "Dessert"])
        #expect(with.contains("Vorhandene Kategorien:\nSuppe, Vegan, Dessert\n"))
        let without = RecipeReplacementPrompt.prompt(task: "x", for: soup)
        #expect(!without.contains("Vorhandene Kategorien:"))
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

    @Test("The prompt pasted instead of the answer is refused, its example JSON is no recipe")
    func refusesThePrompt() {
        let prompt = RecipeReplacementPrompt.prompt(task: "Mach es vegan.", for: soup)
        #expect(RecipeReplacementPrompt.read(prompt) == .failure(.pastedThePrompt))
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
    @Test("Replacing keeps the title by default, keeps every version, and any of them comes back")
    func library() async throws {
        let stores = try StoreBackend.coreData.makeStores()
        let enrichment = SwiftDataRecipeEnrichmentStore(modelContainer: try ModelContainer.sousContainer(inMemory: true))
        let library = RecipeLibrary(store: stores.recipes, imageStore: stores.images, enrichmentStore: enrichment)
        try await stores.recipes.save(soup)
        let replacement = try RecipeReplacementPrompt.read(answer).get()

        #expect(await library.applyReplacement(replacement, request: "Vegan machen", to: soup))
        let replaced = try #require(await library.recipe(id: soup.id))
        #expect(replaced.title == "Linsensuppe")
        #expect(replaced.summary == "Ohne Speck.")
        #expect(replaced.servings == 4)
        #expect(replaced.categories == ["Suppe", "Vegan"])
        #expect(replaced.ingredientsText == "250 g rote Linsen\n1 EL Olivenöl")
        // The first change keeps the recipe as the original, whole.
        #expect(replaced.original?.ingredientsText == soup.ingredientsText)
        #expect(replaced.original?.meta?.servings == 2)
        #expect(replaced.versions.map(\.kind) == [.current, .original])

        // A second round: the original stays the first, round one joins the history.
        var second = replacement
        second.ingredientsText = "250 g rote Linsen"
        #expect(await library.applyReplacement(second, fields: .all, request: "Für vier", to: replaced))
        let again = try #require(await library.recipe(id: soup.id))
        #expect(again.title == "Vegane Linsensuppe")
        #expect(again.original?.ingredientsText == soup.ingredientsText)
        let versions = again.versions
        #expect(versions.map(\.kind) == [.current, .earlier(0), .original])
        #expect(versions[1].ingredientsText == "250 g rote Linsen\n1 EL Olivenöl")
        #expect(versions[1].replacedBy == "Für vier")

        // Back one step: round one again, and round two kept in its turn.
        #expect(await library.restore(versions[1], of: again))
        let undone = try #require(await library.recipe(id: soup.id))
        #expect(undone.title == "Linsensuppe")
        #expect(undone.ingredientsText == "250 g rote Linsen\n1 EL Olivenöl")
        #expect(undone.versions.count == 4)
        #expect(undone.versions[1].title == "Vegane Linsensuppe")
        #expect(undone.versions[1].replacedBy == "Wiederherstellung")
        // Restoring what is there already changes nothing.
        #expect(await library.restore(undone.versions[0], of: undone) == false)

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
    @Test("The answer's references come along: the new recipe scales in cook mode and reads as optimized")
    func referencesComeAlong() async throws {
        let stores = try StoreBackend.coreData.makeStores()
        let enrichment = SwiftDataRecipeEnrichmentStore(modelContainer: try ModelContainer.sousContainer(inMemory: true))
        let library = RecipeLibrary(store: stores.recipes, imageStore: stores.images, enrichmentStore: enrichment)
        try await stores.recipes.save(soup)
        #expect(!soup.isOptimizedForSous)

        let withReferences = #"""
        ```json
        {"titel": "Linsensuppe", "portionen": 2,
         "zutaten": ["250 g rote Linsen", "1 l Gemüsebrühe"],
         "zubereitung": ["200 g Linsen in der Brühe kochen.", "Die übrigen Linsen zugeben."],
         "bezuege": [
          {"schritt": 1, "bezuege": [{"art": "menge", "stelle": "200 g", "vorkommen": 1, "zeile": 1, "menge": "200 g"},
                                    {"art": "bezug", "zeile": 2, "menge": "1 l"}]},
          {"schritt": 2, "bezuege": [{"art": "bezug", "zeile": 1, "menge": "50 g"}]}]}
        ```
        """#
        let replacement = try RecipeReplacementPrompt.read(withReferences).get()
        #expect(replacement.hasStepReferences)
        #expect(await library.applyReplacement(replacement, fields: .all, to: soup))
        let stored = try #require(await library.recipe(id: soup.id))
        let references = try #require(stored.stepReferences)
        #expect(references.isCurrent(for: stored))
        #expect(references.steps.count == 2)
        #expect(stored.isOptimizedForSous)

        // A reference to a line the answer does not have: no references at all.
        let broken = withReferences.replacingOccurrences(of: #""zeile": 2"#, with: #""zeile": 9"#)
        let applied = try RecipeReplacementPrompt.read(broken).get().applied(to: soup, fields: .all)
        #expect(applied.stepReferences == nil)
        #expect(!applied.isOptimizedForSous)
    }

    @Test("The prompt asks for the references, numbered past the headings")
    func promptAsksForReferences() {
        let prompt = RecipeReplacementPrompt.prompt(task: "x", for: soup)
        #expect(prompt.contains(#""bezuege""#))
        #expect(prompt.contains("Überschriften"))
    }

    @MainActor
    @Test("An edit saved in the editor is a version; a new favourite is not; the history keeps ten")
    func editsAreVersions() async throws {
        let stores = try StoreBackend.coreData.makeStores()
        let enrichment = SwiftDataRecipeEnrichmentStore(modelContainer: try ModelContainer.sousContainer(inMemory: true))
        let library = RecipeLibrary(store: stores.recipes, imageStore: stores.images, enrichmentStore: enrichment)
        try await stores.recipes.save(soup)

        var favourite = soup
        favourite.isFavorite = true
        await library.saveEdited(favourite)
        #expect(try #require(await library.recipe(id: soup.id)).versions.count == 1)

        var typo = try #require(await library.recipe(id: soup.id))
        typo.instructionsText = "Speck anbraten.\nLinsen kochn."
        await library.saveEdited(typo)
        var fixed = typo
        fixed.instructionsText = "Speck anbraten.\nLinsen kochen."
        await library.saveEdited(fixed)
        let edited = try #require(await library.recipe(id: soup.id))
        #expect(edited.versions.map(\.kind) == [.current, .earlier(0), .original])
        #expect(edited.versions[1].instructionsText == "Speck anbraten.\nLinsen kochn.")
        #expect(edited.versions[1].replacedBy == "Bearbeitet")
        #expect(edited.isFavorite)

        // An editor opened before another change keeps that change's version.
        for round in 0..<14 {
            var next = try #require(await library.recipe(id: soup.id))
            next.notes = "Runde \(round)"
            await library.saveEdited(next)
        }
        let long = try #require(await library.recipe(id: soup.id))
        #expect(long.original?.history?.count == RecipeOriginal.historyLimit)
        #expect(long.versions.last?.kind == .original)
        #expect(long.versions.last?.ingredientsText == soup.ingredientsText)
    }

    @Test("Two versions compare line by line, fields side by side")
    func difference() {
        var after = soup
        after.title = "Vegane Linsensuppe"
        after.servings = 4
        after.ingredientsText = "250 g rote Linsen\n150 g Räuchertofu"
        let difference = RecipeVersionDifference(
            from: RecipeVersion(current: soup), to: RecipeVersion(current: after)
        )
        #expect(difference.fields.map(\.name) == ["Titel", "Portionen"])
        #expect(difference.ingredients == [
            .same("250 g rote Linsen"), .removed("100 g Speck"), .added("150 g Räuchertofu"),
        ])
        #expect(difference.steps.allSatisfy { if case .same = $0 { true } else { false } })
        #expect(!difference.isEmpty)
        #expect(RecipeVersionDifference(from: RecipeVersion(current: soup), to: RecipeVersion(current: soup)).isEmpty)
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
