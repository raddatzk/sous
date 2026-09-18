import Foundation
import SwiftData
import Testing
@testable import SousKit

@Suite("schema.org file import")
struct JSONLDImportTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
        )
        return try Data(contentsOf: url)
    }

    @Test("A single recipe file reads like the page it could have come from")
    func singleRecipe() throws {
        let data = Data("""
        {"@context":"https://schema.org","@type":"Recipe",
         "name":"Linsensuppe","description":"Wärmt.","url":"https://example.com/linsensuppe",
         "recipeYield":"4 Portionen","prepTime":"PT20M","cookTime":"PT40M",
         "recipeIngredient":["250 g Linsen","1 Zwiebel"],
         "recipeInstructions":["Linsen waschen.","Alles kochen."],
         "recipeCategory":"Suppe","datePublished":"2023-05-02"}
        """.utf8)

        let batch = try JSONLDImport.read(data, named: "linsensuppe.json")
        let recipe = try #require(batch.recipes.first?.recipe)

        #expect(batch.recipes.count == 1)
        #expect(recipe.title == "Linsensuppe")
        #expect(recipe.summary == "Wärmt.")
        #expect(recipe.servings == 4)
        #expect(recipe.prepTimeSeconds == 1200)
        #expect(recipe.cookTimeSeconds == 2400)
        #expect(recipe.ingredients.count == 2)
        #expect(recipe.steps.count == 2)
        #expect(recipe.categories == ["Suppe"])
        #expect(recipe.source.kind == .web)
        #expect(recipe.source.url?.host() == "example.com")

        var components = DateComponents()
        components.year = 2023
        components.month = 5
        components.day = 2
        #expect(Calendar.current.dateComponents([.year, .month, .day], from: recipe.createdAt)
            == components)
    }

    @Test("A recipe without an address of its own is the cook's, not a site's")
    func noURL() throws {
        let data = Data(#"{"@type":"Recipe","name":"Omas Kuchen","recipeIngredient":["Mehl"]}"#.utf8)
        let recipe = try #require(try JSONLDImport.read(data, named: "a.json").recipes.first?.recipe)

        #expect(recipe.source.kind == .manual)
        #expect(recipe.source.url == nil)
    }

    @Test("A file holding several recipes, in a list or a graph, reads as all of them")
    func collection() throws {
        let list = Data("""
        [{"@type":"Recipe","name":"Eins"},{"@type":"Recipe","name":"Zwei"}]
        """.utf8)
        let graph = Data("""
        {"@context":"https://schema.org","@graph":[
          {"@type":"WebPage","name":"Sammlung"},
          {"@type":["Recipe","Thing"],"name":"Drei"},
          {"@type":"Recipe","name":"Vier"}]}
        """.utf8)

        #expect(try JSONLDImport.read(list, named: "a.json").recipes.map(\.recipe.title)
            == ["Eins", "Zwei"])
        #expect(try JSONLDImport.read(graph, named: "b.jsonld").recipes.map(\.recipe.title)
            == ["Drei", "Vier"])
    }

    @Test("A picture carried in the file as a data URI comes along")
    func embeddedImage() throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC"
        let data = Data("""
        {"@type":"Recipe","name":"Bild","image":"data:image/png;base64,\(png)"}
        """.utf8)
        let imported = try #require(try JSONLDImport.read(data, named: "a.json").recipes.first)

        #expect(imported.images == [try #require(Data(base64Encoded: png))])
    }

    @Test("A picture that is only a web address is not fetched")
    func remoteImage() throws {
        let data = Data(#"{"@type":"Recipe","name":"Fern","image":"https://example.com/a.jpg"}"#.utf8)
        let imported = try #require(try JSONLDImport.read(data, named: "a.json").recipes.first)

        #expect(imported.images.isEmpty)
    }

    @Test("Any JSON without a recipe in it is refused, not imported as nothing")
    func notARecipe() {
        #expect(throws: RecipeImportError.self) {
            try JSONLDImport.read(Data(#"{"name":"Einkaufsliste"}"#.utf8), named: "a.json")
        }
        #expect(throws: RecipeImportError.self) {
            try JSONLDImport.read(Data("kein JSON".utf8), named: "a.json")
        }
    }

    @Test("Importing the same file twice gives the same recipe, not a second one")
    func stableIdentity() throws {
        let withURL = Data(#"{"@type":"Recipe","name":"A","url":"https://example.com/a"}"#.utf8)
        let bare = Data(#"{"@type":"Recipe","name":"B","recipeIngredient":["Mehl"]}"#.utf8)
        let other = Data(#"{"@type":"Recipe","name":"B","recipeIngredient":["Reis"]}"#.utf8)

        func id(_ data: Data) throws -> UUID? {
            try JSONLDImport.read(data, named: "x.json").recipes.first?.recipe.id
        }
        #expect(try id(withURL) == id(withURL))
        #expect(try id(bare) == id(bare))
        // Same title, different recipe: kept apart.
        #expect(try id(bare) != id(other))
    }

    @Test("A packed-up cookbook folder yields its recipes with their photos")
    func cookbookArchive() throws {
        let batch = try JSONLDImport.read(fixture("cookbook.zip"), named: "cookbook.zip")

        #expect(batch.recipes.map(\.recipe.title).sorted() == ["Linsensuppe", "Pfannkuchen"])
        // The settings file beside the recipes is not one of them.
        #expect(batch.problems.map(\.name) == ["Einstellungen.json"])

        let png = try fixture("Tomatensalat.melarecipe")
        let expected = try #require(
            (try JSONSerialization.jsonObject(with: png) as? [String: Any])?["images"] as? [String]
        ).first.flatMap { Data(base64Encoded: $0) }

        // Nextcloud Cookbook's layout: the full-size photo, not the thumbnail.
        let soup = try #require(batch.recipes.first { $0.recipe.title == "Linsensuppe" })
        #expect(soup.images == [expected].compactMap { $0 })
        #expect(soup.recipe.categories == ["Suppe", "Winter", "Vegan"])
        #expect(soup.recipe.servings == 4)

        // A flat folder: the picture named like the recipe file, nothing else.
        let pancakes = try #require(batch.recipes.first { $0.recipe.title == "Pfannkuchen" })
        #expect(pancakes.images == [expected].compactMap { $0 })
        #expect(pancakes.recipe.servings == 8)
        #expect(pancakes.recipe.steps.count == 2)
    }

    @Test("An archive with no recipe files is reported")
    func emptyArchive() throws {
        let batch = try JSONLDImport.read(fixture("library.melarecipes"), named: "falsch.zip")

        #expect(batch.recipes.isEmpty)
        #expect(batch.problems.count == 1)
    }

    @Test("JSON files and zips are routed to it")
    func routing() throws {
        let data = Data(#"{"@type":"Recipe","name":"Eins"}"#.utf8)
        #expect(try RecipeImport.read(data, named: "a.json").recipes.count == 1)
        #expect(try RecipeImport.read(data, named: "a.JSONLD").recipes.count == 1)
        #expect(try RecipeImport.read(fixture("cookbook.zip"), named: "c.zip").recipes.count == 2)
    }
}
