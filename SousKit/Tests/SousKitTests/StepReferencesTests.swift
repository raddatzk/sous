import Foundation
import Testing
@testable import SousKit

@Suite("Step references from a pasted answer")
struct StepReferencesTests {
    let recipe = Recipe(
        title: "Kuchen",
        servings: 4,
        ingredientsText: """
        # Teig
        200 g Mehl
        100 g Butter
        # Füllung
        200 g Butter
        Salz
        """,
        instructionsText: """
        200 g Mehl mit 100 g Butter verkneten, 300 ml Wasser zugeben und bei 180 °C backen.
        Die Hälfte der Butter schmelzen.
        Restliche Butter unterrühren und mit Salz abschmecken.
        """
    )

    let answer = #"""
    Hier die Bezüge:
    ```json
    {"schritte": [
      {"schritt": 1, "bezuege": [
        {"art": "menge", "stelle": "200 g", "vorkommen": 1, "zeile": 1, "menge": "200 g"},
        {"art": "menge", "stelle": "100 g", "vorkommen": 1, "zeile": 2, "menge": "100 g"},
        {"art": "menge", "stelle": "300 ml", "vorkommen": 1, "zeile": null, "menge": "300 ml"}
      ]},
      {"schritt": 2, "bezuege": [
        {"art": "bezug", "stelle": "Die Hälfte der Butter", "vorkommen": 1, "zeile": 3, "menge": "100 g"}
      ]},
      {"schritt": 3, "bezuege": [
        {"art": "bezug", "stelle": "Restliche Butter", "vorkommen": 1, "zeile": 3, "menge": "100 g"},
        {"art": "bezug", "stelle": "", "vorkommen": 1, "zeile": 4, "menge": ""}
      ]}
    ]}
    ```
    """#

    @Test("The prompt numbers lines and steps and asks for the reference shape")
    func prompt() {
        let prompt = StepReferencesPrompt.prompt(for: recipe)
        #expect(prompt.contains("Z3: 200 g Butter"))
        #expect(prompt.contains("[Füllung]"))
        #expect(prompt.contains("S2: Die Hälfte der Butter schmelzen."))
        #expect(prompt.contains(#""bezuege""#))
    }

    @Test("An answer is read out of a code fence and the words around it")
    func reads() throws {
        let reading = try StepReferencesPrompt.read(answer, for: recipe).get()
        #expect(reading.warnings.isEmpty)
        #expect(reading.references.steps.count == 3)
        #expect(reading.references.steps[0][2] == .init(kind: .amount, text: "300 ml", line: nil, amount: "300 ml"))
        #expect(reading.references.steps[2][1] == .init(kind: .mention, text: "", line: 4, amount: nil))
    }

    @Test("Written amounts scale in place, other numbers stay, mentions become chips")
    func rendition() throws {
        var withReferences = recipe
        withReferences.stepReferences = try StepReferencesPrompt.read(answer, for: recipe).get().references
        let steps = withReferences.steps
        let doubled = withReferences.stepRendition(toServings: 8, formatter: QuantityFormatter(locale: Locale(identifier: "de_DE")))

        #expect(doubled.segments(for: steps[0]) == [
            .amount("400 g"), .text(" Mehl mit "), .amount("200 g"), .text(" Butter verkneten, "),
            .amount("600 ml"), .text(" Wasser zugeben und bei 180 °C backen."),
        ])
        #expect(doubled.ingredients(for: steps[0]).isEmpty)
        #expect(doubled.marks(for: steps[0]).map(\.kind) == [.bound, .bound, .loose])

        let melted = doubled.ingredients(for: steps[1])
        #expect(melted.map(\.name) == ["Butter"])
        #expect(melted.first?.group == "Füllung")
        #expect(melted.first?.quantity == Quantity(200, .gram))
        #expect(doubled.segments(for: steps[1]) == [.text("Die Hälfte der Butter schmelzen.")])

        #expect(doubled.ingredients(for: steps[2]).map(\.name) == ["Butter", "Salz"])
    }

    @Test("Amounts per piece stay as written; a span scales at both ends")
    func perPieceAndSpans() throws {
        let schnitzel = Recipe(
            title: "Schnitzel",
            servings: 2,
            ingredientsText: "2 TL Salz\n4 EL Saft",
            instructionsText: "Schnitzel je mit ¼ TL Salz würzen und mit 3-4 EL Saft beträufeln."
        )
        var withReferences = schnitzel
        withReferences.stepReferences = try StepReferencesPrompt.read(#"""
        {"schritte": [{"schritt": 1, "bezuege": [
          {"art": "menge", "stelle": "¼ TL", "zeile": 1, "menge": "½ TL"},
          {"art": "menge", "stelle": "3-4 EL", "zeile": 2, "menge": "4 EL"}
        ]}]}
        """#, for: schnitzel).get().references
        let step = withReferences.steps[0]
        let doubled = withReferences.stepRendition(toServings: 4, formatter: QuantityFormatter(locale: Locale(identifier: "de_DE")))
        #expect(doubled.segments(for: step) == [
            .text("Schnitzel je mit "), .amount("¼ TL"), .text(" Salz würzen und mit "), .amount("6–8 EL"), .text(" Saft beträufeln."),
        ])
    }

    @Test("Amounts in words, approximate amounts, and units that do not compare")
    func looseQuotes() throws {
        let dough = Recipe(
            title: "Teig",
            servings: 2,
            ingredientsText: "2 große Kartoffeln\n1 Prise Salz\n2 Eier",
            instructionsText: "Mit den übrigen Zutaten und etwa 400 g Kartoffeln mischen, Zwei Eier und einer Prise Salz zugeben."
        )
        let reading = try StepReferencesPrompt.read(#"""
        {"schritte": [{"schritt": 1, "bezuege": [
          {"art": "bezug", "stelle": "die übrigen Zutaten", "zeile": 2, "menge": ""},
          {"art": "bezug", "stelle": "Kartoffeln", "zeile": 1, "menge": "400 g"},
          {"art": "menge", "stelle": "Zwei", "zeile": 3, "menge": "2"},
          {"art": "menge", "stelle": "einer Prise", "zeile": 2, "menge": "1 Prise"}
        ]}]}
        """#, for: dough).get()
        #expect(reading.warnings.isEmpty)
        var withReferences = dough
        withReferences.stepReferences = reading.references
        let doubled = withReferences.stepRendition(toServings: 4, formatter: QuantityFormatter(locale: Locale(identifier: "de_DE")))
        let segments = doubled.segments(for: withReferences.steps[0])
        #expect(segments.contains(.amount("4")))
        #expect(segments.contains(.amount("2 Prisen")) || segments.contains(.amount("2 Prise")))
        // Only written amounts are marked; the mentions are chips.
        #expect(doubled.marks(for: withReferences.steps[0]).map(\.kind) == [.bound, .bound])
        #expect(doubled.ingredients(for: withReferences.steps[0]).map(\.name) == ["Kartoffeln"])
    }

    @Test("Edited by hand: chips added, changed and removed, written amounts moved or let go")
    func editing() throws {
        var references = try StepReferencesPrompt.read(answer, for: recipe).get().references
        references.setChip(line: 1, amount: "50 ", inStepAt: 1)
        references.setChip(line: 1, amount: "50 g", inStepAt: 1)
        references.setChip(line: 3, amount: "120 g", inStepAt: 1)
        references.removeChip(line: 4, fromStepAt: 2)
        references.setLine(3, forReferenceAt: 1, inStepAt: 0)
        references.removeReference(at: 2, inStepAt: 0)

        #expect(references.steps[1] == [
            .init(kind: .mention, text: "", line: 3, amount: "120 g"),
            .init(kind: .mention, text: "", line: 1, amount: "50 g"),
        ])
        #expect(references.steps[2].map(\.line) == [3])
        #expect(references.steps[0].map(\.line) == [1, 3])

        var edited = recipe
        edited.stepReferences = references
        let rendition = edited.stepRendition(formatter: QuantityFormatter(locale: Locale(identifier: "de_DE")))
        #expect(rendition.segments(for: edited.steps[0]).last == .text(" Butter verkneten, 300 ml Wasser zugeben und bei 180 °C backen."))
        #expect(!rendition.segments(for: edited.steps[0]).contains(.amount("300 ml")))
    }

    @Test("Assigned from scratch: empty references are current and show nothing yet")
    func fromScratch() {
        var references = StepReferences.empty(for: recipe)
        #expect(references.isCurrent(for: recipe))
        #expect(references.steps.count == 3)
        references.setChip(line: 4, amount: "", inStepAt: 2)
        var edited = recipe
        edited.stepReferences = references
        #expect(edited.stepRendition().ingredients(for: edited.steps[2]).map(\.name) == ["Salz"])
        #expect(StepReferencesPrompt.readsAsAmount("2 EL"))
        #expect(!StepReferencesPrompt.readsAsAmount("etwas"))
    }

    @Test("A bare count takes the line's unit")
    func bareCount() throws {
        let soup = Recipe(title: "Suppe", servings: 2, ingredientsText: "4 Zehen Knoblauch", instructionsText: "Knoblauch hacken.")
        var withReferences = soup
        withReferences.stepReferences = try StepReferencesPrompt.read(
            #"{"schritte": [{"schritt": 1, "bezuege": [{"art": "bezug", "zeile": 1, "menge": "4"}]}]}"#, for: soup
        ).get().references
        let chip = withReferences.stepRendition(toServings: 4).ingredients(for: withReferences.steps[0]).first
        #expect(chip?.quantity == Quantity(8, .clove))
    }

    @Test("Stale or missing references show the steps as written")
    func stale() throws {
        var edited = recipe
        edited.stepReferences = try StepReferencesPrompt.read(answer, for: recipe).get().references
        #expect(edited.stepRendition(toServings: 8).segments(for: edited.steps[0]).count > 1)

        var retitled = edited
        retitled.title = "Anderer Kuchen"
        #expect(retitled.stepReferences?.isCurrent(for: retitled) == true)

        edited.instructionsText += "\nServieren."
        let plain = edited.stepRendition(toServings: 8)
        #expect(plain.segments(for: edited.steps[0]) == [.text(edited.steps[0].text)])
        #expect(plain.ingredients(for: edited.steps[1]).isEmpty)
        #expect(recipe.stepRendition(toServings: 8).marks(for: recipe.steps[0]).isEmpty)
    }

    @Test("A line or step the recipe lacks refuses the answer; nothing to read is refused too")
    func refusals() {
        let unknownLine = #"{"schritte": [{"schritt": 1, "bezuege": [{"art": "bezug", "stelle": "Mehl", "zeile": 9, "menge": ""}]}]}"#
        guard case .failure(.unknownLine(step: 1, line: 9)) = StepReferencesPrompt.read(unknownLine, for: recipe) else {
            Issue.record("expected an unknown line")
            return
        }
        let unknownStep = #"{"schritte": [{"schritt": 7, "bezuege": []}]}"#
        guard case .failure(.unknownStep(7)) = StepReferencesPrompt.read(unknownStep, for: recipe) else {
            Issue.record("expected an unknown step")
            return
        }
        guard case .failure(.noAnswer) = StepReferencesPrompt.read("Leider nicht.", for: recipe) else {
            Issue.record("expected no answer")
            return
        }
    }

    @Test("Quotes the step lacks, unreadable amounts and overbooked lines are warned about")
    func warnings() throws {
        let pasted = #"""
        {"schritte": [
          {"schritt": 1, "bezuege": [
            {"art": "menge", "stelle": "250 g", "zeile": 1, "menge": "250 g"},
            {"art": "menge", "stelle": "200 g", "zeile": 1, "menge": "200 g"},
            {"art": "menge", "stelle": "mit", "zeile": 2, "menge": ""}
          ]},
          {"schritt": 2, "bezuege": [{"art": "bezug", "stelle": "Die Margarine", "zeile": 3, "menge": "100 g"}]}
        ]}
        """#
        let reading = try StepReferencesPrompt.read(pasted, for: recipe).get()
        #expect(reading.warnings.contains(.notInStep(step: 1, text: "250 g")))
        // A mention is a chip: its quote is not looked for, and not kept.
        #expect(!reading.warnings.contains(.notInStep(step: 2, text: "Die Margarine")))
        #expect(reading.warnings.contains(.unreadableAmount(step: 1, text: "mit")))
        // The unfound amount is dropped; the mention stays a chip, without words.
        #expect(reading.references.steps[0].map(\.text) == ["200 g", "mit"])
        #expect(reading.references.steps[1] == [.init(kind: .mention, text: "", line: 3, amount: "100 g")])

        // A chain — all of it prepared, shares handed out later — adds up
        // past the line by design and is not warned about.
        let chain = #"""
        {"schritte": [
          {"schritt": 1, "bezuege": [{"art": "bezug", "zeile": 3, "menge": "200 g"}]},
          {"schritt": 2, "bezuege": [{"art": "bezug", "zeile": 3, "menge": "100 g"}]},
          {"schritt": 3, "bezuege": [{"art": "bezug", "zeile": 3, "menge": "100 g"}]}
        ]}
        """#
        #expect(try StepReferencesPrompt.read(chain, for: recipe).get().warnings.isEmpty)

        // Amounts the text itself writes, beyond what the line holds, are.
        let written = #"""
        {"schritte": [{"schritt": 1, "bezuege": [
          {"art": "menge", "stelle": "200 g", "zeile": 2, "menge": "200 g"}
        ]}]}
        """#
        #expect(try StepReferencesPrompt.read(written, for: recipe).get().warnings == [.overbooked(line: 2, percent: 200)])
    }

    @Test("Two shares of one line in one step become one chip of the sum; notes are read")
    func mergeAndNotes() throws {
        let pasted = #"""
        {"schritte": [
          {"schritt": 2, "bezuege": [
            {"art": "bezug", "zeile": 3, "menge": "66,7 g"},
            {"art": "bezug", "zeile": 3, "menge": "133,3 g"},
            {"art": "bezug", "zeile": 4, "menge": ""},
            {"art": "bezug", "zeile": 4, "menge": ""}
          ]}
        ],
        "hinweise": ["Schritt 1 nennt 300 ml Wasser, das in der Liste fehlt.", " "]}
        """#
        let reading = try StepReferencesPrompt.read(pasted, for: recipe).get()
        #expect(reading.references.steps[1] == [
            .init(kind: .mention, text: "", line: 3, amount: "200 g"),
            .init(kind: .mention, text: "", line: 4, amount: nil),
        ])
        #expect(reading.notes == ["Schritt 1 nennt 300 ml Wasser, das in der Liste fehlt."])
    }

    @Test("Stored references survive the column round trip; the old chips shape reads as none")
    func roundTrip() {
        let references = StepReferences(fingerprint: "abc", steps: [[.init(kind: .amount, text: "½ TL", line: 1, amount: "½ TL")], []])
        #expect(StepReferences.decode(StepReferences.encode(references)) == references)
        #expect(StepReferences.encode(nil) == nil)
        #expect(StepReferences.decode(#"{"fingerprint":"x","usesByStep":[[{"line":1,"amount":"1"}]],"createdAt":0}"#) == nil)
    }
}
