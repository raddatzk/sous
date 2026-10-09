import Foundation
import SwiftData
import Testing
@testable import SousKit

@Suite("Sous export")
struct SousExportTests {
    private let picture = Data("not really a picture, but bytes are bytes".utf8)

    private var complete: Recipe {
        Recipe(
            title: "Zwiebelkuchen",
            summary: "Im Herbst, mit Federweißer.",
            servings: 12,
            ingredientsText: "1 kg Zwiebeln\n200 g Speck\n# Für den Teig\n500 g Mehl",
            instructionsText: "Zwiebeln schneiden.\nTeig ausrollen.",
            categories: ["Herbst", "Kuchen"],
            isFavorite: true,
            wantToCook: true,
            notes: "Blech gut fetten.",
            source: RecipeSource(kind: .web, url: URL(string: "https://example.com/z"), name: "example.com"),
            prepTimeSeconds: 40 * 60,
            cookTimeSeconds: 50 * 60,
            totalTimeSeconds: 3 * 3600,
            suitableSlots: [.lunch, .dinner]
        )
    }

    @Test("A recipe comes back from its own file unchanged")
    func roundTrip() throws {
        let original = complete
        let file = try SousExport.recipe(original, images: [picture])

        let batch = try SousImport.read(file, named: "Zwiebelkuchen.sousrecipe")
        let imported = try #require(batch.recipes.first)
        let back = imported.recipe

        #expect(back.id == original.id)
        #expect(back.title == original.title)
        #expect(back.summary == original.summary)
        #expect(back.servings == original.servings)
        #expect(back.ingredientsText == original.ingredientsText)
        #expect(back.instructionsText == original.instructionsText)
        #expect(back.categories == original.categories)
        #expect(back.isFavorite)
        #expect(back.wantToCook)
        #expect(back.notes == original.notes)
        #expect(back.prepTimeSeconds == original.prepTimeSeconds)
        #expect(back.cookTimeSeconds == original.cookTimeSeconds)
        #expect(back.totalTimeSeconds == original.totalTimeSeconds)
        #expect(back.source.url == original.source.url)
        #expect(back.createdAt == original.createdAt)
        #expect(back.suitableSlots == [.lunch, .dinner])
        #expect(imported.images == [picture])
    }

    @Test("What each step takes comes back with the recipe, still current")
    func stepReferencesRoundTrip() throws {
        var recipe = complete
        recipe.stepReferences = StepReferences(
            fingerprint: StepReferencesPrompt.fingerprint(for: recipe),
            steps: [
                [.init(kind: .mention, text: "", line: 1, amount: "1 kg")],
                [.init(kind: .mention, text: "", line: 3, amount: "500 g")],
            ]
        )
        let file = try SousExport.recipe(recipe, images: [])

        let back = try #require(try SousImport.read(file, named: "x.sousrecipe").recipes.first?.recipe)

        #expect(back.stepReferences == recipe.stepReferences)
        #expect(back.stepReferences?.isCurrent(for: back) == true)
    }

    @Test("A recipe with almost nothing in it survives too")
    func sparseRoundTrip() throws {
        let bare = Recipe(title: "Rührei")
        let file = try SousExport.recipe(bare, images: [])

        let back = try #require(try SousImport.read(file, named: "x.sousrecipe").recipes.first?.recipe)

        #expect(back.title == "Rührei")
        // Empty strings go out and come back as nothing, not as "".
        #expect(back.summary == nil)
        #expect(back.notes == nil)
        #expect(back.prepTimeSeconds == nil)
        #expect(back.totalTimeSeconds == nil)
        #expect(back.source.kind == .manual)
        // Undecided stays undecided — a Mela file never carries the key.
        #expect(back.suitableSlots == nil)
        #expect(back.stepReferences == nil)
    }

    @Test("A library archive reads back as the library it was")
    func libraryRoundTrip() throws {
        let recipes: [(recipe: Recipe, images: [Data], variantGroup: VariantGroup?)] = [
            (recipe: complete, images: [picture], variantGroup: nil),
            (recipe: Recipe(title: "Rührei", servings: 2), images: [], variantGroup: nil),
        ]

        let archive = try SousExport.library(recipes)
        let batch = try SousImport.read(archive, named: "Rezepte.sousrecipes")

        #expect(batch.problems.isEmpty)
        #expect(batch.recipes.count == 2)
        #expect(Set(batch.recipes.map(\.recipe.title)) == ["Zwiebelkuchen", "Rührei"])
        #expect(Set(batch.recipes.map(\.recipe.id)) == Set(recipes.map(\.recipe.id)))
    }

    @Test("Files are named after their recipe, and two of a name stay apart")
    func fileNames() {
        var used = Set<String>()
        let first = SousExport.fileName(for: Recipe(title: "Pasta"), avoiding: &used)
        let second = SousExport.fileName(for: Recipe(title: "Pasta"), avoiding: &used)
        let slashes = SousExport.fileName(for: Recipe(title: "Süß/Sauer"), avoiding: &used)
        let untitled = SousExport.fileName(for: Recipe(title: " "), avoiding: &used)

        #expect(first == "Pasta.sousrecipe")
        #expect(second == "Pasta 2.sousrecipe")
        // A slash in a title must not become a folder.
        #expect(!slashes.contains("/"))
        #expect(untitled == "Rezept.sousrecipe")
    }

    @Test("Durations are written the way Mela writes them")
    func durations() {
        #expect(SousExport.duration(1200) == "20min")
        #expect(SousExport.duration(3600) == "1h")
        #expect(SousExport.duration(5400) == "1h 30min")
        #expect(SousExport.duration(0) == "0min")
    }
}

@MainActor
@Suite("Exporting the library")
struct RecipeLibraryExportTests {
    @Test("Everything is exported, not just what the filter shows")
    func exportsWholeLibrary() async throws {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let library = RecipeLibrary(
            store: SwiftDataRecipeStore(modelContainer: container),
            imageStore: SwiftDataRecipeImageStore(modelContainer: container),
            enrichmentStore: SwiftDataRecipeEnrichmentStore(modelContainer: container)
        )
        await library.save(Recipe(title: "Linsensuppe", categories: ["Suppe"]))
        await library.save(Recipe(title: "Zwiebelkuchen", categories: ["Kuchen"]))

        // A filter that hides one of them changes nothing about the export.
        await library.apply(.category("Suppe"))
        #expect(library.recipes.count == 1)

        let archive = try #require(await library.exportedLibrary())
        let batch = try SousImport.read(archive, named: "Rezepte.sousrecipes")

        #expect(Set(batch.recipes.map(\.recipe.title)) == ["Linsensuppe", "Zwiebelkuchen"])
        #expect(library.exportProgress == nil)
    }
}
