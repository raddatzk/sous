import Foundation
import Testing
@testable import SousKit

@Suite("Resolving amounts written into steps")
struct StepAmountResolverTests {
    private let formatter = QuantityFormatter(locale: Locale(identifier: "de_DE"))

    private func segmentsText(_ segments: [StepAmountSegment]) -> [String] {
        segments.map { segment in
            switch segment {
            case .text(let s): "text(\(s))"
            case .amount(let s): "amount(\(s))"
            }
        }
    }

    @Test("The acceptance scenario: a share, a remainder, and a half, all at 12 servings")
    func acceptanceScenario() {
        let recipe = Recipe(
            title: "Kartoffelpfanne",
            servings: 4,
            ingredientsText: """
            1 kg Kartoffel
            2 Zwiebeln
            """,
            instructionsText: """
            300 g Kartoffeln 7 Minuten köcheln lassen.
            Restliche Kartoffeln nur schälen.
            Die Hälfte der Zwiebeln fein würfeln.
            """
        )
        let steps = recipe.steps
        let resolution = StepAmountResolver.resolve(recipe, toServings: 12, formatter: formatter)

        let step1 = segmentsText(resolution.segments(for: steps[0])).joined()
        #expect(step1.contains("amount(900 g)"))
        #expect(!step1.contains("300 g"))

        let step2 = segmentsText(resolution.segments(for: steps[1])).joined()
        #expect(step2.contains("amount(2,1 kg)"))

        let step3 = segmentsText(resolution.segments(for: steps[2])).joined()
        #expect(step3.contains("amount(3)"))

        // The chip beneath each step loses the ingredient whose amount is
        // now part of the sentence.
        let kartoffel = recipe.ingredients.first { $0.name == "Kartoffel" }!
        let zwiebeln = recipe.ingredients.first { $0.name == "Zwiebeln" }!
        #expect(resolution.mentionsAmount(of: kartoffel, in: steps[0]))
        #expect(resolution.mentionsAmount(of: kartoffel, in: steps[1]))
        #expect(resolution.mentionsAmount(of: zwiebeln, in: steps[2]))

        #expect(recipe.ingredients(mentionedIn: steps[0], scaledToServings: 12).isEmpty)
    }

    @Test("A relative amount is inserted right after the name it matched, not after the rest of the sentence")
    func relativeAmountSitsRightAfterTheName() {
        let recipe = Recipe(
            title: "Kartoffelpüree",
            servings: 2,
            ingredientsText: "1 kg Kartoffel",
            instructionsText: """
            300 g Kartoffeln 7 Minuten köcheln lassen.
            Restlichen Kartoffeln nur schälen.
            """
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        let segments = resolution.segments(for: recipe.steps[1])
        let text = segmentsText(segments).joined()

        // "nur schälen" stays after the parenthetical, not before it — the
        // amount belongs to "Kartoffeln", not to the rest of the sentence.
        #expect(text == "text(Restlichen Kartoffeln)text( ()amount(700 g)text())text( nur schälen.)")
    }

    @Test("A bare count only scales when it is bound to a counted ingredient")
    func bareCountBindsToCountedIngredient() {
        let recipe = Recipe(
            title: "Eierkuchen",
            servings: 2,
            ingredientsText: "4 Eier",
            instructionsText: "2 Eier trennen, den Rest in die Schüssel geben"
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 4, formatter: formatter)
        let text = segmentsText(resolution.segments(for: recipe.steps[0])).joined()
        #expect(text.contains("amount(4)"))
    }

    @Test("Group headings disambiguate two lines with the same name")
    func groupDisambiguatesSameName() {
        let recipe = Recipe(
            title: "Kuchen",
            servings: 4,
            ingredientsText: """
            # Für den Teig
            200 g Butter
            # Für die Füllung
            100 g Butter
            """,
            instructionsText: """
            # Für den Teig
            200 g Butter schmelzen
            # Für die Füllung
            100 g Butter erwärmen
            """
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 8, formatter: formatter)
        let teig = segmentsText(resolution.segments(for: recipe.steps[0])).joined()
        let fuellung = segmentsText(resolution.segments(for: recipe.steps[1])).joined()
        #expect(teig.contains("amount(400 g)"))
        #expect(fuellung.contains("amount(200 g)"))
    }

    @Test("Group headings disambiguate even when both lines carry the identical amount")
    func groupDisambiguatesIdenticalAmounts() {
        // "100 g Butter" appears under both headings with the same number —
        // the group filter alone must still send each mention to its own
        // line, without needing the amounts to differ to tell them apart.
        let recipe = Recipe(
            title: "Apfelkuchen mit Gemüsefüllung",
            servings: 4,
            ingredientsText: """
            # Für den Teig
            200 g Mehl
            100 g Butter
            1 Ei
            # Für die Füllung
            100 g Butter
            300 g Äpfel
            """,
            instructionsText: """
            # Für den Teig
            Für den Teig 200 g Mehl mit 100 g Butter und dem Ei zu einem glatten Teig verkneten und 30 Minuten kühl stellen.
            # Für die Füllung
            Für die Füllung 100 g Butter in einer Pfanne erhitzen und die Äpfel darin 5 Minuten andünsten.
            """
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 8, formatter: formatter)
        let teigStep = segmentsText(resolution.segments(for: recipe.steps[0])).joined()
        let fuellungStep = segmentsText(resolution.segments(for: recipe.steps[1])).joined()

        // Both scale identically (100 g -> 200 g at double servings) — the
        // point is that each resolves confidently to its own line rather
        // than falling back to blind scale because two lines matched.
        #expect(teigStep.contains("amount(200 g)"))
        #expect(fuellungStep.contains("amount(200 g)"))

        let teigButter = recipe.ingredients.first { $0.name == "Butter" && $0.group == "Für den Teig" }!
        let fuellungButter = recipe.ingredients.first { $0.name == "Butter" && $0.group == "Für die Füllung" }!
        #expect(resolution.mentionsAmount(of: teigButter, in: recipe.steps[0]))
        #expect(!resolution.mentionsAmount(of: fuellungButter, in: recipe.steps[0]))
        #expect(resolution.mentionsAmount(of: fuellungButter, in: recipe.steps[1]))
        #expect(!resolution.mentionsAmount(of: teigButter, in: recipe.steps[1]))
    }

    @Test("An amount that cannot be tied to any line falls back to the old blind scale")
    func unresolvedFallsBackToBlindScale() {
        let recipe = Recipe(
            title: "Pfanne",
            servings: 2,
            ingredientsText: "300 g Tomaten",
            instructionsText: "500 g Zucchini anbraten"
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 4, formatter: formatter)
        let segments = resolution.segments(for: recipe.steps[0])
        // Scaled (500 g at factor 2 promotes to 1 kg, same as the formatter
        // always does), but as plain text — nothing confidently resolved it.
        #expect(segmentsText(segments).joined().contains("text(1 kg)"))
        #expect(!segments.contains { if case .amount = $0 { true } else { false } })
    }

    @Test("AmountScaler still behaves exactly as before, now via the resolver")
    func amountScalerUnchanged() {
        #expect(AmountScaler.scaled("300 g Tomaten würfeln", by: 2, formatter: formatter) == "600 g Tomaten würfeln")
        #expect(AmountScaler.scaled("Bei 180 Grad backen", by: 2, formatter: formatter) == "Bei 180 Grad backen")
        #expect(AmountScaler.scaled("20 Minuten schmoren", by: 2, formatter: formatter) == "20 Minuten schmoren")
        #expect(AmountScaler.scaled("In 2 Hälften schneiden", by: 2, formatter: formatter) == "In 2 Hälften schneiden")
    }
}
