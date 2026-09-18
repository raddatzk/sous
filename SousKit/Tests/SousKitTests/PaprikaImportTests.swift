import Foundation
import SwiftData
import Testing
@testable import SousKit

@Suite("Paprika import")
struct PaprikaImportTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
        )
        return try Data(contentsOf: url)
    }

    @Test("A single gzip-compressed recipe carries over field by field")
    func singleRecipe() throws {
        let batch = try PaprikaImport.read(fixture("Gulasch.paprikarecipe"), named: "Gulasch.paprikarecipe")

        #expect(batch.problems.isEmpty)
        let imported = try #require(batch.recipes.first)
        let recipe = imported.recipe

        #expect(recipe.id == UUID(uuidString: "8C1E4B9A-2F3D-4E5A-9B6C-7D8E9F0A1B2C"))
        #expect(recipe.title == "Gulasch")
        #expect(recipe.summary == "Braucht Zeit, sonst nichts.")
        #expect(recipe.servings == 4)
        // Windows line endings from Paprika's web app are gone.
        #expect(recipe.ingredientsText == "1 kg Rindfleisch\n500 g Zwiebeln\n2 EL Paprikapulver")
        #expect(recipe.ingredients.count == 3)
        #expect(recipe.steps.count == 2)
        #expect(recipe.categories == ["Hauptgericht", "Fleisch"])
        #expect(recipe.isFavorite)
        #expect(recipe.notes == "Am nächsten Tag besser.")
        #expect(recipe.prepTimeSeconds == 1200)
        #expect(recipe.cookTimeSeconds == 5400)
        #expect(recipe.totalTimeSeconds == nil)
        // A source without a link is a book or a person, not a site.
        #expect(recipe.source.kind == .manual)
        #expect(recipe.source.name == "Omas Kochbuch")
        // The main photo, then the one attached to the directions.
        #expect(imported.images.count == 2)

        var components = DateComponents()
        components.year = 2021
        components.month = 11
        components.day = 3
        components.hour = 18
        components.minute = 20
        #expect(recipe.createdAt == Calendar.current.date(from: components))
    }

    @Test("Paprika's nutrition reading is dropped, not parked in notes")
    func nutritionIsIgnored() throws {
        let batch = try PaprikaImport.read(fixture("Gulasch.paprikarecipe"), named: "x.paprikarecipe")
        let notes = try #require(batch.recipes.first?.recipe.notes)

        #expect(!notes.contains("kcal"))
    }

    @Test("An archive yields every recipe in it and reports the ones it cannot read")
    func archive() throws {
        let batch = try PaprikaImport.read(
            fixture("library.paprikarecipes"), named: "library.paprikarecipes"
        )

        #expect(batch.recipes.map(\.recipe.title).sorted() == ["Gulasch", "Gurkensalat"])
        #expect(batch.problems.map(\.name) == ["kaputt.paprikarecipe"])

        let salad = try #require(batch.recipes.first { $0.recipe.title == "Gurkensalat" })
        #expect(salad.recipe.source.kind == .web)
        #expect(salad.recipe.source.url?.absoluteString == "https://example.com/gurkensalat")
        #expect(salad.recipe.source.name == "example.com")
        #expect(salad.recipe.prepTimeSeconds == 600)
        #expect(salad.recipe.cookTimeSeconds == nil)
        // No yield written: the usual default rather than a guess.
        #expect(salad.recipe.servings == 2)
        #expect(salad.images.isEmpty)
        #expect(!salad.recipe.isFavorite)
    }

    @Test("Importing the same export twice gives the same recipes, not second copies")
    func stableIdentity() throws {
        let data = try fixture("library.paprikarecipes")
        let first = try PaprikaImport.read(data, named: "a.paprikarecipes").recipes.map(\.recipe.id)
        let second = try PaprikaImport.read(data, named: "b.paprikarecipes").recipes.map(\.recipe.id)

        #expect(first == second)
    }

    @Test("A recipe file someone already unpacked still reads")
    func uncompressed() throws {
        let data = Data(#"{"uid": "x", "name": "Eins", "ingredients": "Salz"}"#.utf8)
        let batch = try PaprikaImport.read(data, named: "eins.paprikarecipe")

        #expect(batch.recipes.map(\.recipe.title) == ["Eins"])
    }

    @Test("A recipe without a name is reported, not stored")
    func untitled() throws {
        let data = Data(#"{"uid": "x", "name": " "}"#.utf8)
        let batch = try PaprikaImport.read(data, named: "leer.paprikarecipe")

        #expect(batch.recipes.isEmpty)
        #expect(batch.problems.count == 1)
    }

    @Test("Something that is not a recipe file at all is refused")
    func notARecipeFile() {
        #expect(throws: RecipeImportError.self) {
            try PaprikaImport.read(Data("nicht einmal JSON".utf8), named: "x.paprikarecipe")
        }
    }

    @Test("Paprika's extensions are routed to it")
    func routing() throws {
        let data = try fixture("library.paprikarecipes")
        #expect(try RecipeImport.read(data, named: "Export.paprikarecipes").recipes.count == 2)
    }
}

@Suite("Gzip reading")
struct GZipTests {
    @Test("A gzip stream with a file name in its header decompresses")
    func withFileName() throws {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/Gulasch.paprikarecipe", withExtension: nil)
        )
        let data = try Data(contentsOf: url)

        #expect(GZip.isCompressed(data))
        let json = try #require(GZip.decompress(data))
        #expect(String(data: json, encoding: .utf8)?.contains("Rindfleisch") == true)
    }

    @Test("Truncated or foreign data is refused")
    func refusesGarbage() {
        #expect(GZip.decompress(Data([0x1F, 0x8B, 0x08, 0x00])) == nil)
        #expect(GZip.decompress(Data("{}".utf8)) == nil)
        #expect(!GZip.isCompressed(Data("{}".utf8)))
    }
}

@MainActor
@Suite("Importing Paprika into the library")
struct PaprikaImportLibraryTests {
    @Test("An export lands in the library with its pictures attached")
    func importsIntoLibrary() async throws {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let images = SwiftDataRecipeImageStore(modelContainer: container)
        let library = RecipeLibrary(
            store: SwiftDataRecipeStore(modelContainer: container),
            imageStore: images,
            enrichmentStore: SwiftDataRecipeEnrichmentStore(modelContainer: container)
        )
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/library.paprikarecipes", withExtension: nil)
        )

        let summary = await library.importRecipes(
            from: try Data(contentsOf: url), named: "library.paprikarecipes"
        )

        #expect(summary.imported == 2)
        #expect(summary.problems.count == 1)
        let goulash = try #require(library.recipes.first { $0.title == "Gulasch" })
        #expect(goulash.imageIDs.count == 2)
        #expect(try await images.thumbnails(for: goulash.id).count == 2)
    }
}
