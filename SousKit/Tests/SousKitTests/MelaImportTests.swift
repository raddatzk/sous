import Foundation
import SwiftData
import Testing
@testable import SousKit

@Suite("Mela import")
struct MelaImportTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
        )
        return try Data(contentsOf: url)
    }

    @Test("A single recipe file carries over field by field")
    func singleRecipe() throws {
        let batch = try MelaImport.read(fixture("Tomatensalat.melarecipe"), named: "Tomatensalat.melarecipe")

        #expect(batch.problems.isEmpty)
        let imported = try #require(batch.recipes.first)
        let recipe = imported.recipe

        #expect(recipe.title == "Tomatensalat")
        #expect(recipe.summary == "Schnell, roh, gut.")
        #expect(recipe.servings == 4)
        #expect(recipe.categories == ["Salate", "Schnell"])
        #expect(recipe.isFavorite)
        #expect(!recipe.wantToCook)
        #expect(recipe.ingredients.count == 3)
        #expect(recipe.steps.count == 2)
        #expect(recipe.prepTimeSeconds == 900)
        // Mela's totalTime is a reading of its own, not cooking time.
        #expect(recipe.cookTimeSeconds == nil)
        #expect(recipe.totalTimeSeconds == 900)
        #expect(recipe.source.kind == .web)
        #expect(recipe.source.url?.host() == "example.com")
        #expect(imported.images.count == 1)
    }

    @Test("Nutrition is parked in the notes rather than dropped")
    func nutritionIsKept() throws {
        let batch = try MelaImport.read(fixture("Tomatensalat.melarecipe"), named: "x.melarecipe")
        let notes = try #require(batch.recipes.first?.recipe.notes)

        #expect(notes.contains("Mit Basilikum."))
        #expect(notes.contains("120 kcal"))
    }

    @Test("Importing the same file twice gives the same recipe, not a second one")
    func stableIdentity() throws {
        let data = try fixture("Tomatensalat.melarecipe")
        let first = try MelaImport.read(data, named: "a.melarecipe").recipes.first?.recipe.id
        let second = try MelaImport.read(data, named: "b.melarecipe").recipes.first?.recipe.id

        #expect(first == second)
    }

    @Test("An archive yields every recipe in it and reports the ones it cannot read")
    func archive() throws {
        let batch = try MelaImport.read(fixture("library.melarecipes"), named: "library.melarecipes")

        #expect(batch.recipes.count == 2)
        #expect(batch.problems.count == 1)
        #expect(batch.problems.first?.name == "kaputt.melarecipe")

        let curry = try #require(batch.recipes.first { $0.recipe.title == "Kichererbsencurry" })
        // Lists where Mela wrote lists, a comma-separated string where it
        // wrote one, and ISO-8601 durations from its own web import.
        #expect(curry.recipe.ingredientsText == "400 g Kichererbsen\n1 Dose Kokosmilch")
        #expect(curry.recipe.categories == ["Hauptgericht", "Vegan"])
        #expect(curry.recipe.servings == 2)
        #expect(curry.recipe.prepTimeSeconds == 1200)
        #expect(curry.recipe.cookTimeSeconds == 4200)
        #expect(curry.recipe.wantToCook)
        // A data-URI prefix is stripped before decoding.
        #expect(curry.images.first?.isEmpty == false)
    }

    @Test("Durations are read however Mela wrote them")
    func durations() {
        #expect(RecipeFieldParsing.seconds(in: "PT45M") == 2700)
        #expect(RecipeFieldParsing.seconds(in: "PT1H30M") == 5400)
        #expect(RecipeFieldParsing.seconds(in: "20 Minuten") == 1200)
        #expect(RecipeFieldParsing.seconds(in: "1 Stunde") == 3600)
        #expect(RecipeFieldParsing.seconds(in: "45 minutes") == 2700)
        #expect(RecipeFieldParsing.seconds(in: "2 hours") == 7200)
        #expect(RecipeFieldParsing.seconds(in: "30") == 1800)
        #expect(RecipeFieldParsing.seconds(in: "") == nil)
        #expect(RecipeFieldParsing.seconds(in: nil) == nil)
        #expect(RecipeFieldParsing.seconds(in: "ohne Angabe") == nil)
    }

    /// Every shape that actually turned up in an exported library of a few
    /// hundred recipes. The compound ones are why this adds up rather than
    /// taking the first number it finds.
    @Test("Compound durations add up instead of stopping at the first number")
    func compoundDurations() {
        #expect(RecipeFieldParsing.seconds(in: "40min") == 2400)
        #expect(RecipeFieldParsing.seconds(in: "1h 30min") == 5400)
        #expect(RecipeFieldParsing.seconds(in: "1h 5min") == 3900)
        #expect(RecipeFieldParsing.seconds(in: "2h 5min") == 7500)
        #expect(RecipeFieldParsing.seconds(in: "4h 45min") == 17100)
        #expect(RecipeFieldParsing.seconds(in: "5h 30min") == 19800)
        #expect(RecipeFieldParsing.seconds(in: "1h") == 3600)
        #expect(RecipeFieldParsing.seconds(in: "15 min") == 900)
        #expect(RecipeFieldParsing.seconds(in: "20 Min") == 1200)
        #expect(RecipeFieldParsing.seconds(in: "5 Minuten") == 300)
        #expect(RecipeFieldParsing.seconds(in: "95") == 5700)
        #expect(RecipeFieldParsing.seconds(in: "90 Sekunden") == 90)
    }

    @Test("A yield larger than a dinner party survives the import")
    func largeYield() {
        // A tray of biscuits is a reference amount like any other; clamping
        // it would rewrite what the ingredient amounts refer to.
        #expect(RecipeFieldParsing.servings(from: "62 Keks") == 62)
        #expect(RecipeFieldParsing.servings(from: "10 Stücke") == 10)
        #expect(RecipeFieldParsing.servings(from: "1 Kuchen") == 1)
        // Still bounded, so a stray number cannot claim a thousand portions.
        #expect(RecipeFieldParsing.servings(from: "999") == 200)
    }

    @Test("Servings come out of whatever the yield says")
    func servings() {
        #expect(RecipeFieldParsing.servings(from: "4 Portionen") == 4)
        #expect(RecipeFieldParsing.servings(from: "Für 6 Personen") == 6)
        #expect(RecipeFieldParsing.servings(from: "2") == 2)
        #expect(RecipeFieldParsing.servings(from: "ergibt 1 Blech") == 1)
        // Nothing to go on, and nothing worth guessing.
        #expect(RecipeFieldParsing.servings(from: "eine Schüssel") == 2)
        #expect(RecipeFieldParsing.servings(from: nil) == 2)
    }

    @Test("A recipe without a title is reported, not stored")
    func untitled() throws {
        let data = Data(#"{"title": "  ", "ingredients": "Salz"}"#.utf8)
        let batch = try MelaImport.read(data, named: "leer.melarecipe")

        #expect(batch.recipes.isEmpty)
        #expect(batch.problems.count == 1)
    }

    @Test("A file holding an array of recipes reads as all of them")
    func arrayOfRecipes() throws {
        let data = Data(#"[{"title": "Eins"}, {"title": "Zwei"}]"#.utf8)
        let batch = try MelaImport.read(data, named: "zwei.melarecipes")

        #expect(batch.recipes.map(\.recipe.title) == ["Eins", "Zwei"])
    }

    @Test("Something that is not a recipe file at all is refused")
    func notARecipeFile() {
        #expect(throws: RecipeImportError.self) {
            try MelaImport.read(Data("nicht einmal JSON".utf8), named: "x.melarecipe")
        }
    }

    @Test("Files are routed by their extension")
    func routing() throws {
        let data = Data(#"{"title": "Eins"}"#.utf8)
        #expect(try RecipeImport.read(data, named: "a.melarecipe").recipes.count == 1)
        // Sous's own extension is the same format under a different name.
        #expect(try RecipeImport.read(data, named: "a.sousrecipe").recipes.count == 1)
        #expect(try RecipeImport.read(data, named: "a.sousrecipes").recipes.count == 1)
        #expect(throws: RecipeImportError.self) {
            try RecipeImport.read(data, named: "a.paprikarecipes")
        }
    }
}

@Suite("ZIP reading")
struct ZIPArchiveTests {
    @Test("Entries come back with their names and contents")
    func entries() throws {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/library.melarecipes", withExtension: nil)
        )
        let entries = try ZIPArchive.entries(in: try Data(contentsOf: url))

        #expect(entries.map(\.name).sorted() == [
            "Kichererbsencurry.melarecipe", "Tomatensalat.melarecipe", "kaputt.melarecipe",
        ])
        let curry = try #require(entries.first { $0.name.hasPrefix("Kichererbsen") })
        #expect(String(data: curry.data, encoding: .utf8)?.contains("Kokosmilch") == true)
    }

    @Test("Anything that is not an archive is refused")
    func notAnArchive() {
        #expect(!ZIPArchive.looksLikeArchive(Data("{}".utf8)))
        #expect(throws: (any Error).self) {
            try ZIPArchive.entries(in: Data("{}".utf8))
        }
    }
}

@MainActor
@Suite("Importing into the library")
struct RecipeImportLibraryTests {
    private func makeLibrary() throws -> (RecipeLibrary, SwiftDataRecipeImageStore) {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let images = SwiftDataRecipeImageStore(modelContainer: container)
        let library = RecipeLibrary(
            store: SwiftDataRecipeStore(modelContainer: container),
            imageStore: images,
            enrichmentStore: SwiftDataRecipeEnrichmentStore(modelContainer: container)
        )
        return (library, images)
    }

    private func archive() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/library.melarecipes", withExtension: nil)
        )
        return try Data(contentsOf: url)
    }

    @Test("An archive lands in the library with its pictures attached")
    func importsIntoLibrary() async throws {
        let (library, images) = try makeLibrary()

        let summary = await library.importRecipes(from: try archive(), named: "library.melarecipes")

        #expect(summary.imported == 2)
        #expect(summary.problems.count == 1)
        #expect(library.recipes.map(\.title).sorted() == ["Kichererbsencurry", "Tomatensalat"])
        #expect(library.categories.contains("Salate"))

        let salad = try #require(library.recipes.first { $0.title == "Tomatensalat" })
        #expect(salad.imageIDs.count == 1)
        let stored = try await images.thumbnails(for: salad.id)
        #expect(stored.count == 1)

        // The progress indicator is only there while it runs.
        #expect(library.importProgress == nil)
    }

    @Test("Importing the same library twice updates it instead of doubling it")
    func reimportIsIdempotent() async throws {
        let (library, images) = try makeLibrary()
        let data = try archive()

        _ = await library.importRecipes(from: data, named: "library.melarecipes")
        _ = await library.importRecipes(from: data, named: "library.melarecipes")

        #expect(library.recipes.count == 2)
        let salad = try #require(library.recipes.first { $0.title == "Tomatensalat" })
        // And the picture is replaced rather than piling up beside the old one.
        #expect(salad.imageIDs.count == 1)
        #expect(try await images.thumbnails(for: salad.id).count == 1)
    }

    @Test("A file that is not a recipe file is reported, not thrown away silently")
    func unreadableFile() async throws {
        let (library, _) = try makeLibrary()

        let summary = await library.importRecipes(from: Data("nope".utf8), named: "notizen.txt")

        #expect(summary.imported == 0)
        #expect(summary.problems.count == 1)
        #expect(library.errorMessage != nil)
    }
}
