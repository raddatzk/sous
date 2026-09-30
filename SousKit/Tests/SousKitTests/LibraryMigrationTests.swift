import Foundation
import SwiftData
import Testing
@testable import SousKit

@Suite("Library migration")
struct LibraryMigrationTests {
    private let catalog = IngredientCatalog.bundled

    private func outcome(_ line: String) -> LibraryMigration.LineOutcome {
        LibraryMigration.migrate(line: line, catalog: catalog)
    }

    // MARK: - Lines

    @Test("A line the old parser understood is written in the fixed form", arguments: [
        ("2 EL Kokosöl (oder Pflanzenöl)", "2 EL Kokosöl, oder Pflanzenöl"),
        ("200 g schwarze Bohnen (gekocht)", "200 g schwarze Bohnen, gekocht"),
        ("1 Dose Kidneybohnen - (Abtropfgewicht 500 g)", "1 Dose Kidneybohnen, Abtropfgewicht 500 g"),
        ("250 g rote Linsen - (getrocknet)", "250 g rote Linsen, getrocknet"),
        ("2 Zwiebeln, rot", "2 rote Zwiebeln"),
        ("800 g Tomaten, passierte", "800 g passierte Tomaten"),
        ("Salz nach Geschmack", "Salz, nach Geschmack"),
        ("etwas Mehl", "Mehl, etwas"),
        ("1 EL frischer Ingwer (klein gehackt)", "1 EL frischer Ingwer, klein gehackt"),
    ])
    func rewrites(line: String, fixed: String) {
        #expect(outcome(line) == .rewritten(to: fixed))
    }

    @Test("A line already in the form stays as written", arguments: [
        "500 g festkochende Kartoffeln, geschält, in Würfel",
        // After the comma everything is the annotation, a parenthesis too.
        "½ Limette, Saft davon (optional)",
        "400 g Champignons , geviertelt",
        "2 große Aubergine(n)",
        "1 Spritzer Zitronensaft",
        "Salz, Pfeffer nach Geschmack",
        "1 1/2 TL Backpulver",
    ])
    func keeps(line: String) {
        #expect(outcome(line) == .inForm)
    }

    @Test("A line neither reader can take stays as written, for the optimization", arguments: [
        "1 TL frisch geriebener Ingwer",
        "300 ml dünne Kokosmilch (oder Kokosmilch mit etwas Wasser verdünnt)",
        "150 g Einhornstaub",
        // The old parser would read "1 Chili, rot" as a red chili, which is
        // not what the line meant: an older app must read a rewrite alike.
        "1 Chili (rot)",
    ])
    func marks(line: String) {
        #expect(outcome(line) == .outsideForm)
    }

    // MARK: - Recipes

    private let chili = Recipe(
        title: "Chili sin Carne",
        servings: 4,
        ingredientsText: """
        # Chili
        250 g rote Linsen - (getrocknet)
        2 Zwiebeln, rot
        1 TL frisch geriebener Ingwer

        # Topping
        1 Limette (optional)
        """,
        instructionsText: "Linsen kochen.\nZwiebeln anbraten.\nMit Limette servieren."
    )

    @Test("Only the changed lines change; headings, blank lines and order stay")
    func recipeText() {
        let migrated = LibraryMigration.migrate(chili, catalog: catalog, keptAt: .distantPast)
        #expect(migrated.recipe.ingredientsText == """
        # Chili
        250 g rote Linsen, getrocknet
        2 rote Zwiebeln
        1 TL frisch geriebener Ingwer

        # Topping
        1 Limette, optional
        """)
        #expect(migrated.rewrittenCount == 3)
        #expect(migrated.outsideForm == ["1 TL frisch geriebener Ingwer"])
        #expect(migrated.recipe.ingredients(readWith: catalog).count == chili.ingredients(readWith: catalog).count)
        #expect(migrated.recipe.instructionsText == chili.instructionsText)
    }

    @Test("The original is kept first, and an existing one is never replaced")
    func original() {
        let migrated = LibraryMigration.migrate(chili, catalog: catalog, keptAt: .distantPast).recipe
        #expect(migrated.original?.ingredientsText == chili.ingredientsText)

        var imported = chili
        imported.original = RecipeOriginal(of: Recipe(title: "Import", ingredientsText: "vom Web"), keptAt: .distantPast)
        let again = LibraryMigration.migrate(imported, catalog: catalog).recipe
        #expect(again.original?.ingredientsText == "vom Web")
    }

    @Test("A recipe with nothing to rewrite is left alone, without an original")
    func untouched() {
        let clean = Recipe(title: "Dal", ingredientsText: "250 g rote Linsen\n1 TL frisch geriebener Ingwer")
        let migrated = LibraryMigration.migrate(clean, catalog: catalog)
        #expect(!migrated.changed)
        #expect(migrated.recipe == clean)
        #expect(migrated.recipe.original == nil)
    }

    @Test("Running it twice changes nothing the second time")
    func idempotent() {
        let first = LibraryMigration.migrate([chili], catalog: catalog)
        let second = LibraryMigration.migrate(first.outcomes.map(\.recipe), catalog: catalog)
        #expect(first.summary.rewritten == 3)
        #expect(second.summary.rewritten == 0)
        #expect(second.outcomes.allSatisfy { !$0.changed })
        #expect(second.outcomes.first?.recipe == first.outcomes.first?.recipe)
        #expect(second.summary.outsideForm == first.summary.outsideForm)
    }

    @Test("Current step references are stamped for the new text and keep their lines")
    func restampsCurrentReferences() throws {
        var recipe = chili
        recipe.stepReferences = StepReferences(
            fingerprint: StepReferencesPrompt.fingerprint(for: recipe),
            steps: [[.init(kind: .mention, text: "", line: 1, amount: nil)],
                    [.init(kind: .mention, text: "", line: 2, amount: nil)],
                    [.init(kind: .mention, text: "", line: 4, amount: nil)]]
        )
        try #require(recipe.stepReferences?.isCurrent(for: recipe) == true)

        let migrated = LibraryMigration.migrate(recipe, catalog: catalog).recipe
        let references = try #require(migrated.stepReferences)
        #expect(references.isCurrent(for: migrated))
        #expect(references.steps == recipe.stepReferences?.steps)
        // Line 2 is still the onions, now written as the variety.
        let lines = migrated.ingredients(readWith: catalog)
        #expect(catalog.ingredient(for: lines[1].name)?.name == "Rote Zwiebel")
    }

    @Test("Stale step references stay stale — they were not right before either")
    func leavesStaleReferences() {
        var recipe = chili
        recipe.stepReferences = StepReferences(fingerprint: "stale", steps: [[], [], []])
        let migrated = LibraryMigration.migrate(recipe, catalog: catalog).recipe
        #expect(migrated.stepReferences?.fingerprint == "stale")
        #expect(migrated.stepReferences?.isCurrent(for: migrated) == false)
    }

    @Test("The summary counts what the preview shows")
    func summary() {
        let clean = Recipe(title: "Dal", ingredientsText: "250 g rote Linsen\n1 TL Kurkuma, gemahlen")
        let summary = LibraryMigration.migrate([chili, clean], catalog: catalog).summary
        #expect(summary.recipes == 2)
        #expect(summary.recipesChanged == 1)
        #expect(summary.lines == 6)
        #expect(summary.rewritten == 3)
        #expect(summary.outsideForm == [.init(recipeTitle: "Chili sin Carne", line: "1 TL frisch geriebener Ingwer")])
        // "rote Linsen, getrocknet", "Limette, optional", "Kurkuma, gemahlen".
        #expect(summary.annotated == 3)
    }

    // MARK: - The library

    @MainActor
    @Test("Bibliothek umstellen saves the changed recipes, trash included, and a second run finds nothing")
    func library() async throws {
        // Core Data: the store that keeps a recipe's original.
        let stores = try StoreBackend.coreData.makeStores()
        let store = stores.recipes
        let library = RecipeLibrary(
            store: store,
            imageStore: stores.images,
            enrichmentStore: SwiftDataRecipeEnrichmentStore(
                modelContainer: try ModelContainer.sousContainer(inMemory: true)
            )
        )
        let clean = Recipe(title: "Dal", ingredientsText: "250 g rote Linsen")
        try await store.save(chili)
        try await store.save(clean)
        var trashed = Recipe(title: "Alt", ingredientsText: "2 Zwiebeln, rot")
        trashed.deletedAt = .distantPast
        try await store.save(trashed)

        let preview = await library.libraryMigrationPreview()
        #expect(preview.recipes == 3)
        #expect(preview.recipesChanged == 2)
        // The preview writes nothing.
        #expect(try await store.recipe(id: chili.id)?.ingredientsText == chili.ingredientsText)

        let done = await library.migrateLibrary()
        #expect(done == preview)
        let saved = try #require(try await store.recipe(id: chili.id))
        #expect(saved.ingredientsText.contains("2 rote Zwiebeln"))
        #expect(saved.original?.ingredientsText == chili.ingredientsText)
        #expect(try await store.recipe(id: trashed.id)?.ingredientsText == "2 rote Zwiebeln")
        #expect(try await store.recipe(id: clean.id)?.original == nil)

        let again = await library.libraryMigrationPreview()
        #expect(again.recipesChanged == 0)
        #expect(again.rewritten == 0)
    }
}
