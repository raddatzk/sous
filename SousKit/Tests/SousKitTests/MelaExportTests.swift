import Foundation
import SwiftData
import Testing
@testable import SousKit

@Suite("Mela export")
struct MelaExportTests {
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
            totalTimeSeconds: 3 * 3600
        )
    }

    @Test("A recipe comes back from its own file unchanged")
    func roundTrip() throws {
        let original = complete
        let file = try MelaExport.recipe(original, images: [picture])

        let batch = try MelaImport.read(file, named: "Zwiebelkuchen.melarecipe")
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
        #expect(imported.images == [picture])
    }

    @Test("A recipe with almost nothing in it survives too")
    func sparseRoundTrip() throws {
        let bare = Recipe(title: "Rührei")
        let file = try MelaExport.recipe(bare, images: [])

        let back = try #require(try MelaImport.read(file, named: "x.melarecipe").recipes.first?.recipe)

        #expect(back.title == "Rührei")
        // Empty strings go out and come back as nothing, not as "".
        #expect(back.summary == nil)
        #expect(back.notes == nil)
        #expect(back.prepTimeSeconds == nil)
        #expect(back.totalTimeSeconds == nil)
        #expect(back.source.kind == .manual)
    }

    @Test("A library archive reads back as the library it was")
    func libraryRoundTrip() throws {
        let recipes = [
            (recipe: complete, images: [picture]),
            (recipe: Recipe(title: "Rührei", servings: 2), images: []),
        ]

        let archive = try MelaExport.library(recipes)
        let batch = try MelaImport.read(archive, named: "Rezepte.melarecipes")

        #expect(batch.problems.isEmpty)
        #expect(batch.recipes.count == 2)
        #expect(Set(batch.recipes.map(\.recipe.title)) == ["Zwiebelkuchen", "Rührei"])
        #expect(Set(batch.recipes.map(\.recipe.id)) == Set(recipes.map(\.recipe.id)))
    }

    @Test("Files are named after their recipe, and two of a name stay apart")
    func fileNames() {
        var used = Set<String>()
        let first = MelaExport.fileName(for: Recipe(title: "Pasta"), avoiding: &used)
        let second = MelaExport.fileName(for: Recipe(title: "Pasta"), avoiding: &used)
        let slashes = MelaExport.fileName(for: Recipe(title: "Süß/Sauer"), avoiding: &used)
        let untitled = MelaExport.fileName(for: Recipe(title: " "), avoiding: &used)

        #expect(first == "Pasta.melarecipe")
        #expect(second == "Pasta 2.melarecipe")
        // A slash in a title must not become a folder.
        #expect(!slashes.contains("/"))
        #expect(untitled == "Rezept.melarecipe")
    }

    @Test("Durations are written the way Mela writes them")
    func durations() {
        #expect(MelaExport.duration(1200) == "20min")
        #expect(MelaExport.duration(3600) == "1h")
        #expect(MelaExport.duration(5400) == "1h 30min")
        #expect(MelaExport.duration(0) == "0min")
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
            imageStore: SwiftDataRecipeImageStore(modelContainer: container)
        )
        await library.save(Recipe(title: "Linsensuppe", categories: ["Suppe"]))
        await library.save(Recipe(title: "Zwiebelkuchen", categories: ["Kuchen"]))

        // A filter that hides one of them changes nothing about the export.
        await library.apply(.category("Suppe"))
        #expect(library.recipes.count == 1)

        let archive = try #require(await library.exportedLibrary())
        let batch = try MelaImport.read(archive, named: "Rezepte.melarecipes")

        #expect(Set(batch.recipes.map(\.recipe.title)) == ["Linsensuppe", "Zwiebelkuchen"])
        #expect(library.exportProgress == nil)
    }
}
