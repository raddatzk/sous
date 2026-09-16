import Foundation
import Testing
@testable import SousKit

@Suite("Step chips from a pasted answer")
struct StepChipsTests {
    let recipe = Recipe(
        title: "Kartoffelcurry",
        servings: 4,
        ingredientsText: """
        500 g Kartoffeln
        2 EL Kokosöl
        300 ml Kokosmilch
        Salz
        """,
        instructionsText: """
        Kartoffeln würfeln.
        Öl erhitzen, Kartoffeln anbraten.
        Kokosmilch zugeben und mit Salz abschmecken.
        """
    )

    @Test("The prompt numbers lines and steps and asks for the JSON shape")
    func prompt() {
        let prompt = StepChipsPrompt.prompt(for: recipe)
        #expect(prompt.contains("Z1: 500 g Kartoffeln"))
        #expect(prompt.contains("Z4: Salz"))
        #expect(prompt.contains("S3: Kokosmilch zugeben und mit Salz abschmecken."))
        #expect(prompt.contains("Portionen: 4"))
        #expect(prompt.contains(#"{"schritte": [{"schritt": 1"#))
    }

    @Test("An answer is read out of a code fence and the words around it")
    func readsFencedAnswer() throws {
        let pasted = """
        Hier ist die Zuordnung:

        ```json
        {"schritte": [
          {"schritt": 1, "zutaten": [{"zeile": 1, "menge": "500 g"}]},
          {"schritt": 2, "zutaten": [{"zeile": 2, "menge": "2 EL"}]},
          {"schritt": 3, "zutaten": [{"zeile": 3, "menge": "300 ml"}, {"zeile": 4, "menge": ""}]}
        ]}
        ```
        """
        let reading = try StepChipsPrompt.read(pasted, for: recipe).get()
        #expect(reading.warnings.isEmpty)
        #expect(reading.chips.usesByStep.count == 3)
        #expect(reading.chips.usesByStep[1] == [StepChips.Use(line: 2, amount: "2 EL")])
        #expect(reading.chips.usesByStep[2][1] == StepChips.Use(line: 4, amount: nil))
    }

    @Test("A line the recipe does not have refuses the whole answer")
    func unknownLine() {
        let pasted = #"{"schritte": [{"schritt": 1, "zutaten": [{"zeile": 9, "menge": "1"}]}]}"#
        guard case .failure(let failure) = StepChipsPrompt.read(pasted, for: recipe) else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure == .unknownLine(step: 1, line: 9))
    }

    @Test("Text without an answer is refused")
    func noAnswer() {
        guard case .failure(let failure) = StepChipsPrompt.read("Leider kann ich das nicht.", for: recipe) else {
            Issue.record("expected a failure")
            return
        }
        #expect(failure == .noAnswer)
    }

    @Test("Handing out more than a line holds, and unreadable amounts, are warned about")
    func warnings() throws {
        let pasted = #"""
        {"schritte": [
          {"schritt": 1, "zutaten": [{"zeile": 1, "menge": "500 g"}]},
          {"schritt": 2, "zutaten": [{"zeile": 1, "menge": "250 g"}, {"zeile": 2, "menge": "etwas"}]}
        ]}
        """#
        let reading = try StepChipsPrompt.read(pasted, for: recipe).get()
        #expect(reading.warnings.contains(.overbooked(line: 1, percent: 150)))
        #expect(reading.warnings.contains(.unreadableAmount(step: 2, line: 2, amount: "etwas")))
    }

    @Test("Stored chips survive the column round trip")
    func roundTrip() throws {
        let chips = StepChips(fingerprint: "abc", usesByStep: [[StepChips.Use(line: 1, amount: "½ TL")], []])
        #expect(StepChips.decode(StepChips.encode(chips)) == chips)
        #expect(StepChips.encode(nil) == nil)
        #expect(StepChips.decode("kaputt") == nil)
    }

    @Test("Chips scale with the servings and go stale when the text changes")
    func chips() throws {
        let pasted = #"""
        {"schritte": [
          {"schritt": 1, "zutaten": [{"zeile": 1, "menge": "250 g"}]},
          {"schritt": 2, "zutaten": [{"zeile": 1, "menge": "250 g"}, {"zeile": 2, "menge": "2 EL"}]},
          {"schritt": 3, "zutaten": [{"zeile": 3, "menge": "300 ml"}, {"zeile": 4, "menge": ""}]}
        ]}
        """#
        let chips = try StepChipsPrompt.read(pasted, for: recipe).get().chips

        let doubled = try #require(chips.ingredientsByStep(of: recipe, scaledToServings: 8))[1]
        #expect(doubled.map(\.name) == ["Kartoffeln", "Kokosöl"])
        #expect(doubled[0].quantity == Quantity(500, .gram))
        #expect(doubled[1].quantity == Quantity(4, .tablespoon))

        let seasoning = try #require(chips.ingredientsByStep(of: recipe))[2]
        #expect(seasoning.map(\.name) == ["Kokosmilch", "Salz"])
        #expect(seasoning[1].quantity == nil)

        var retitled = recipe
        retitled.title = "Ala Hodi"
        #expect(chips.isCurrent(for: retitled))

        var edited = recipe
        edited.instructionsText += "\nServieren."
        #expect(!chips.isCurrent(for: edited))
        #expect(chips.ingredientsByStep(of: edited) == nil)
    }
}
