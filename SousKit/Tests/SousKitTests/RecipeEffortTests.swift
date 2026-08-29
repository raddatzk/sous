import Foundation
import Testing
@testable import SousKit

@Suite("How much work a recipe is")
struct RecipeEffortTests {
    private func recipe(
        _ title: String, ingredients: String, steps: String, servings: Int = 2
    ) -> Recipe {
        Recipe(
            title: title, servings: servings,
            ingredientsText: ingredients, instructionsText: steps
        )
    }

    @Test("A recipe with nothing to go on says nothing rather than 'simple'")
    func tooThinToJudge() {
        // What an import of prose looks like: one block, no headings, no
        // times. Every signal would read it as trivial, and it might be a
        // cassoulet.
        let blob = recipe(
            "Irgendwas",
            ingredients: "500 g Fleisch\n2 Zwiebeln\n1 Dose Bohnen",
            steps: "Alles zusammen lange schmoren, bis es gut ist."
        )
        #expect(blob.effort() == nil)
    }

    @Test("Steps and ingredients are the ground floor")
    func sizeAlone() throws {
        let salad = recipe(
            "Salat",
            ingredients: "2 Tomaten\n1 Gurke",
            steps: "Tomaten schneiden.\nGurke schneiden.\nAnrichten."
        )
        let effort = try #require(salad.effort())
        // 3 steps + 2 ingredients: 3 * 1.0 + 2 * 0.3
        #expect(abs(effort.score - 3.6) < 0.001)
        #expect(effort.level == .simple)
    }

    @Test("A second component costs more than the steps it adds")
    func componentsWeighHeavy() throws {
        let flat = recipe(
            "Auflauf ohne Gliederung",
            ingredients: "300 g Mehl\n200 ml Milch\n2 Eier\n400 g Spinat",
            steps: "Teig rühren.\nSpinat dünsten.\nSchichten.\nBacken."
        )
        let grouped = recipe(
            "Auflauf mit Gliederung",
            ingredients: """
            # Für den Teig
            300 g Mehl
            200 ml Milch
            2 Eier
            # Für die Füllung
            400 g Spinat
            """,
            steps: "Teig rühren.\nSpinat dünsten.\nSchichten.\nBacken."
        )
        let flatEffort = try #require(flat.effort())
        let groupedEffort = try #require(grouped.effort())

        // Same steps, same ingredients — what differs is that the second one
        // is two things to keep going at once.
        #expect(groupedEffort.score > flatEffort.score)
        #expect(abs((groupedEffort.score - flatEffort.score) - 3.0) < 0.001)
    }

    @Test("A duration that is not the last step means something is running")
    func interleavingCounts() throws {
        let sequential = recipe(
            "Nacheinander",
            ingredients: "200 g Reis",
            steps: "Reis waschen.\nReis 20 Minuten kochen."
        )
        let interleaved = recipe(
            "Gleichzeitig",
            ingredients: "200 g Reis",
            steps: "Reis 20 Minuten kochen.\nWährenddessen die Soße rühren."
        )
        let sequentialEffort = try #require(sequential.effort())
        let interleavedEffort = try #require(interleaved.effort())

        // Same two steps and the same one ingredient. The difference is
        // where the clock sits: at the end it is waiting, in the middle it
        // is a second thing to watch.
        #expect(interleavedEffort.score > sequentialEffort.score)
        #expect(
            interleavedEffort.contributions.first { $0.signal == .interleaving }?.count == 1
        )
        #expect(sequentialEffort.contributions.contains { $0.signal == .interleaving } == false)
    }

    @Test("Prepared ingredients are small jobs of their own")
    func preparationsCount() throws {
        let plain = recipe(
            "Schlicht", ingredients: "2 Zwiebeln\n3 Karotten",
            steps: "In den Topf.\n30 Minuten kochen."
        )
        let prepped = recipe(
            "Vorbereitet", ingredients: "2 Zwiebeln, fein gehackt\n3 Karotten, gewürfelt",
            steps: "In den Topf.\n30 Minuten kochen."
        )
        let plainEffort = try #require(plain.effort())
        let preppedEffort = try #require(prepped.effort())
        #expect(abs((preppedEffort.score - plainEffort.score) - 1.0) < 0.001)
    }

    @Test("A linked recipe brings its work along, at half weight")
    func subRecipesCountHalf() throws {
        let naan = recipe(
            "Naan",
            ingredients: "300 g Mehl\n7 g Hefe\n150 ml Wasser",
            steps: "Teig kneten.\nTeig 60 Minuten gehen lassen.\nFladen ausrollen.\nBacken."
        )
        let naanEffort = try #require(naan.effort())

        let curry = recipe(
            "Curry",
            ingredients: "400 ml Kokosmilch\n2 Portionen \(RecipeLink.markdown(title: "Naan", id: naan.id))",
            steps: "Alles köcheln.\n20 Minuten ziehen lassen."
        )
        let alone = try #require(curry.effort())
        let withNaan = try #require(curry.effort { $0 == naan.id ? naan : nil })

        #expect(withNaan.score > alone.score)
        #expect(abs((withNaan.score - alone.score) - naanEffort.score * 0.5) < 0.001)
        #expect(withNaan.contributions.first { $0.signal == .subRecipes }?.count == 1)
    }

    @Test("A recipe that links itself does not count forever")
    func linkCyclesTerminate() throws {
        var loop = recipe("Rundlauf", ingredients: "1 Ei", steps: "Rühren.\n5 Minuten ruhen.")
        loop.ingredientsText += "\n1 Portion \(RecipeLink.markdown(title: "Rundlauf", id: loop.id))"
        // Resolving it to itself must terminate rather than recurse until the
        // stack gives out.
        let effort = try #require(loop.effort { $0 == loop.id ? loop : nil })
        #expect(effort.score > 0)
    }

    @Test("Typing a rung offers it as a filter")
    func rungsAreOfferable() {
        // Effort is not a word that appears anywhere in a recipe, so unless
        // the filter row offers it there is no way to reach it at all.
        let offered = RecipeFilter.suggestions(
            for: "aufwend", catalog: .bundled, categories: []
        )
        #expect(offered.contains { $0.effort == .involved })
    }

    @Test("A cook's word beats the structure, and can be taken back")
    func theOverrideWins() throws {
        var croissant = recipe(
            "Croissants",
            ingredients: "500 g Mehl\n250 g Butter\n10 g Hefe\n300 ml Milch",
            steps: "Teig kneten.\n12 Stunden kühlen.\nTourieren.\nBacken."
        )
        // Structurally modest, and the cook knows better.
        let computed = try #require(croissant.effort())
        #expect(computed.level != .involved)

        croissant.effortOverride = .involved
        #expect(croissant.effortOverride == .involved)
        // The computation is untouched by the override: it is still what the
        // structure says, and the two are different claims.
        #expect(croissant.effort()?.level == computed.level)
    }

    @Test("The rungs are ordered, whatever the thresholds end up being")
    func levelsAreMonotonic() {
        #expect(RecipeEffort.level(for: 0) == .simple)
        #expect(RecipeEffort.level(for: 100) == .involved)
        var seen: [RecipeEffort.Level] = []
        for score in stride(from: 0.0, through: 60.0, by: 0.5) {
            let level = RecipeEffort.level(for: score)
            if seen.last != level { seen.append(level) }
        }
        // Never back down a rung as the score climbs.
        #expect(seen == [.simple, .medium, .involved])
    }
}
