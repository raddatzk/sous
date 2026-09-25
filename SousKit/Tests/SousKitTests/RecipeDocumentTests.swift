import Foundation
import Testing
@testable import SousKit

@Suite("Recipe document, Markdown and printed page")
struct RecipeDocumentTests {
    private var zwiebelkuchen: Recipe {
        Recipe(
            title: "Zwiebelkuchen",
            summary: "Im Herbst, mit *Federweißer*.",
            servings: 12,
            ingredientsText: "1 kg Zwiebeln\n200 g Speck\n# Für den Teig\n500 g Mehl",
            instructionsText: "# Belag\nZwiebeln **schneiden**.\nSpeck auslassen.\n# Teig\nTeig ausrollen.",
            categories: ["Herbst", "Kuchen"],
            notes: "Blech gut fetten.",
            source: RecipeSource(kind: .web, url: URL(string: "https://example.com/z"), name: "example.com")
        )
    }

    private var pfannkuchen: Recipe {
        Recipe(
            title: "Pfannkuchen",
            summary: "Sonntags.",
            servings: 2,
            ingredientsText: "200 g Mehl\n2 Eier",
            instructionsText: "Alles verrühren.\nIn der Pfanne backen.",
            categories: ["Frühstück"],
            notes: "Mit Apfelmus.",
            source: RecipeSource(kind: .web, url: URL(string: "https://example.com/p"), name: "example.com"),
            prepTimeSeconds: 10 * 60,
            cookTimeSeconds: 20 * 60
        )
    }

    @Test("Amounts are scaled to the serving count asked for, group by group")
    func scaled() {
        let document = RecipeDocument(zwiebelkuchen, servings: 6)

        #expect(document.servings == 6)
        #expect(document.ingredientGroups.map(\.name) == [nil, "Für den Teig"])
        #expect(document.ingredientGroups[0].lines == [
            .init(amount: "500 g", text: "Zwiebeln"),
            .init(amount: "100 g", text: "Speck"),
        ])
        #expect(document.ingredientGroups[1].lines == [.init(amount: "250 g", text: "Mehl")])
    }

    @Test("Steps are counted within their group and read without markdown marks")
    func steps() {
        let document = RecipeDocument(zwiebelkuchen)

        #expect(document.stepGroups.map(\.name) == ["Belag", "Teig"])
        #expect(document.stepGroups[0].steps.map(\.number) == [1, 2])
        #expect(document.stepGroups[1].steps.map(\.number) == [1])
        #expect(document.stepGroups[0].steps[0].text == "Zwiebeln schneiden.")
        #expect(document.summary == "Im Herbst, mit Federweißer.")
    }

    @Test("A link into the app leaves only its words behind")
    func linksReadOut() {
        let recipe = Recipe(
            title: "Curry",
            ingredientsText: "2 [Naan](sous://recipe/\(UUID().uuidString))"
        )
        let line = RecipeDocument(recipe).ingredientGroups[0].lines[0]
        #expect(line.amount == "2")
        #expect(line.text == "Naan")
    }

    @Test("Nothing written means nothing claimed: no notes, no source")
    func empty() {
        let document = RecipeDocument(Recipe(title: "Leer", notes: "  \n"))
        #expect(document.notes == nil)
        #expect(document.source == nil)
        #expect(document.nutrition == nil)
        #expect(document.factsLine == "2 Portionen")
    }

    @Test("The Markdown file reads as a recipe")
    func markdown() {
        let markdown = RecipeMarkdown.string(for: RecipeDocument(pfannkuchen))
        #expect(markdown == """
        # Pfannkuchen

        Sonntags.

        *Frühstück*

        2 Portionen · Vorbereitung 10 Min · Zubereitung 20 Min · Gesamt 30 Min

        ## Zutaten

        - 200 g Mehl
        - 2 Eier

        ## Zubereitung

        1. Alles verrühren.
        2. In der Pfanne backen.

        ## Notizen

        Mit Apfelmus.

        Quelle: [example.com](https://example.com/p)

        """)
    }

    @Test("Group headings sit below the section they belong to")
    func markdownGroups() {
        let markdown = RecipeMarkdown.string(for: RecipeDocument(zwiebelkuchen))
        #expect(markdown.contains("## Zutaten\n\n- 1 kg Zwiebeln\n- 200 g Speck\n\n### Für den Teig\n\n- 500 g Mehl"))
        #expect(markdown.contains("## Zubereitung\n\n### Belag\n\n1. Zwiebeln schneiden.\n2. Speck auslassen.\n\n### Teig\n\n1. Teig ausrollen."))
    }

    @Test("Text that looks like Markdown stays text")
    func markdownEscaping() {
        #expect(RecipeMarkdown.inline("[Tipp] *nicht* umrühren") == "\\[Tipp\\] \\*nicht\\* umrühren")
        #expect(RecipeMarkdown.inline("# kein Titel") == "\\# kein Titel")
        #expect(RecipeMarkdown.inline("Salz & Pfeffer") == "Salz & Pfeffer")
    }

    @Test("The printed page carries every part, escaped")
    func html() {
        var recipe = zwiebelkuchen
        recipe.title = "Speck & <Zwiebeln>"
        let html = RecipeHTML.string(for: RecipeDocument(recipe, servings: 6))

        #expect(html.contains("<h1>Speck &amp; &lt;Zwiebeln&gt;</h1>"))
        #expect(html.contains("<span class=\"amount\">500 g</span><span class=\"text\">Zwiebeln</span>"))
        #expect(html.contains("<h3>Für den Teig</h3>"))
        #expect(html.contains("<dt>Portionen</dt><dd>6</dd>"))
        #expect(html.contains("<p class=\"kicker\">Herbst · Kuchen</p>"))
        #expect(html.contains("<div class=\"body columns\">"))
        #expect(html.contains("<div class=\"qr\"><svg"))
        #expect(html.contains("https://example.com/z"))
    }

    @Test("A resolved amount in a step is set apart on paper")
    func htmlStepAmounts() {
        let step = RecipeDocument.Step(number: 1, segments: [.text("Mit "), .amount("200 g"), .text(" Mehl <mischen>.")])
        var document = RecipeDocument(Recipe(title: "x", instructionsText: "Mischen."))
        document.stepGroups = [.init(name: nil, steps: [step])]

        #expect(RecipeHTML.string(for: document).contains("<p>Mit <b>200 g</b> Mehl &lt;mischen&gt;.</p>"))
        #expect(step.text == "Mit 200 g Mehl <mischen>.")
    }

    @Test("The recipe's own link gets a code of its own, beside the source's")
    func htmlAppLink() throws {
        let link = try #require(URL(string: "sous://recipe/\(UUID().uuidString)"))
        let html = RecipeHTML.string(for: RecipeDocument(zwiebelkuchen, appLink: link))
        let footer = try #require(html.range(of: "<footer>")).upperBound
        #expect(html[footer...].components(separatedBy: "class=\"qr\"").count - 1 == 2)
        #expect(html.contains("In der App öffnen"))

        let without = RecipeHTML.string(for: RecipeDocument(zwiebelkuchen))
        #expect(!without.contains("In der App öffnen"))
    }

    @Test("Without a source address there is no code to scan")
    func htmlWithoutURL() {
        let recipe = Recipe(title: "Omas Rotkohl", source: RecipeSource(kind: .manual, name: "Oma"))
        let html = RecipeHTML.string(for: RecipeDocument(recipe))
        #expect(!html.contains("class=\"qr\""))
        #expect(html.contains("<span class=\"name\">Oma</span>"))
        #expect(html.contains("<div class=\"body single\">"))
    }

    @Test("The QR code comes out the right way up")
    func qrOrientation() throws {
        let modules = try #require(QRCode.modules(for: "https://example.com/recipes/42"))
        let size = modules.count
        #expect(modules.allSatisfy { $0.count == size })

        // The quiet zone is as wide as the first dark module is far in.
        let quiet = try #require(modules.firstIndex { $0.contains(true) })
        func finderEdge(row: Int, from column: Int) -> Bool {
            (column..<column + 7).allSatisfy { modules[row][$0] }
        }
        let far = size - quiet - 7
        // Finder patterns at three corners — top left, top right, bottom
        // left — and none at the bottom right. Upside down, a phone may not
        // read it.
        #expect(finderEdge(row: quiet, from: quiet))
        #expect(finderEdge(row: quiet, from: far))
        #expect(finderEdge(row: size - quiet - 1, from: quiet))
        #expect(!finderEdge(row: size - quiet - 1, from: far))
    }

    @Test("Times are listed in the order they happen, with a total only where it adds something")
    func times() {
        #expect(RecipeTimes.items(for: pfannkuchen).map(\.label) == ["Vorbereitung", "Zubereitung", "Gesamt"])
        let onlyCooking = Recipe(title: "x", cookTimeSeconds: 90 * 60)
        #expect(RecipeTimes.items(for: onlyCooking).map(\.value) == ["1:30 Std"])
    }
}
