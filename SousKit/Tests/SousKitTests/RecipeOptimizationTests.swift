import Foundation
import SwiftData
import Testing
@testable import SousKit

@Suite("Optimizing a recipe for Sous (prompt v4)")
struct RecipeOptimizationTests {
    let chili = Recipe(
        title: "Chili sin Carne",
        servings: 6,
        ingredientsText: """
        250 g rote Linsen - (getrocknet)
        3 Knoblauchzehen
        1 Dose stückige Tomaten - (400 g)
        1,5 TL Kreuzkümmel, gemahlen - (ersatzweise Zimtpulver)
        1 TL Ingwer, frisch gerieben
        Limette und Creme fraiche - (zum Servieren)
        """,
        instructionsText: """
        Die 250 g Linsen waschen.
        Knoblauch würfeln und mit Kreuzkümmel und Ingwer andünsten.
        Tomaten und Linsen dazugeben.
        Mit Limette und Creme fraiche servieren.
        """
    )

    /// An answer in the v4 shape: `lines` are the entries of "zeilen" as
    /// JSON objects, `steps` those of "schritte".
    private func answer(lines: [String], steps: [String], groups: [String] = []) -> String {
        """
        Hier ist die Antwort:
        ```json
        {"zeilen": [\(lines.joined(separator: ", "))], "gruppen": [\(groups.joined(separator: ", "))], "schritte": [\(steps.joined(separator: ", "))], "hinweise": []}
        ```
        """
    }

    /// Each line as written, one new line each, numbered in order.
    private func unchanged(_ recipe: Recipe, except overrides: [Int: String] = [:]) -> [String] {
        var number = 0
        return IngredientLineReader.writtenLines(in: recipe.ingredientsText).enumerated().map { index, line in
            if let override = overrides[index + 1] {
                number += override.components(separatedBy: "\"nr\"").count - 1
                return override
            }
            number += 1
            return #"{"zeile": \#(index + 1), "neu": [{"nr": \#(number), "text": "\#(line.text)"}]}"#
        }
    }

    private func oldSteps(_ recipe: Recipe) -> [String] {
        recipe.steps.indices.map { #"{"alt": \#($0 + 1), "bezuege": []}"# }
    }

    private func read(_ text: String, for recipe: Recipe) throws -> RecipeOptimization {
        try RecipeOptimizationPrompt.read(text, for: recipe).get()
    }

    // MARK: - The prompt

    @Test("The prompt carries the catalog, the lines as written, the steps and the notes")
    func prompt() {
        var recipe = chili
        recipe.notes = "Dazu passt Reis."
        let prompt = RecipeOptimizationPrompt.prompt(for: recipe)
        #expect(prompt.contains("Katalog (Name | Aliasse):"))
        #expect(prompt.contains("\nKnoblauch | Knoblauchzehe, Knoblauchzehen\n"))
        // As written, noise and all: that is what is to be rewritten.
        #expect(prompt.contains("Z1: 250 g rote Linsen - (getrocknet)"))
        #expect(prompt.contains("S2: Knoblauch würfeln"))
        #expect(prompt.contains("Notizen:\nDazu passt Reis."))
        #expect(prompt.contains("\"einordnung\""))
        // A state is preparation, not noise (v5).
        #expect(prompt.contains("\"100 g Butter, weich\""))
    }

    // MARK: - Structure

    @Test("Every old line exactly once, the steps all there in order, references to lines that exist")
    func structure() {
        var lines = unchanged(chili)
        let skipped = Array(lines.dropLast())
        #expect(throws: RecipeOptimizationPrompt.Failure.lineNotCovered(6)) {
            try read(answer(lines: skipped, steps: oldSteps(chili)), for: chili)
        }
        lines.append(lines[0])
        #expect(throws: RecipeOptimizationPrompt.Failure.lineCoveredTwice(1)) {
            try read(answer(lines: lines, steps: oldSteps(chili)), for: chili)
        }
        #expect(throws: RecipeOptimizationPrompt.Failure.stepsChanged) {
            try read(answer(lines: unchanged(chili), steps: oldSteps(chili).reversed()), for: chili)
        }
        let dangling = [#"{"alt": 1, "bezuege": [{"art": "bezug", "zeile": 42}]}"#] + oldSteps(chili).dropFirst()
        #expect(throws: RecipeOptimizationPrompt.Failure.unknownNewLine(step: 1, line: 42)) {
            try read(answer(lines: unchanged(chili), steps: dangling), for: chili)
        }
        #expect(throws: RecipeOptimizationPrompt.Failure.unreadable) {
            // A v2 answer is not an optimization.
            try read(#"{"schritte": [{"schritt": 1, "bezuege": []}], "hinweise": []}"#, for: chili)
        }
    }

    // MARK: - Noise, amounts, words

    @Test("Noise is dropped: \"250 g rote Linsen - (getrocknet)\" becomes \"250 g rote Linsen\"")
    func noise() throws {
        let optimization = try read(answer(
            lines: unchanged(chili, except: [1: #"{"zeile": 1, "neu": [{"nr": 1, "text": "250 g rote Linsen", "zutat": "Rote Linsen"}]}"#]),
            steps: oldSteps(chili)
        ), for: chili)
        let line = optimization.lines[0]
        #expect(line.rewritten == ["250 g rote Linsen"])
        #expect(line.changes == [.noise])
        #expect(line.issues.isEmpty)
        #expect(line.isPreTicked)
        #expect(line.resolves)

        let applied = optimization.applied(optimization.defaultSelection).recipe
        #expect(applied.ingredientsText.hasPrefix("250 g rote Linsen\n3 Knoblauchzehen\n"))
        #expect(applied.instructionsText == chili.instructionsText)
    }

    @Test("Amounts stay: changed, invented or dropped amounts are refused; a weight the line writes and a unit taken out of the name pass")
    func amounts() throws {
        let optimization = try read(answer(
            lines: unchanged(chili, except: [
                1: #"{"zeile": 1, "neu": [{"nr": 1, "text": "300 g rote Linsen"}]}"#,
                2: #"{"zeile": 2, "neu": [{"nr": 2, "text": "3 Zehen Knoblauch", "zutat": "Knoblauch"}]}"#,
                3: #"{"zeile": 3, "neu": [{"nr": 3, "text": "400 g stückige Tomaten", "zutat": "Gehackte Tomaten"}]}"#,
                4: #"{"zeile": 4, "neu": [{"nr": 4, "text": "Kreuzkümmel, gemahlen"}]}"#,
                6: #"{"zeile": 6, "neu": [{"nr": 6, "text": "1 Limette"}, {"nr": 7, "text": "Creme fraiche"}]}"#,
            ]),
            steps: oldSteps(chili)
        ), for: chili)
        #expect(optimization.lines[0].issues == [.amountChanged(from: "250 g", to: "300 g")])
        #expect(optimization.lines[0].isRefused)
        #expect(optimization.lines[1].issues.isEmpty)
        #expect(optimization.lines[1].isPreTicked)
        #expect(optimization.lines[2].issues.isEmpty)
        #expect(optimization.lines[3].issues == [.amountDropped("1,5 TL")], "\(optimization.lines[3].issues)")
        #expect(optimization.lines[5].issues == [.amountInvented("1")])

        // Refused lines stay as written.
        let applied = optimization.applied(RecipeOptimization.Selection(lines: [1, 2, 3, 4, 6])).recipe
        #expect(applied.ingredientsText.components(separatedBy: "\n") == [
            "250 g rote Linsen - (getrocknet)",
            "3 Zehen Knoblauch",
            "400 g stückige Tomaten",
            "1,5 TL Kreuzkümmel, gemahlen - (ersatzweise Zimtpulver)",
            "1 TL Ingwer, frisch gerieben",
            "Limette und Creme fraiche - (zum Servieren)",
        ])
    }

    @Test("A size belongs to the amount; a misspelled unit is a typo, not a new amount")
    func sizesAndUnitTypos() throws {
        let recipe = Recipe(title: "Dip", ingredientsText: "1 großer Blumenkohl\n3 Priesen Pfeffer", instructionsText: "Alles mischen.")
        let optimization = try read(answer(lines: [
            #"{"zeile": 1, "neu": [{"nr": 1, "text": "1 Blumenkohl"}]}"#,
            #"{"zeile": 2, "neu": [{"nr": 2, "text": "3 Prisen Pfeffer"}], "tippfehler": {"falsch": "Priesen", "richtig": "Prisen"}}"#,
        ], steps: oldSteps(recipe)), for: recipe)
        #expect(optimization.lines[0].issues == [.amountChanged(from: "1 großer", to: "1")])
        #expect(!optimization.lines[1].isRefused)
        #expect(optimization.lines[1].typos == [.init(wrong: "Priesen", right: "Prisen", declared: true)])
        #expect(!optimization.lines[1].isPreTicked)
    }

    @Test("Units that mean the same amount pass")
    func unitNormalizations() throws {
        let recipe = Recipe(title: "Brot", ingredientsText: "0,5 kg Mehl\n2 Esslöffel Öl\n1 Pkg Hefe", instructionsText: "Alles verkneten.")
        let optimization = try read(answer(lines: [
            #"{"zeile": 1, "neu": [{"nr": 1, "text": "500 g Mehl"}]}"#,
            #"{"zeile": 2, "neu": [{"nr": 2, "text": "2 EL Öl"}]}"#,
            #"{"zeile": 3, "neu": [{"nr": 3, "text": "1 Packung Hefe"}]}"#,
        ], steps: oldSteps(recipe)), for: recipe)
        #expect(optimization.lines.allSatisfy { $0.issues.isEmpty && !$0.isRefused })
    }

    @Test("A line is never exchanged for other words; a compound is only taken apart whole")
    func words() throws {
        let recipe = Recipe(
            title: "Salat",
            ingredientsText: "200 g Möhren\n2 EL Kürbiskernöl\n1 EL Tomatenmark\n2 Knoblauchzehen\n100 g Tomaten, getrocknet",
            instructionsText: "Alles mischen."
        )
        let optimization = try read(answer(lines: [
            #"{"zeile": 1, "neu": [{"nr": 1, "text": "200 g Karotten"}]}"#,
            #"{"zeile": 2, "neu": [{"nr": 2, "text": "2 EL Kürbiskern"}]}"#,
            #"{"zeile": 3, "neu": [{"nr": 3, "text": "1 EL Tomate"}]}"#,
            #"{"zeile": 4, "neu": [{"nr": 4, "text": "2 Zehen Knoblauch"}]}"#,
            #"{"zeile": 5, "neu": [{"nr": 5, "text": "100 g getrocknete Tomaten"}]}"#,
        ], steps: oldSteps(recipe)), for: recipe)
        #expect(optimization.lines[0].issues == [.newWord("Karotten")])
        #expect(optimization.lines[1].isRefused)
        #expect(optimization.lines[2].isRefused)
        #expect(!optimization.lines[3].isRefused)
        #expect(!optimization.lines[4].isRefused)
    }

    // MARK: - Typos (R4)

    @Test("A typo is one edit at most, must make the line read, and is never pre-ticked")
    func typos() throws {
        let recipe = Recipe(
            title: "Kuchen",
            ingredientsText: "100 g Cachewkerne\n50 g Margarine\n2 EL Kürbiskernöl\n1 Chiabatta",
            instructionsText: "Backen."
        )
        let optimization = try read(answer(lines: [
            #"{"zeile": 1, "neu": [{"nr": 1, "text": "100 g Cashewkerne", "zutat": "Cashew"}], "tippfehler": {"falsch": "Cachewkerne", "richtig": "Cashewkerne"}}"#,
            #"{"zeile": 2, "neu": [{"nr": 2, "text": "50 g Mandarine"}], "tippfehler": {"falsch": "Margarine", "richtig": "Mandarine"}}"#,
            #"{"zeile": 3, "neu": [{"nr": 3, "text": "2 EL Kürbiskerne"}]}"#,
            #"{"zeile": 4, "neu": [{"nr": 4, "text": "1 Ciabatta"}], "tippfehler": {"falsch": "Chiabatta", "richtig": "Ciabatta"}}"#,
        ], steps: oldSteps(recipe)), for: recipe)

        let cashew = optimization.lines[0]
        #expect(cashew.typos == [.init(wrong: "Cachewkerne", right: "Cashewkerne", declared: true)])
        #expect(!cashew.isRefused)
        #expect(!cashew.isPreTicked)
        #expect(!optimization.defaultSelection.lines.contains(1))

        // Margarine → Mandarine resolves and keeps the amount: only the
        // distance catches it.
        #expect(optimization.lines[1].issues.contains(.typoTooFar(wrong: "Margarine", right: "Mandarine")))
        #expect(optimization.lines[1].isRefused)
        // Undeclared, two edits: a new word.
        #expect(optimization.lines[2].issues.contains(.newWord("Kürbiskerne")))
        // One edit, but the catalog does not know Ciabatta: not offered.
        #expect(optimization.lines[3].issues.contains(.typoDoesNotResolve("Ciabatta")))

        #expect(TypoDistance.edits("chiabatta", "ciabatta") == 1)
        #expect(TypoDistance.edits("margarine", "mandarine") == 2)
        #expect(TypoDistance.edits("kürbiskernöl", "kürbiskerne") == 2)
        #expect(TypoDistance.edits("eingefrohren", "eingefroren") == 1)
        #expect(TypoDistance.edits("priesen", "prisen") == 1)
        #expect(TypoDistance.edits("ab", "ba") == 1)
    }

    @Test("A typo nobody declared is shown as one, unticked")
    func undeclaredTypo() throws {
        let recipe = Recipe(title: "Salat", ingredientsText: "100 g Cachewkerne", instructionsText: "Rösten.")
        let optimization = try read(answer(lines: [
            #"{"zeile": 1, "neu": [{"nr": 1, "text": "100 g Cashewkerne"}]}"#,
        ], steps: oldSteps(recipe)), for: recipe)
        #expect(optimization.lines[0].typos == [.init(wrong: "Cachewkerne", right: "Cashewkerne", declared: false)])
        #expect(!optimization.lines[0].isPreTicked)
    }

    // MARK: - What the reader reads

    @Test("The claimed ingredient must be what Sous reads; otherwise the change waits for a look")
    func claims() throws {
        let optimization = try read(answer(
            lines: unchanged(chili, except: [
                1: #"{"zeile": 1, "neu": [{"nr": 1, "text": "250 g rote Linsen", "zutat": "Linsen"}]}"#,
                3: #"{"zeile": 3, "neu": [{"nr": 3, "text": "400 g stückige Tomaten", "zutat": "Tomatenwürfel aus Dosen"}]}"#,
            ]),
            steps: oldSteps(chili)
        ), for: chili)
        #expect(optimization.lines[0].issues == [.readsAs(line: "250 g rote Linsen", claimed: "Linsen", read: "Rote Linsen")])
        #expect(!optimization.lines[0].isRefused)
        #expect(!optimization.lines[0].isPreTicked)
        #expect(optimization.lines[2].issues == [.unknownClaim("Tomatenwürfel aus Dosen")])
    }

    @Test("A rewritten line outside the fixed form reads as nothing, however close it comes")
    func claimOutsideTheForm() throws {
        let optimization = try read(answer(
            lines: unchanged(chili, except: [
                5: #"{"zeile": 5, "neu": [{"nr": 5, "text": "1 TL frisch geriebener Ingwer", "zutat": "Ingwer"}]}"#,
            ]),
            steps: oldSteps(chili)
        ), for: chili)
        #expect(optimization.lines[4].issues.contains(
            .readsAs(line: "1 TL frisch geriebener Ingwer", claimed: "Ingwer", read: nil)
        ))
        #expect(!optimization.lines[4].isPreTicked)
    }

    // MARK: - Preparation, grams, steps

    @Test("Preparation becomes a step; Sous weighs a measured line from the catalog, never the model")
    func preparation() throws {
        let optimization = try read(answer(
            lines: unchanged(chili, except: [
                5: #"{"zeile": 5, "neu": [{"nr": 5, "text": "1 TL Ingwer", "zutat": "Ingwer"}], "zubereitung": "frisch gerieben"}"#,
            ]),
            steps: [
                #"{"alt": 1, "bezuege": [{"art": "menge", "stelle": "250 g", "zeile": 1, "menge": "250 g"}]}"#,
                #"{"neu": "Ingwer schälen und fein reiben.", "bezuege": [{"art": "bezug", "zeile": 5, "menge": "1 TL"}]}"#,
                #"{"alt": 2, "bezuege": [{"art": "bezug", "zeile": 2, "menge": "3"}, {"art": "bezug", "zeile": 4}, {"art": "bezug", "zeile": 5}]}"#,
                #"{"alt": 3, "bezuege": [{"art": "bezug", "zeile": 3}, {"art": "bezug", "zeile": 1}]}"#,
                #"{"alt": 4, "bezuege": [{"art": "bezug", "zeile": 6}]}"#,
            ]
        ), for: chili)

        let ginger = optimization.lines[4]
        #expect(ginger.changes == [.preparation])
        let grams = try #require(RecipeOptimizationPrompt.weighedGrams(
            IngredientLineReader.readLine("1 TL Ingwer", catalog: .bundled), catalog: .bundled, nutritionCatalog: .bundled
        ))
        #expect(ginger.weighing == .init(from: Quantity(1, .teaspoon), grams: RecipeOptimization.roundedGrams(grams)))
        let expected = QuantityFormatter(locale: Locale(identifier: "de_DE"))
            .string(for: Quantity(RecipeOptimization.roundedGrams(grams), .gram), size: nil)
        #expect(ginger.rewritten == ["\(expected) Ingwer"])
        #expect(optimization.newSteps == [.init(id: 1, before: 2, text: "Ingwer schälen und fein reiben.")])

        let applied = optimization.applied(optimization.defaultSelection)
        let recipe = applied.recipe
        #expect(recipe.steps.map(\.text) == [
            "Die 250 g Linsen waschen.",
            "Ingwer schälen und fein reiben.",
            "Knoblauch würfeln und mit Kreuzkümmel und Ingwer andünsten.",
            "Tomaten und Linsen dazugeben.",
            "Mit Limette und Creme fraiche servieren.",
        ])
        // The references are about the new text, and current for it.
        let references = try #require(recipe.stepReferences)
        #expect(references.isCurrent(for: recipe))
        #expect(references.steps.count == 5)
        // The chip on the new step is weighed like its line.
        #expect(references.steps[1] == [.init(kind: .mention, text: "", line: 5, amount: expected)])

        // Without the step, the line change can still be taken, and the
        // references move up a step.
        var selection = optimization.defaultSelection
        selection.steps = []
        let withoutStep = optimization.applied(selection).recipe
        #expect(withoutStep.steps.count == 4)
        #expect(withoutStep.stepReferences?.isCurrent(for: withoutStep) == true)
        #expect(withoutStep.stepReferences?.steps[1].contains { $0.line == 2 } == true)
    }

    @Test("Without a measure in the catalog, the line keeps its unit")
    func noMeasure() throws {
        let recipe = Recipe(title: "Pasta", ingredientsText: "2 EL Parmesan, frisch gerieben", instructionsText: "Den geriebenen Parmesan darüberstreuen.")
        let optimization = try read(answer(lines: [
            #"{"zeile": 1, "neu": [{"nr": 1, "text": "2 EL Parmesan", "zutat": "Parmesan"}], "zubereitung": "frisch gerieben"}"#,
        ], steps: oldSteps(recipe)), for: recipe)
        #expect(optimization.lines[0].rewritten == ["2 EL Parmesan"])
        #expect(optimization.lines[0].weighing == nil)
        // Offered, but only with a look: two spoons of a block of cheese
        // measure nothing.
        #expect(optimization.lines[0].issues == [.unweighed("2 EL")])
        #expect(!optimization.lines[0].isPreTicked)
        #expect(optimization.newSteps.isEmpty)
    }

    @Test("The model writing grams itself is an amount changed")
    func modelGrams() throws {
        let recipe = Recipe(title: "Tee", ingredientsText: "1 TL Ingwer, frisch gerieben", instructionsText: "Aufgießen.")
        let optimization = try read(answer(lines: [
            #"{"zeile": 1, "neu": [{"nr": 1, "text": "5 g Ingwer"}], "zubereitung": "frisch gerieben"}"#,
        ], steps: oldSteps(recipe)), for: recipe)
        #expect(optimization.lines[0].issues == [.amountChanged(from: "1 TL", to: "5 g")])
    }

    // MARK: - Alternatives, splits, removal

    @Test("An alternative moves into the notes; two ingredients become two lines; a line goes only somewhere")
    func alternativesAndSplits() throws {
        var recipe = chili
        recipe.notes = "Schmeckt aufgewärmt noch besser."
        let optimization = try read(answer(
            lines: unchanged(recipe, except: [
                4: #"{"zeile": 4, "neu": [{"nr": 4, "text": "1,5 TL Kreuzkümmel, gemahlen", "zutat": "Kreuzkümmel"}], "notiz": "Statt Kreuzkümmel geht auch Zimtpulver."}"#,
                5: #"{"zeile": 5, "neu": []}"#,
                6: #"{"zeile": 6, "neu": [{"nr": 5, "text": "Limette", "zutat": "Limette"}, {"nr": 6, "text": "Creme fraiche", "zutat": "Creme fraiche"}]}"#,
            ]),
            steps: oldSteps(recipe)
        ), for: recipe)
        #expect(optimization.lines[3].changes == [.alternative])
        #expect(optimization.lines[3].isPreTicked)
        #expect(optimization.lines[4].issues == [.removedWithoutPlace])
        #expect(optimization.lines[5].changes == [.split])
        #expect(optimization.lines[5].isPreTicked)

        let applied = optimization.applied(optimization.defaultSelection).recipe
        #expect(applied.notes == "Schmeckt aufgewärmt noch besser.\nStatt Kreuzkümmel geht auch Zimtpulver.")
        #expect(applied.ingredientsText.hasSuffix("1,5 TL Kreuzkümmel, gemahlen\n1 TL Ingwer, frisch gerieben\nLimette\nCreme fraiche"))
    }

    @Test("A group of alternatives the notes already describe goes, heading and all — unless unticked")
    func alternativeGroup() throws {
        let recipe = Recipe(
            title: "Brötchen mit gegrilltem Gemüse",
            ingredientsText: "1 Pkg Halloumi\n3 Zucchini\nBrötchen\n# Alternative\n2 Auberginen\nFeta\nFladenbrot",
            instructionsText: "Gemüse grillen.\nBrötchen belegen.",
            notes: "Alternativ zum Halloumi geht auch Feta.\nAlternativ zum Brötchen auch Fladenbrot.\ngegrillte Aubergine schmeckt auch super"
        )
        let optimization = try read(answer(
            lines: [
                #"{"zeile": 1, "neu": [{"nr": 1, "text": "1 Pkg Halloumi"}]}"#,
                #"{"zeile": 2, "neu": [{"nr": 2, "text": "3 Zucchini"}]}"#,
                #"{"zeile": 3, "neu": [{"nr": 3, "text": "Brötchen"}]}"#,
                #"{"zeile": 4, "neu": [], "entfernt": "gruppe"}"#,
                #"{"zeile": 5, "neu": [], "entfernt": "gruppe"}"#,
                #"{"zeile": 6, "neu": [], "entfernt": "gruppe"}"#,
            ],
            steps: [#"{"alt": 1, "bezuege": [{"art": "bezug", "zeile": 2}]}"#, #"{"alt": 2, "bezuege": [{"art": "bezug", "zeile": 3}, {"art": "bezug", "zeile": 1}]}"#],
            groups: [#"{"gruppe": "Alternative", "vorschlag": "entfernen", "grund": "Die Notizen nennen die Alternativen schon."}"#]
        ), for: recipe)
        #expect(optimization.groups == [.init(name: "Alternative", action: .remove, reason: "Die Notizen nennen die Alternativen schon.", lines: [4, 5, 6], variant: nil)])
        #expect(optimization.defaultSelection.groups == ["Alternative"])

        let applied = optimization.applied(optimization.defaultSelection).recipe
        #expect(applied.ingredientsText == "1 Pkg Halloumi\n3 Zucchini\nBrötchen")
        #expect(applied.notes == recipe.notes)
        #expect(applied.stepReferences?.isCurrent(for: applied) == true)

        var keep = optimization.defaultSelection
        keep.groups = []
        #expect(optimization.applied(keep).recipe.ingredientsText == recipe.ingredientsText)
    }

    @Test("A variant is proposed with its own text; amounts the recipe never writes are pointed out")
    func variantProposal() throws {
        let recipe = Recipe(
            title: "Curry",
            ingredientsText: "200 g Hähnchen\n400 ml Kokosmilch\n# Alternative\n200 g Tofu",
            instructionsText: "Anbraten.\nKöcheln."
        )
        let optimization = try read(answer(
            lines: [
                #"{"zeile": 1, "neu": [{"nr": 1, "text": "200 g Hähnchen"}]}"#,
                #"{"zeile": 2, "neu": [{"nr": 2, "text": "400 ml Kokosmilch"}]}"#,
                #"{"zeile": 3, "neu": [], "entfernt": "gruppe"}"#,
            ],
            steps: oldSteps(recipe),
            groups: [#"{"gruppe": "alternative", "vorschlag": "variante", "grund": "Eine vegane Fassung.", "variante": {"titel": "Curry mit Tofu", "zutaten": ["200 g Tofu", "400 ml Kokosmilch", "1 EL Sojasauce"], "schritte": ["Tofu anbraten.", "Köcheln."]}}"#]
        ), for: recipe)
        let group = try #require(optimization.groups.first)
        #expect(group.action == .variant)
        #expect(group.variant?.title == "Curry mit Tofu")
        #expect(group.variant?.ingredientsText == "200 g Tofu\n400 ml Kokosmilch\n1 EL Sojasauce")
        #expect(group.variant?.foreignAmounts == ["1 EL Sojasauce"])
    }

    // MARK: - Classification

    @Test("Unknown names are classified; known ones are ignored; a fair target becomes a \"zählt wie\" to report")
    func classification() throws {
        let recipe = Recipe(
            title: "Bowl",
            ingredientsText: "200 g Tempeh-Streifen\n100 g Babyspinat\n1 Handvoll Curryblätter",
            instructionsText: "Alles anbraten."
        )
        let optimization = try read(answer(lines: [
            #"{"zeile": 1, "neu": [{"nr": 1, "text": "200 g Tempeh-Streifen"}], "einordnung": {"name": "Tempeh-Streifen", "art": "sorte", "ziel": "Tempeh"}}"#,
            #"{"zeile": 2, "neu": [{"nr": 2, "text": "100 g Babyspinat"}], "einordnung": {"name": "Babyspinat", "art": "sorte", "ziel": "Spinat"}}"#,
            #"{"zeile": 3, "neu": [{"nr": 3, "text": "1 Handvoll Curryblätter"}], "einordnung": {"name": "Curryblätter", "art": "neu", "ziel": null}}"#,
        ], steps: oldSteps(recipe)), for: recipe)
        // Babyspinat and Curryblätter are known to the catalog.
        #expect(optimization.classifications.map(\.name) == ["Tempeh-Streifen"])
        let tempeh = try #require(optimization.classifications.first)
        #expect(tempeh.kind == .variety)
        #expect(tempeh.target == IngredientCatalog.bundled.ingredient(for: "Tempeh")?.name)
        // The catalog has no Tempeh to count as: a word of its own, then.
        #expect(tempeh.target == nil)
        #expect(tempeh.proposal == .word)
    }

    @Test("A name that stays unknown comes with a household proposal that makes its line read")
    func householdProposals() throws {
        let recipe = Recipe(
            title: "Curry",
            ingredientsText: "400 ml halbfette Kokosmilch (oder mehr)\n2 Einhornstaub\n1 TL Kreuzkümel\n1 Prise Glitzerzucker",
            instructionsText: "Alles kochen."
        )
        let optimization = try read(answer(lines: [
            #"{"zeile": 1, "neu": [{"nr": 1, "text": "400 ml halbfette Kokosmilch"}], "einordnung": {"name": "halbfette Kokosmilch", "art": "formulierung", "ziel": "Kokosmilch"}}"#,
            #"{"zeile": 2, "neu": [{"nr": 2, "text": "2 Einhornstaub"}], "einordnung": {"name": "Einhornstaub", "art": "neu", "ziel": null}}"#,
            #"{"zeile": 3, "neu": [{"nr": 3, "text": "1 TL Kreuzkümel"}], "einordnung": {"name": "Kreuzkümel", "art": "tippfehler", "ziel": "Kreuzkümmel"}}"#,
            // A name that would not make the line read is no proposal.
            #"{"zeile": 4, "neu": [{"nr": 4, "text": "1 Prise Glitzerzucker"}], "einordnung": {"name": "Glitzer", "art": "neu", "ziel": null}}"#,
        ], steps: oldSteps(recipe)), for: recipe)

        let proposals = Dictionary(uniqueKeysWithValues: optimization.householdProposals.map { ($0.name, $0.proposal) })
        #expect(proposals == [
            "halbfette Kokosmilch": .countsAs(try #require(IngredientCatalog.bundled.ingredient(for: "Kokosmilch")?.name)),
            "Einhornstaub": .word,
        ])
        #expect(RecipeOptimization.HouseholdProposal.word.label == "neues Wort, ohne Werte")
    }

    @Test("Asked again, an optimized recipe keeps its lines and still gets proposals and references")
    func idempotent() throws {
        let recipe = Recipe(
            title: "Curry",
            ingredientsText: "2 Einhornstaub\n200 g Reis",
            instructionsText: "Reis kochen."
        )
        let optimization = try read(answer(lines: [
            #"{"zeile": 1, "neu": [{"nr": 1, "text": "2 Einhornstaub"}], "einordnung": {"name": "Einhornstaub", "art": "neu", "ziel": null}}"#,
            #"{"zeile": 2, "neu": [{"nr": 2, "text": "200 g Reis", "zutat": "Reis"}]}"#,
        ], steps: [#"{"alt": 1, "bezuege": [{"art": "bezug", "zeile": 2, "menge": "200 g"}]}"#]), for: recipe)
        #expect(!optimization.changesAnything)
        #expect(optimization.householdProposals.map(\.proposal) == [.word])
        let applied = optimization.applied(optimization.defaultSelection)
        #expect(applied.recipe.ingredientsText == recipe.ingredientsText)
        #expect(applied.recipe.stepReferences?.steps.first?.first?.line == 2)
    }

    // MARK: - The backend contract

    @Test("Any backend answers through the same checks")
    func backend() async throws {
        struct Fixed: RecipeOptimizationBackend {
            let text: String
            func answer(to prompt: String) async throws -> String {
                #expect(prompt.hasPrefix(RecipeOptimizationPrompt.rules))
                return text
            }
        }
        let text = answer(
            lines: unchanged(chili, except: [1: #"{"zeile": 1, "neu": [{"nr": 1, "text": "300 g rote Linsen"}]}"#]),
            steps: oldSteps(chili)
        )
        let optimization = try await RecipeOptimizer.optimize(chili, backend: Fixed(text: text)).get()
        #expect(optimization.lines[0].isRefused)
    }
}

@Suite("The original, kept read-only")
struct RecipeOriginalTests {
    private let imported = Recipe(
        title: "Suppe",
        ingredientsText: "250 g rote Linsen - (getrocknet)",
        instructionsText: "Kochen.",
        notes: "Aus dem Netz."
    )

    @Test("Kept once, never replaced; a variant starts without one")
    func keptOnce() {
        let kept = imported.keepingOriginal()
        #expect(kept.original?.ingredientsText == imported.ingredientsText)
        #expect(kept.original?.notes == "Aus dem Netz.")
        #expect(kept.original?.matches(kept) == true)

        var edited = kept
        edited.ingredientsText = "250 g rote Linsen"
        #expect(edited.keepingOriginal().original == kept.original)
        #expect(edited.original?.matches(edited) == false)
        #expect(edited.variantCopy(title: "Suppe scharf", in: UUID()).original == nil)
    }

    @Test("It survives the Core Data column and an export", arguments: [StoreBackend.coreData])
    func roundTrips(backend: StoreBackend) async throws {
        var recipe = imported.keepingOriginal()
        recipe.ingredientsText = "250 g rote Linsen"
        let store = try backend.makeStore()
        try await store.save(recipe)
        #expect(try await store.recipe(id: recipe.id)?.original == recipe.original)

        let data = try MelaExport.recipe(recipe, images: [])
        let back = try #require(MelaImport.read(data, named: "Suppe.sousrecipe").recipes.first?.recipe)
        #expect(back.original?.ingredientsText == "250 g rote Linsen - (getrocknet)")
        #expect(back.original?.notes == "Aus dem Netz.")
    }

    @MainActor
    @Test("Written at import; kept at the first optimization; an answer about an older text is refused")
    func library() async throws {
        let stores = try StoreBackend.coreData.makeStores()
        let enrichment = SwiftDataRecipeEnrichmentStore(modelContainer: try ModelContainer.sousContainer(inMemory: true))
        let library = RecipeLibrary(store: stores.recipes, imageStore: stores.images, enrichmentStore: enrichment)

        _ = await library.importRecipes(RecipeImportBatch(recipes: [ImportedRecipe(recipe: imported, images: [])], problems: []))
        let saved = try #require(await library.recipe(id: imported.id))
        #expect(saved.original == RecipeOriginal(of: imported, keptAt: try #require(saved.original?.keptAt)))

        // An older recipe, without an original, optimized for the first time.
        var older = Recipe(title: "Alt", ingredientsText: "1 Dose Tomaten - (400 g)", instructionsText: "Kochen.")
        try await stores.recipes.save(older)
        var rewritten = older
        rewritten.ingredientsText = "400 g Tomaten"
        let applied = RecipeOptimization.Applied(recipe: rewritten, reading: nil)
        #expect(await library.applyOptimization(applied, to: older))
        let optimized = try #require(await library.recipe(id: older.id))
        #expect(optimized.ingredientsText == "400 g Tomaten")
        #expect(optimized.original?.ingredientsText == "1 Dose Tomaten - (400 g)")

        // Asked about a text that has changed since: refused.
        older.ingredientsText = "1 Dose Tomaten - (400 g)"
        #expect(await library.applyOptimization(applied, to: older) == false)

        // Back to the original: the text as it arrived, no references, the
        // original kept for the next optimization.
        var referenced = optimized
        referenced.stepReferences = .empty(for: optimized)
        await library.save(referenced)
        #expect(await library.resetToOriginal(optimized))
        let reset = try #require(await library.recipe(id: older.id))
        #expect(reset.ingredientsText == "1 Dose Tomaten - (400 g)")
        #expect(reset.stepReferences == nil)
        #expect(reset.original == optimized.original)
        // Nothing left to go back to.
        #expect(await library.resetToOriginal(reset) == false)
    }
}
