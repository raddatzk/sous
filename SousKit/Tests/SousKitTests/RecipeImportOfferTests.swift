import Foundation
import SwiftData
import Testing
@testable import SousKit

@Suite("What an opened file offers")
struct RecipeImportOfferTests {
    private let problem = RecipeImportProblem(name: "kaputt.melarecipe", reason: "Kein lesbares Rezept.")

    private func item(_ title: String) -> ImportedRecipe {
        ImportedRecipe(recipe: Recipe(
            id: StableID.make(namespace: "test", index: 0, content: title), title: title
        ))
    }

    @Test("A file with nothing readable in it says so")
    func nothingReadable() {
        let offer = RecipeImportOffer(batch: RecipeImportBatch(problems: [problem]), existing: [:])
        #expect(offer == .nothingReadable(problems: [problem]))
    }

    @Test("A single recipe the library has is opened, not imported again")
    func alreadyHere() {
        let soup = item("Suppe")
        let stored = Recipe(id: soup.recipe.id, title: "Suppe, seither verbessert")
        let offer = RecipeImportOffer(
            batch: RecipeImportBatch(recipes: [soup]), existing: [stored.id: stored]
        )
        // The library's version, not the file's: that is the one to read.
        #expect(offer == .alreadyHere(stored))
    }

    @Test("A recipe in the trash counts as new, so importing brings it back")
    func trashedIsNew() throws {
        let soup = item("Suppe")
        let trashed = Recipe(id: soup.recipe.id, title: "Suppe", deletedAt: .now)
        let offer = RecipeImportOffer(
            batch: RecipeImportBatch(recipes: [soup]), existing: [trashed.id: trashed]
        )
        guard case .preview(let preview) = offer else {
            Issue.record("expected a preview")
            return
        }
        #expect(preview.entries.map(\.isNew) == [true])
        #expect(preview.initialSelection == [soup.recipe.id])
    }

    @Test("A preview lists everything alphabetically, with only the new recipes ticked")
    func preview() throws {
        let soup = item("Suppe")
        let salad = item("Salat")
        let apple = item("Apfelkuchen")
        let stored = Recipe(id: soup.recipe.id, title: "Suppe, seither verbessert")
        let offer = RecipeImportOffer(
            batch: RecipeImportBatch(recipes: [soup, salad, apple, soup], problems: [problem]),
            existing: [stored.id: stored]
        )
        guard case .preview(let preview) = offer else {
            Issue.record("expected a preview")
            return
        }

        // The duplicate is gone; the order is the recipe list's.
        #expect(preview.entries.map(\.recipe.title) == ["Apfelkuchen", "Salat", "Suppe"])
        #expect(preview.entries.last?.existing == stored)
        #expect(preview.newCount == 2)
        #expect(preview.initialSelection == [salad.recipe.id, apple.recipe.id])
        #expect(preview.problems == [problem])

        // Choosing is by id, and the file's problems stay behind.
        let chosen = preview.batch(selecting: [soup.recipe.id, apple.recipe.id])
        #expect(chosen.recipes.map(\.recipe.title) == ["Apfelkuchen", "Suppe"])
        #expect(chosen.problems.isEmpty)
    }

    @Test("A file whose recipes are all here still offers them, none ticked")
    func allHere() throws {
        let soup = item("Suppe")
        let salad = item("Salat")
        let offer = RecipeImportOffer(
            batch: RecipeImportBatch(recipes: [soup, salad]),
            existing: [soup.recipe.id: soup.recipe, salad.recipe.id: salad.recipe]
        )
        guard case .preview(let preview) = offer else {
            Issue.record("expected a preview")
            return
        }
        #expect(preview.initialSelection.isEmpty)
        #expect(preview.newCount == 0)
    }
}

@MainActor
@Suite("Offering an opened file against the library")
struct RecipeImportOfferLibraryTests {
    @Test("A file read twice offers its recipes the first time and opens them the second")
    func readThenStored() async throws {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let library = RecipeLibrary(
            store: SwiftDataRecipeStore(modelContainer: container),
            imageStore: SwiftDataRecipeImageStore(modelContainer: container),
            enrichmentStore: SwiftDataRecipeEnrichmentStore(modelContainer: container)
        )
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/Gulasch.paprikarecipe", withExtension: nil)
        )
        let batch = try await library.readRecipes(
            from: try Data(contentsOf: url), named: "Gulasch.paprikarecipe"
        )

        // Reading stores nothing.
        #expect(library.recipes.isEmpty)
        guard case .preview(let preview) = await library.offer(for: batch) else {
            Issue.record("expected the recipe to be offered")
            return
        }

        let summary = await library.importRecipes(
            preview.batch(selecting: preview.initialSelection)
        )
        #expect(summary.imported == 1)

        guard case .alreadyHere(let recipe) = await library.offer(for: batch) else {
            Issue.record("expected the stored recipe")
            return
        }
        #expect(recipe.title == "Gulasch")
        #expect(library.importProgress == nil)
    }
}
