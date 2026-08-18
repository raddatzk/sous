import Foundation
import Testing
@testable import SousKit

@Suite("Reading a recipe off a page")
struct RecipeWebImportTests {
    private let url = URL(string: "https://example.com/rezepte/linsensuppe")!

    private func page(_ jsonLD: String, extra: String = "") -> String {
        """
        <!DOCTYPE html><html><head><title>Egal</title>
        \(extra)
        <script type="application/ld+json">\(jsonLD)</script>
        </head><body><p>Werbung, Lebensgeschichte, noch mehr Werbung.</p></body></html>
        """
    }

    @Test("A plain schema.org recipe comes across whole")
    func plainRecipe() throws {
        let html = page("""
        {"@context":"https://schema.org","@type":"Recipe",
         "name":"Linsensuppe","description":"Wärmt.",
         "recipeYield":"4 Portionen","prepTime":"PT20M","cookTime":"PT40M","totalTime":"PT1H",
         "recipeIngredient":["250 g Linsen","1 Zwiebel","2 EL Essig"],
         "recipeInstructions":["Linsen waschen.","Alles kochen."],
         "recipeCategory":"Suppe","recipeCuisine":"Deutsch",
         "image":"https://example.com/bild.jpg"}
        """)

        let found = try RecipeWebImport.extract(from: html, url: url)
        let recipe = found.recipe

        #expect(recipe.title == "Linsensuppe")
        #expect(recipe.summary == "Wärmt.")
        #expect(recipe.servings == 4)
        #expect(recipe.prepTimeSeconds == 1200)
        #expect(recipe.cookTimeSeconds == 2400)
        #expect(recipe.totalTimeSeconds == 3600)
        #expect(recipe.ingredients.count == 3)
        #expect(recipe.steps.count == 2)
        #expect(recipe.categories == ["Suppe", "Deutsch"])
        #expect(recipe.source.kind == .web)
        #expect(recipe.source.url == url)
        #expect(found.imageURLs.map(\.absoluteString) == ["https://example.com/bild.jpg"])
    }

    @Test("A recipe buried in an @graph is still found")
    func insideGraph() throws {
        let html = page("""
        {"@context":"https://schema.org","@graph":[
          {"@type":"WebSite","name":"Kochseite"},
          {"@type":"BreadcrumbList"},
          {"@type":["Recipe","NewsArticle"],"name":"Ofengemüse",
           "recipeIngredient":["1 kg Kartoffeln"],"recipeInstructions":"Backen."}]}
        """)

        let recipe = try RecipeWebImport.extract(from: html, url: url).recipe

        #expect(recipe.title == "Ofengemüse")
        #expect(recipe.ingredients.count == 1)
    }

    @Test("Steps in sections keep their headings")
    func sectionedInstructions() throws {
        let html = page("""
        {"@type":"Recipe","name":"Lasagne",
         "recipeInstructions":[
           {"@type":"HowToSection","name":"Soße",
            "itemListElement":[{"@type":"HowToStep","text":"Zwiebeln anbraten."},
                               {"@type":"HowToStep","text":"Tomaten dazu."}]},
           {"@type":"HowToSection","name":"Schichten",
            "itemListElement":[{"@type":"HowToStep","text":"Abwechselnd einfüllen."}]}]}
        """)

        let recipe = try RecipeWebImport.extract(from: html, url: url).recipe

        #expect(recipe.instructionsText == """
        # Soße
        Zwiebeln anbraten.
        Tomaten dazu.
        # Schichten
        Abwechselnd einfüllen.
        """)
        // Which the step parser reads back as two groups.
        #expect(recipe.stepGroups.map(\.group) == ["Soße", "Schichten"])
    }

    @Test("Markup and entities inside the data are taken out")
    func stripsMarkup() throws {
        let html = page("""
        {"@type":"Recipe","name":"Kr&auml;utersalat",
         "description":"<p>Mit Salz &amp; Pfeffer.</p>",
         "recipeInstructions":"<p>Waschen.</p><p>Schneiden.</p>"}
        """)

        let recipe = try RecipeWebImport.extract(from: html, url: url).recipe

        #expect(recipe.title == "Kräutersalat")
        #expect(recipe.summary == "Mit Salz & Pfeffer.")
        #expect(recipe.steps.map(\.text) == ["Waschen.", "Schneiden."])
    }

    @Test("The odd shapes real sites use are read anyway")
    func awkwardShapes() throws {
        let html = page("""
        [{"@type":"Organization","name":"Verlag"},
         {"@type":"Recipe","name":"Pfannkuchen",
          "recipeYield":[12,"12 Stück"],
          "totalTime":"PT1H30M",
          "recipeIngredient":["3 Eier"],
          "recipeInstructions":[{"@type":"HowToStep","name":"Rühren"}],
          "keywords":"schnell, süß, Kinder",
          "image":{"@type":"ImageObject","url":"/bilder/pfannkuchen.jpg"}}]
        """)

        let found = try RecipeWebImport.extract(from: html, url: url)

        #expect(found.recipe.title == "Pfannkuchen")
        #expect(found.recipe.servings == 12)
        #expect(found.recipe.totalTimeSeconds == 5400)
        #expect(found.recipe.steps.map(\.text) == ["Rühren"])
        #expect(found.recipe.categories == ["schnell", "süß", "Kinder"])
        // A relative image URL is resolved against the page it came from.
        #expect(found.imageURLs.map(\.absoluteString) == ["https://example.com/bilder/pfannkuchen.jpg"])
    }

    @Test("A page without a recipe says so instead of inventing one")
    func noRecipe() {
        let html = page("""
        {"@context":"https://schema.org","@type":"Article","headline":"Zehn Tipps"}
        """)

        #expect(throws: RecipeWebImport.Failure.self) {
            try RecipeWebImport.extract(from: html, url: url)
        }
        #expect(throws: RecipeWebImport.Failure.self) {
            try RecipeWebImport.extract(from: "<html><body>nichts</body></html>", url: url)
        }
    }

    @Test("A second block is read when the first one is not a recipe")
    func multipleBlocks() throws {
        let html = """
        <html><head>
        <script type="application/ld+json">{"@type":"WebPage","name":"Seite"}</script>
        <script type='application/ld+json'>
          {"@type":"Recipe","name":"Grießbrei","recipeIngredient":["500 ml Milch"]}
        </script>
        </head></html>
        """

        #expect(try RecipeWebImport.extract(from: html, url: url).recipe.title == "Grießbrei")
    }
}
