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

    @Test("A supplementary mention that regex already found does not render twice")
    func supplementaryDuplicateDoesNotDoubleRender() throws {
        let recipe = Recipe(
            title: "Kartoffelpüree",
            servings: 2,
            ingredientsText: "1 kg Kartoffel",
            instructionsText: """
            300 g Kartoffeln kochen.
            Restlichen Kartoffeln nur schälen.
            """
        )
        let steps = recipe.steps
        let text0 = steps[0].text
        let text1 = steps[1].text

        // What `AmountAIExtractor` would independently find for the exact
        // same two mentions the regex scanner already resolves on its own.
        let duplicateAbsolute = AmountMention(
            kind: .absolute(Quantity(300, .gram)),
            writtenRange: try #require(text0.range(of: "300 g")),
            replacesWrittenRange: true,
            namePhrase: text0[try #require(text0.range(of: "Kartoffeln"))]
        )
        let duplicateRemaining = AmountMention(
            kind: .remaining,
            writtenRange: try #require(text1.range(of: "Restlichen")),
            replacesWrittenRange: false,
            namePhrase: text1[try #require(text1.range(of: "Kartoffeln"))]
        )

        let resolution = StepAmountResolver.resolve(
            recipe, toServings: 4,
            additionalMentions: [steps[0].id: [duplicateAbsolute], steps[1].id: [duplicateRemaining]],
            formatter: formatter
        )

        let step0 = segmentsText(resolution.segments(for: steps[0])).joined()
        let step1 = segmentsText(resolution.segments(for: steps[1])).joined()
        // 1 kg at double servings is 2 kg; 300 g of the original 1 kg is a
        // 0.3 share, i.e. 600 g of the scaled line, leaving 1,4 kg restlich.
        #expect(step0.contains("amount(600 g)"))
        #expect(step1.contains("amount(1,4 kg)"))
        // Exactly one resolved amount per step — not two, side by side.
        #expect(resolution.segments(for: steps[0]).filter { if case .amount = $0 { true } else { false } }.count == 1)
        #expect(resolution.segments(for: steps[1]).filter { if case .amount = $0 { true } else { false } }.count == 1)
    }

    @Test("A second noun under one shared 'restlichen' — which regex alone can never reach — surfaces as a suggestion via a supplementary mention")
    func supplementaryMentionReachesTheSecondNoun() throws {
        let recipe = Recipe(
            title: "Gemüsefüllung",
            servings: 2,
            ingredientsText: """
            4 Zwiebeln
            6 Karotten
            """,
            instructionsText: "Die restlichen Zwiebeln und Karotten zur Füllung geben."
        )
        let steps = recipe.steps
        let text = steps[0].text

        // Regex alone only ever reaches "Zwiebeln" (the first word after
        // "restlichen"); "Karotten" has no regex mention pointing at it at
        // all, so nothing here can collide with what regex already found.
        let karotten = AmountMention(
            kind: .remaining,
            writtenRange: try #require(text.range(of: "restlichen")),
            replacesWrittenRange: false,
            namePhrase: text[try #require(text.range(of: "Karotten"))]
        )

        let resolution = StepAmountResolver.resolve(
            recipe, toServings: 2,
            additionalMentions: [steps[0].id: [karotten]],
            formatter: formatter
        )
        let rendered = segmentsText(resolution.segments(for: steps[0])).joined()
        #expect(rendered.contains("amount(4)"))  // Zwiebeln, found by regex — trusted, renders live
        #expect(!rendered.contains("amount(6)")) // Karotten — an AI-origin claim never renders live

        // "Karotten" is reachable at all, just through the review sheet
        // rather than live text — a supplementary mention is not lost, only
        // held back from rendering unconfirmed.
        let suggestion = try #require(resolution.suggestions(for: steps[0]).first { $0.ingredientName == "Karotten" })
        #expect(suggestion.displayAmount == "6")
        guard case .aiExtracted(let writtenText) = suggestion.origin else {
            Issue.record("Expected an AI-extracted origin, got \(suggestion.origin)")
            return
        }
        #expect(writtenText == "restlichen")
    }

    @Test("Two ungrouped lines of the same ingredient act as one pot")
    func ungroupedSameNameLinesShareOnePot() {
        // The bug seen live: two `150 g Butter` lines with no group heading.
        // Per raw line the solver sees two equally good homes for "150 g"
        // and binds nothing — per pot there is exactly one 300-gram supply.
        let recipe = Recipe(
            title: "Apfelkuchen",
            servings: 4,
            ingredientsText: """
            300 g Mehl
            150 g Butter
            150 g Butter
            1 Ei
            """,
            instructionsText: """
            300 g Mehl mit 150 g Butter und dem Ei verkneten.
            Die restliche Butter in einer Pfanne erhitzen.
            """
        )
        let steps = recipe.steps
        let resolution = StepAmountResolver.resolve(recipe, toServings: 8, formatter: formatter)

        let step0 = segmentsText(resolution.segments(for: steps[0])).joined()
        // 150 g is half the 300-gram pot; at double servings that half is 300 g.
        #expect(step0.contains("amount(600 g)"))  // Mehl
        #expect(step0.contains("amount(300 g)"))  // Butter, resolved despite the twin lines

        // "Die restliche Butter" is the pot's other half.
        let step1 = segmentsText(resolution.segments(for: steps[1])).joined()
        #expect(step1.contains("amount(300 g)"))

        // Binding the pot binds both lines — no chip repeats the butter
        // beneath either step. The egg, named with no amount anywhere in
        // the step, is the one honest chip left.
        let butterLines = recipe.ingredients.filter { $0.name == "Butter" }
        #expect(butterLines.count == 2)
        for butter in butterLines {
            #expect(resolution.mentionsAmount(of: butter, in: steps[0]))
            #expect(resolution.mentionsAmount(of: butter, in: steps[1]))
        }
        #expect(recipe.ingredients(mentionedIn: steps[0], resolution: resolution, scaledToServings: 8).map(\.name) == ["Ei"])
        #expect(recipe.ingredients(mentionedIn: steps[1], resolution: resolution, scaledToServings: 8).isEmpty)
    }

    @Test("A pot also forms over unequal amounts, and 'restliche' means what the pot has left")
    func potPoolsUnequalAmounts() {
        let recipe = Recipe(
            title: "Buttergebäck",
            servings: 2,
            ingredientsText: """
            100 g Butter
            50 g Butter
            """,
            instructionsText: """
            100 g Butter schmelzen.
            Die restliche Butter unterheben.
            """
        )
        let steps = recipe.steps
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)

        #expect(segmentsText(resolution.segments(for: steps[0])).joined().contains("amount(100 g)"))
        #expect(segmentsText(resolution.segments(for: steps[1])).joined().contains("amount(50 g)"))
    }

    @Test("An amount larger than any single line still binds when the pot as a whole covers it")
    func potCoversAmountNoSingleLineCould() {
        // Per raw line "150 g" exceeds both and could bind nowhere; the
        // 150-gram pot is exactly what the step asks for.
        let recipe = Recipe(
            title: "Buttergebäck",
            servings: 2,
            ingredientsText: """
            100 g Butter
            50 g Butter
            """,
            instructionsText: "150 g Butter zerlassen."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        #expect(segmentsText(resolution.segments(for: recipe.steps[0])).joined().contains("amount(150 g)"))
        for butter in recipe.ingredients {
            #expect(resolution.mentionsAmount(of: butter, in: recipe.steps[0]))
        }
    }

    @Test("The fallback chip lists a pot once, with the summed amount")
    func fallbackChipCollapsesPotLines() {
        // No amount anywhere near "Butter" in the step, so the chip is the
        // legitimate fallback — but it must not present one supply twice.
        let recipe = Recipe(
            title: "Apfelkuchen",
            servings: 4,
            ingredientsText: """
            150 g Butter
            150 g Butter
            1 kg Äpfel
            """,
            instructionsText: "Die Butter mit den Äpfeln verrühren."
        )
        let step = recipe.steps[0]
        let resolution = StepAmountResolver.resolve(recipe, toServings: 8, formatter: formatter)
        let chips = recipe.ingredients(mentionedIn: step, resolution: resolution, scaledToServings: 8)

        #expect(chips.count == 2)
        let butter = chips.first { $0.name == "Butter" }
        #expect(butter?.quantity == Quantity(600, .gram))  // 2 × 150 g, at double servings
        #expect(chips.contains { $0.name == "Äpfel" })
    }

    @Test("An ingredient named only in an exclusion clause is not offered as a fallback chip")
    func fallbackChipSkipsNegatedMentions() {
        let recipe = Recipe(
            title: "Pesto",
            servings: 2,
            ingredientsText: """
            80 g getrocknete Tomate
            40 ml Olivenöl
            30 g Pinienkerne
            """,
            instructionsText: "Die getrocknete Tomate (abgesehen vom Olivenöl und paar Pinienkerne) in einen Mixer geben."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        let chips = recipe.ingredients(mentionedIn: recipe.steps[0], resolution: resolution)

        // Without the negation check, both would show up as bare mentions —
        // even though the step explicitly says not to use them here.
        #expect(!chips.contains { $0.name == "Olivenöl" })
        #expect(!chips.contains { $0.name == "Pinienkerne" })
        #expect(chips.contains { $0.name == "getrocknete Tomate" })
    }

    @Test("A name already followed by a written parenthetical amount is not repeated as a fallback chip")
    func fallbackChipSkipsAlreadyAnsweredMentions() {
        // "Olivenöl (40 ml)" is the shape Mela imports write, and the shape
        // this app's own review sheet writes too. The regex scanner reads
        // this order too (see `AmountMentionScanner.parenthesizedMentions`),
        // so it is bound like any other mention — but even a step naming an
        // ingredient this way without a recognizable amount at all (guarded
        // by `isAlreadyAnswered`, not exercised by this specific fixture
        // anymore) must not repeat what the sentence already says right
        // next to it.
        let recipe = Recipe(
            title: "Pesto",
            servings: 2,
            ingredientsText: "40 ml Olivenöl",
            instructionsText: "Olivenöl (40 ml) hinzufügen und noch einmal kurz mixen."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        let chips = recipe.ingredients(mentionedIn: recipe.steps[0], resolution: resolution)
        #expect(!chips.contains { $0.name == "Olivenöl" })
    }

    @Test("Same-name lines whose units cannot be added stay in separate pots — and stay ambiguous")
    func unaddableSameNameLinesStaySeparate() {
        let recipe = Recipe(
            title: "Ofengemüse",
            servings: 2,
            ingredientsText: """
            1 Prise Salz
            1 TL Salz
            """,
            instructionsText: "Restliches Salz darüber streuen."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        let segments = resolution.segments(for: recipe.steps[0])
        // Two pots could be meant, so "restliches" resolves against neither.
        #expect(!segments.contains { if case .amount = $0 { true } else { false } })
    }
}

@Suite("Amounts written after the name, in parentheses")
struct ParenthesizedAmountTests {
    private let formatter = QuantityFormatter(locale: Locale(identifier: "de_DE"))

    private func segmentsText(_ segments: [StepAmountSegment]) -> [String] {
        segments.map { segment in
            switch segment {
            case .text(let s): "text(\(s))"
            case .amount(let s): "amount(\(s))"
            }
        }
    }

    @Test("Resolves live and trusted, exactly like the forward order — no AI, no confirmation needed")
    func resolvesLiveWithoutAI() {
        let recipe = Recipe(
            title: "Ajvar-Suppe",
            servings: 4,
            ingredientsText: "3 EL Rapsöl",
            instructionsText: "Etwas Rapsöl (3 EL) in einem flachen Topf erhitzen."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 4, formatter: formatter)
        #expect(resolution.allSuggestions.isEmpty)
        #expect(segmentsText(resolution.segments(for: recipe.steps[0])).contains("amount(3 EL)"))
    }

    @Test("A two-word name is matched by the words closest to the parenthesis, not cut off after the first")
    func multiWordNameMatches() {
        let recipe = Recipe(
            title: "Salat",
            servings: 2,
            ingredientsText: "200 g Rote Bete",
            instructionsText: "Die gewaschene Rote Bete (200 g) grob raspeln."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        #expect(segmentsText(resolution.segments(for: recipe.steps[0])).contains("amount(200 g)"))
    }

    @Test("A bare count with no unit word in the parentheses still resolves")
    func bareCountInParensResolves() {
        let recipe = Recipe(
            title: "Ajvar-Suppe",
            servings: 4,
            ingredientsText: "2 Zwiebel",
            instructionsText: "Zwiebel (2) pellen, halbieren und in feine Streifen schneiden."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 4, formatter: formatter)
        #expect(segmentsText(resolution.segments(for: recipe.steps[0])).contains("amount(2)"))
    }

    @Test("A recognized imprecise unit resolves against a pot in the same unit — 'Zehe' needs no shared base, just a ratio")
    func recognizedNonMetricUnitResolves() {
        // "Zehe" (like "Blatt", "Bund", "Prise") has no `baseUnitFactor` —
        // `Quantity.inBaseUnit` is `nil` for it — but matching against a
        // pot already totalled in the very same unit needs no conversion
        // at all, only a direct ratio (`fraction(for:against:)`'s
        // same-unit fast path). Forward order resolves exactly the same
        // way; this is the real recipe the resurfacing-findings bug and
        // the "Name (Menge)" regex extension were both found against.
        let recipe = Recipe(
            title: "Ajvar-Suppe",
            servings: 4,
            ingredientsText: "1 Zehe Knoblauch",
            instructionsText: "Knoblauch (1 Zehe) ebenfalls pellen und in feine Streifen schneiden."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 4, formatter: formatter)
        #expect(segmentsText(resolution.segments(for: recipe.steps[0])).contains("amount(1 Zehe)"))
    }

    @Test("A partial share of an imprecise-unit pot resolves to a genuine fraction, not the whole pot")
    func imprecisePartialShareResolves() {
        let recipe = Recipe(
            title: "Ajvar-Suppe",
            servings: 4,
            ingredientsText: "3 Zehe Knoblauch",
            instructionsText: "Knoblauch (1 Zehe) andünsten, den restlichen Knoblauch später dazugeben."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 4, formatter: formatter)
        let segments = segmentsText(resolution.segments(for: recipe.steps[0]))
        #expect(segments.contains("amount(1 Zehe)"))
        #expect(segments.contains("amount(2 Zehe)"))
    }

    @Test("A word in parentheses that is not a recognized unit is left alone — not every parenthetical is an amount")
    func unrecognizedWordInParensIsNotAMention() {
        let recipe = Recipe(
            title: "Gulasch",
            servings: 2,
            ingredientsText: "750 g Rindfleisch",
            instructionsText: "Das Rindfleisch scharf anbraten (ca. 5 Minuten)."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        #expect(!resolution.segments(for: recipe.steps[0]).contains { if case .amount = $0 { true } else { false } })
        // Falls through to the ordinary bare-mention path instead of being
        // silently dropped — "Rindfleisch" still gets offered for review.
        #expect(resolution.suggestions(for: recipe.steps[0]).contains { $0.ingredientName == "Rindfleisch" })
    }

    @Test("Scales with servings like any other resolved amount")
    func scalesWithServings() {
        let recipe = Recipe(
            title: "Ajvar-Suppe",
            servings: 4,
            ingredientsText: "750 g Hackfleisch",
            instructionsText: "Das Hackfleisch (750 g) scharf anbraten."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 8, formatter: formatter)
        #expect(segmentsText(resolution.segments(for: recipe.steps[0])).contains("amount(1,5 kg)"))
    }
}

@Suite("Suggesting amounts for bare mentions")
struct AmountSuggestionTests {
    private let formatter = QuantityFormatter(locale: Locale(identifier: "de_DE"))

    @Test("A name at the start of a step gets a suggestion right after it")
    func nameAtStart() {
        let recipe = Recipe(
            title: "Kartoffelpüree",
            servings: 2,
            ingredientsText: "150 g Butter",
            instructionsText: "Butter erhitzen und die Kartoffeln stampfen."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        let suggestions = resolution.suggestions(for: recipe.steps[0])
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.ingredientName == "Butter")
        #expect(suggestions.first?.displayAmount == "150 g")
    }

    @Test("A name in the middle and one at the end both get found")
    func nameInMiddleAndEnd() {
        let recipe = Recipe(
            title: "Kartoffelpüree",
            servings: 2,
            ingredientsText: """
            1 kg Kartoffeln
            150 g Butter
            """,
            instructionsText: "Die Kartoffeln kochen, dann mit der Butter stampfen."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        let names = Set(resolution.suggestions(for: recipe.steps[0]).map(\.ingredientName))
        #expect(names == ["Kartoffeln", "Butter"])
    }

    @Test("An ingredient never named in the step gets no suggestion")
    func nameNotPresent() {
        let recipe = Recipe(
            title: "Kartoffelpüree",
            servings: 2,
            ingredientsText: """
            1 kg Kartoffeln
            1 Ei
            """,
            instructionsText: "Die Kartoffeln kochen."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        let names = resolution.suggestions(for: recipe.steps[0]).map(\.ingredientName)
        #expect(!names.contains("Ei"))
    }

    @Test("A name mentioned twice in one step only gets one suggestion")
    func nameTwiceInOneStep() {
        let recipe = Recipe(
            title: "Kartoffelpüree",
            servings: 2,
            ingredientsText: "150 g Butter",
            instructionsText: "Die Butter erhitzen, dann noch mehr Butter dazugeben."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        #expect(resolution.suggestions(for: recipe.steps[0]).count == 1)
    }

    @Test("An amount already resolved for a pot in this step gets no extra suggestion")
    func alreadyResolvedGetsNoSuggestion() {
        let recipe = Recipe(
            title: "Kartoffelpüree",
            servings: 2,
            ingredientsText: "150 g Butter",
            instructionsText: "150 g Butter erhitzen."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        #expect(resolution.suggestions(for: recipe.steps[0]).isEmpty)
    }

    @Test("Inflected forms are found via the catalog, same as a written amount would be")
    func inflectedFormMatches() {
        let recipe = Recipe(
            title: "Zwiebelsuppe",
            servings: 2,
            ingredientsText: "4 Zwiebeln",
            instructionsText: "Die Zwiebeln fein würfeln."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        #expect(resolution.suggestions(for: recipe.steps[0]).count == 1)
    }

    @Test("allSuggestions counts across every step")
    func allSuggestionsAcrossSteps() {
        let recipe = Recipe(
            title: "Test",
            servings: 2,
            ingredientsText: """
            1 kg Kartoffeln
            150 g Butter
            """,
            instructionsText: """
            Die Kartoffeln kochen.
            Die Butter erhitzen.
            """
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        #expect(resolution.allSuggestions.count == 2)
    }

    @Test("Accepting a suggestion inserts the amount right after the name, group headings included")
    func applyingInsertsTheAmount() {
        let recipe = Recipe(
            title: "Kuchen",
            servings: 4,
            ingredientsText: """
            # Für den Teig
            300 g Mehl
            # Für den Belag
            200 g Äpfel
            """,
            instructionsText: """
            # Für den Teig
            Das Mehl zu einem Teig verkneten.
            # Für den Belag
            Die Äpfel darauf verteilen.
            """
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 8, formatter: formatter)
        let all = resolution.allSuggestions
        #expect(all.count == 2)

        let updated = resolution.applying(Set(all.map(\.id)), to: recipe)
        #expect(updated.instructionsText.contains("Das Mehl (600 g) zu einem Teig verkneten."))
        #expect(updated.instructionsText.contains("Die Äpfel (400 g) darauf verteilen."))
        // The group structure survives the round trip through `StepParser`.
        #expect(updated.instructionsText.contains("# Für den Teig"))
        #expect(updated.instructionsText.contains("# Für den Belag"))

        // Applying against the recipe it was computed from is now settled —
        // resolving the updated recipe finds the amounts inline, no
        // suggestions left over.
        let newResolution = StepAmountResolver.resolve(updated, toServings: 8, formatter: formatter)
        #expect(newResolution.allSuggestions.isEmpty)
    }

    @Test("Accepting only some suggestions leaves the rest untouched")
    func applyingOnlySomeSuggestions() {
        let recipe = Recipe(
            title: "Test",
            servings: 2,
            ingredientsText: """
            1 kg Kartoffeln
            150 g Butter
            """,
            instructionsText: """
            Die Kartoffeln kochen.
            Die Butter erhitzen.
            """
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        let kartoffelnSuggestion = resolution.allSuggestions.first { $0.ingredientName == "Kartoffeln" }!

        let updated = resolution.applying([kartoffelnSuggestion.id], to: recipe)
        #expect(updated.instructionsText.contains("Die Kartoffeln (1 kg) kochen."))
        #expect(updated.instructionsText.contains("Die Butter erhitzen."))
        #expect(!updated.instructionsText.contains("Die Butter (150 g)"))
    }

    @Test("An empty accepted set changes nothing")
    func applyingNothingChangesNothing() {
        let recipe = Recipe(
            title: "Kartoffelpüree",
            servings: 2,
            ingredientsText: "150 g Butter",
            instructionsText: "Die Butter erhitzen."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        let updated = resolution.applying([], to: recipe)
        #expect(updated.instructionsText == recipe.instructionsText)
    }

    @Test("A name only mentioned inside an exclusion clause gets no suggestion")
    func nameOnlyInNegatedClauseGetsNoSuggestion() {
        let recipe = Recipe(
            title: "Pesto",
            servings: 2,
            ingredientsText: """
            80 g getrocknete Tomate
            40 ml Olivenöl
            """,
            instructionsText: "Alles Zutaten (abgesehen vom Olivenöl) in einen Mixer geben."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        let names = resolution.suggestions(for: recipe.steps[0]).map(\.ingredientName)
        #expect(!names.contains("Olivenöl"))
    }

    @Test("A name mentioned both inside and outside an exclusion clause still gets a suggestion for the unnegated occurrence")
    func nameOutsideNegatedClauseStillSuggests() {
        let recipe = Recipe(
            title: "Pesto",
            servings: 2,
            ingredientsText: "40 ml Olivenöl",
            instructionsText: "Alles (abgesehen vom Olivenöl) mixen, dann das Olivenöl unterrühren."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        #expect(resolution.suggestions(for: recipe.steps[0]).count == 1)
    }
}

@Suite("AI-found amounts stay proposals until confirmed")
struct AmountAIProposalTests {
    private let formatter = QuantityFormatter(locale: Locale(identifier: "de_DE"))

    @Test("A fraction word only AI can read resolves to a suggestion, never live text")
    func aiFractionBecomesASuggestionNotLiveText() throws {
        let recipe = Recipe(
            title: "Ofengemüse",
            servings: 2,
            ingredientsText: "300 g Paprika",
            instructionsText: "Ein Drittel der Paprika in Scheiben schneiden."
        )
        let claim = ExtractedQuantity(
            quantityText: "Ein Drittel", modifiedNoun: "Paprika", kind: .fraction, fractionValue: 1.0 / 3.0, stepNumber: 1
        )
        let mentions = AmountAIExtractor.mentions(from: [claim], steps: recipe.steps)

        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, additionalMentions: mentions, formatter: formatter)
        let segments = resolution.segments(for: recipe.steps[0])
        #expect(!segments.contains { if case .amount = $0 { true } else { false } })

        // Only the AI proposal — bound the pot too, so no duplicate
        // bare-name suggestion for the same "Paprika" also shows up.
        let suggestions = resolution.suggestions(for: recipe.steps[0])
        let suggestion = try #require(suggestions.first)
        #expect(suggestions.count == 1)
        #expect(suggestion.ingredientName == "Paprika")
        #expect(suggestion.displayAmount == "100 g")
        guard case .aiExtracted(let writtenText) = suggestion.origin else {
            Issue.record("Expected an AI-extracted origin, got \(suggestion.origin)")
            return
        }
        #expect(writtenText == "Ein Drittel")
    }

    @Test("Accepting an AI suggestion without a correction writes the computed amount in")
    func acceptingWithoutCorrectionUsesTheComputedAmount() throws {
        let recipe = Recipe(
            title: "Ofengemüse",
            servings: 2,
            ingredientsText: "300 g Paprika",
            instructionsText: "Ein Drittel der Paprika in Scheiben schneiden."
        )
        let claim = ExtractedQuantity(
            quantityText: "Ein Drittel", modifiedNoun: "Paprika", kind: .fraction, fractionValue: 1.0 / 3.0, stepNumber: 1
        )
        let mentions = AmountAIExtractor.mentions(from: [claim], steps: recipe.steps)
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, additionalMentions: mentions, formatter: formatter)
        let suggestion = try #require(resolution.suggestions(for: recipe.steps[0]).first)

        let updated = resolution.applying([suggestion.id], to: recipe)
        #expect(updated.instructionsText.contains("Ein Drittel der Paprika (100 g) in Scheiben schneiden."))

        // Settled: resolving the updated recipe again finds no suggestions
        // left over for this text.
        let newResolution = StepAmountResolver.resolve(updated, toServings: 2, formatter: formatter)
        #expect(newResolution.allSuggestions.isEmpty)
    }

    @Test("Correcting an AI suggestion writes the corrected text instead of the computed amount")
    func correctingAnAISuggestionOverridesTheComputedAmount() throws {
        let recipe = Recipe(
            title: "Ofengemüse",
            servings: 2,
            ingredientsText: "300 g Paprika",
            instructionsText: "Ein Drittel der Paprika in Scheiben schneiden."
        )
        let claim = ExtractedQuantity(
            quantityText: "Ein Drittel", modifiedNoun: "Paprika", kind: .fraction, fractionValue: 1.0 / 3.0, stepNumber: 1
        )
        let mentions = AmountAIExtractor.mentions(from: [claim], steps: recipe.steps)
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, additionalMentions: mentions, formatter: formatter)
        let suggestion = try #require(resolution.suggestions(for: recipe.steps[0]).first)

        let updated = resolution.applying([suggestion.id], corrections: [suggestion.id: "90 g"], to: recipe)
        #expect(updated.instructionsText.contains("Ein Drittel der Paprika (90 g) in Scheiben schneiden."))
        #expect(!updated.instructionsText.contains("100 g"))
    }

    @Test("An AI-found amount written in 'name (amount)' order but not enclosed in parentheses — unreadable to regex — replaces rather than inserts")
    func aiFoundWrittenAmountReplacesInPlace() throws {
        let recipe = Recipe(
            title: "Pesto",
            servings: 2,
            ingredientsText: "40 ml Olivenöl",
            instructionsText: "Olivenöl, 40 ml, unterrühren."
        )
        let claim = ExtractedQuantity(
            quantityText: "40 ml", modifiedNoun: "Olivenöl", kind: .absolute, fractionValue: nil, stepNumber: 1
        )
        let mentions = AmountAIExtractor.mentions(from: [claim], steps: recipe.steps)

        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, additionalMentions: mentions, formatter: formatter)
        // Regex alone cannot read this word order — no live `.amount()`
        // segment appears without the AI claim — confirming the fixture
        // exercises the AI path, not a regex mention in disguise. (Regex's
        // own bare-mention fallback still offers "Olivenöl" on its own,
        // unrelated to what this test is about.)
        let regexOnly = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        #expect(!regexOnly.segments(for: recipe.steps[0]).contains { if case .amount = $0 { true } else { false } })

        let suggestion = try #require(resolution.suggestions(for: recipe.steps[0]).first { $0.origin != .unmentioned })
        let updated = resolution.applying([suggestion.id], corrections: [suggestion.id: "45 ml"], to: recipe)
        #expect(updated.instructionsText.contains("Olivenöl, 45 ml, unterrühren."))
    }

    @Test("An AI-found amount already enclosed in parentheses is trusted, not flagged — a person or a prior confirmation already made it unambiguous")
    func aiClaimAlreadyEnclosedInParensIsNotFlaggedAgain() throws {
        let recipe = Recipe(
            title: "Pesto",
            servings: 2,
            ingredientsText: "40 ml Olivenöl",
            instructionsText: "Olivenöl (40 ml) unterrühren."
        )
        let claim = ExtractedQuantity(
            quantityText: "40 ml", modifiedNoun: "Olivenöl", kind: .absolute, fractionValue: nil, stepNumber: 1
        )
        let mentions = AmountAIExtractor.mentions(from: [claim], steps: recipe.steps)

        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, additionalMentions: mentions, formatter: formatter)
        #expect(resolution.suggestions(for: recipe.steps[0]).isEmpty)
        // Still bound — the pot is accounted for, just never rendered live.
        #expect(resolution.mentionsAmount(of: recipe.ingredients[0], in: recipe.steps[0]))
    }

    @Test("Rewording the sentence around an already-confirmed amount does not resurface it as a new finding")
    func rewordingAroundAConfirmedAmountDoesNotReflagIt() throws {
        // The reported bug: two amounts already written in, in the exact
        // shape a prior review-sheet acceptance leaves behind, survive a
        // wording edit to the rest of the sentence — the model re-reads
        // "Rapsöl (3 EL)" and "Hackfleisch (750 g)" fresh on every
        // enrichment pass, and without the parenthesis check both would
        // reappear as unconfirmed suggestions after every such edit.
        let recipe = Recipe(
            title: "Ajvar-Suppe",
            servings: 4,
            ingredientsText: """
            750 g Hackfleisch
            3 EL Rapsöl
            """,
            instructionsText: "Für die Suppe etwas Rapsöl (3 EL) in einem flachen Topf erhitzen und das Hackfleisch (750 g) für 2-5 Minuten scharf anbraten."
        )
        let claims = [
            ExtractedQuantity(quantityText: "3 EL", modifiedNoun: "Rapsöl", kind: .absolute, fractionValue: nil, stepNumber: 1),
            ExtractedQuantity(quantityText: "750 g", modifiedNoun: "Hackfleisch", kind: .absolute, fractionValue: nil, stepNumber: 1),
        ]
        let mentions = AmountAIExtractor.mentions(from: claims, steps: recipe.steps)

        let resolution = StepAmountResolver.resolve(recipe, toServings: 4, additionalMentions: mentions, formatter: formatter)
        #expect(resolution.allSuggestions.isEmpty)
    }

    // MARK: - Head-noun matching

    @Test("The head noun a written name answers to in running text")
    func headWords() {
        #expect(StepAmountResolver.headWord(of: "rote Zwiebel") == "Zwiebel")
        #expect(StepAmountResolver.headWord(of: "Dose Kokosmilch") == "Kokosmilch")
        #expect(StepAmountResolver.headWord(of: "frisch geriebener Ingwer") == "Ingwer")
        #expect(StepAmountResolver.headWord(of: "Limette, Saft davon") == "Limette")
        #expect(StepAmountResolver.headWord(of: "dicke Kokosmilch / Kokoscreme") == "Kokosmilch")
        #expect(StepAmountResolver.headWord(of: "Fett für die Form") == "Fett")
        #expect(StepAmountResolver.headWord(of: "Petersilie (optional)") == "Petersilie")
        // A qualifier written after the noun does not become the head —
        // the last capitalized word is the noun.
        #expect(StepAmountResolver.headWord(of: "Paprika rot") == "Paprika")
        #expect(StepAmountResolver.headWord(of: "Weißwein trocken") == "Weißwein")
        // An unspaced slash is a plural marker, not an alternative.
        #expect(StepAmountResolver.headWord(of: "Zehe/n Knoblauch") == "Knoblauch")
        // A grading qualifies rather than names.
        #expect(StepAmountResolver.headWord(of: "Weizenmehl Type 405") == "Weizenmehl")
        // A single word has no separate head, and neither does a head too
        // short to stand for anything.
        #expect(StepAmountResolver.headWord(of: "Zwiebel") == nil)
        #expect(StepAmountResolver.headWord(of: "Kokosöl") == nil)
        #expect(StepAmountResolver.headWord(of: "2 x Öl") == nil)
    }

    @Test("A step naming just the head noun binds its amount against the qualified line")
    func amountBindsThroughHeadNoun() {
        let recipe = Recipe(
            title: "Ala Hodi",
            servings: 4,
            ingredientsText: "500 g festkochende Kartoffeln",
            instructionsText: "300 g Kartoffeln in Stücke schneiden."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 8, formatter: formatter)
        let text = resolution.segments(for: recipe.steps[0]).map { segment in
            switch segment {
            case .text(let s), .amount(let s): s
            }
        }.joined()
        #expect(text.contains("600 g"))
        #expect(resolution.mentionsAmount(of: recipe.ingredients[0], in: recipe.steps[0]))
    }

    @Test("A bare head-noun mention earns the chip and the suggestion the full name used to miss")
    func bareHeadNounEarnsChipAndSuggestion() {
        let recipe = Recipe(
            title: "Ala Hodi",
            servings: 4,
            ingredientsText: """
            2 rote Zwiebeln
            1 TL Kurkuma
            """,
            instructionsText: "Die Zwiebeln würfeln und glasig dünsten."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 4, formatter: formatter)
        let chips = recipe.ingredients(mentionedIn: recipe.steps[0], resolution: resolution)
        #expect(chips.map(\.name) == ["rote Zwiebeln"])
        #expect(resolution.suggestions(for: recipe.steps[0]).map(\.ingredientName) == ["rote Zwiebeln"])
    }

    @Test("A line saying exactly the head noun owns it — the qualified line does not steal the mention")
    func exactNameOutranksHeadNoun() {
        let recipe = Recipe(
            title: "Zwiebelkuchen",
            servings: 4,
            ingredientsText: """
            1 rote Zwiebel
            2 Zwiebeln
            """,
            instructionsText: "Die Zwiebeln würfeln."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 4, formatter: formatter)
        let chips = recipe.ingredients(mentionedIn: recipe.steps[0], resolution: resolution)
        #expect(chips.map(\.name) == ["Zwiebeln"])
        #expect(resolution.suggestions(for: recipe.steps[0]).map(\.ingredientName) == ["Zwiebeln"])
    }

    // MARK: - Compound heads

    @Test("A bare 'Öl' binds its amount against the one oil the list has")
    func compoundHeadBindsAmount() {
        let recipe = Recipe(
            title: "Pfanne",
            servings: 4,
            ingredientsText: "2 EL Olivenöl",
            instructionsText: "1 EL Öl in der Pfanne erhitzen."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 8, formatter: formatter)
        let text = resolution.segments(for: recipe.steps[0]).map { segment in
            switch segment {
            case .text(let s), .amount(let s): s
            }
        }.joined()
        #expect(text.contains("2 EL Öl"))
        #expect(resolution.mentionsAmount(of: recipe.ingredients[0], in: recipe.steps[0]))
    }

    @Test("Two oils on the list, and a bare 'Öl' means neither")
    func ambiguousCompoundHeadBindsNothing() {
        let recipe = Recipe(
            title: "Pfanne",
            servings: 4,
            ingredientsText: """
            2 EL Olivenöl
            2 EL Rapsöl
            """,
            instructionsText: """
            1 EL Öl in der Pfanne erhitzen.
            Mit dem Öl beträufeln.
            """
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 4, formatter: formatter)
        #expect(!resolution.mentionsAmount(of: recipe.ingredients[0], in: recipe.steps[0]))
        #expect(!resolution.mentionsAmount(of: recipe.ingredients[1], in: recipe.steps[0]))
        #expect(resolution.suggestions(for: recipe.steps[1]).isEmpty)
        #expect(recipe.ingredients(mentionedIn: recipe.steps[1], resolution: resolution).isEmpty)
    }

    @Test("A bare head noun earns the compound line its chip and suggestion")
    func compoundHeadEarnsChipAndSuggestion() {
        let recipe = Recipe(
            title: "Curry",
            servings: 4,
            ingredientsText: """
            500 ml Gemüsebrühe
            200 g Räuchertofu
            """,
            instructionsText: """
            Den Tofu würfeln und anbraten.
            Mit der Brühe ablöschen.
            """
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 4, formatter: formatter)
        let chips1 = recipe.ingredients(mentionedIn: recipe.steps[0], resolution: resolution)
        #expect(chips1.map(\.name) == ["Räuchertofu"])
        let chips2 = recipe.ingredients(mentionedIn: recipe.steps[1], resolution: resolution)
        #expect(chips2.map(\.name) == ["Gemüsebrühe"])
        #expect(resolution.suggestions(for: recipe.steps[0]).map(\.ingredientName) == ["Räuchertofu"])
        #expect(resolution.suggestions(for: recipe.steps[1]).map(\.ingredientName) == ["Gemüsebrühe"])
    }

    @Test("A line saying exactly 'Öl' owns the word — and matches it standing alone, not inside 'Kokosöl'")
    func shortNameMatchesOnlyAsAWholeWord() {
        let recipe = Recipe(
            title: "Pfanne",
            servings: 4,
            ingredientsText: """
            2 EL Öl
            1 EL Kokosöl
            """,
            instructionsText: """
            Das Öl erhitzen.
            Das Kokosöl schmelzen.
            """
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 4, formatter: formatter)
        let chips1 = recipe.ingredients(mentionedIn: recipe.steps[0], resolution: resolution)
        #expect(chips1.map(\.name) == ["Öl"])
        let chips2 = recipe.ingredients(mentionedIn: recipe.steps[1], resolution: resolution)
        #expect(chips2.map(\.name) == ["Kokosöl"])
    }

    // MARK: - Bundles

    @Test("A step saying 'Tomaten' binds its amount against the one variant the list has")
    func bundleBindsAmount() {
        let recipe = Recipe(
            title: "Salat",
            servings: 4,
            ingredientsText: "250 g Kirschtomaten",
            instructionsText: "100 g Tomaten halbieren."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 8, formatter: formatter)
        let text = resolution.segments(for: recipe.steps[0]).map { segment in
            switch segment {
            case .text(let s), .amount(let s): s
            }
        }.joined()
        #expect(text.contains("200 g"))
        #expect(resolution.mentionsAmount(of: recipe.ingredients[0], in: recipe.steps[0]))
    }

    @Test("A bare parent name earns the variant line its chip and suggestion")
    func bundleEarnsChipAndSuggestion() {
        let recipe = Recipe(
            title: "Salat",
            servings: 4,
            ingredientsText: """
            250 g Kirschtomaten
            1 TL Salz
            """,
            instructionsText: "Die Tomaten halbieren."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 4, formatter: formatter)
        let chips = recipe.ingredients(mentionedIn: recipe.steps[0], resolution: resolution)
        #expect(chips.map(\.name) == ["Kirschtomaten"])
        #expect(resolution.suggestions(for: recipe.steps[0]).map(\.ingredientName) == ["Kirschtomaten"])
    }

    @Test("Two variants of the same bundle, and the parent name means neither")
    func ambiguousBundleBindsNothing() {
        let recipe = Recipe(
            title: "Salat",
            servings: 4,
            ingredientsText: """
            250 g Kirschtomaten
            2 Strauchtomaten
            """,
            instructionsText: "Die Tomaten halbieren."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 4, formatter: formatter)
        #expect(recipe.ingredients(mentionedIn: recipe.steps[0], resolution: resolution).isEmpty)
        #expect(resolution.suggestions(for: recipe.steps[0]).isEmpty)
    }

    @Test("An exclusion ends with the noun it excludes — what follows is back in play")
    func exclusionEndsAtItsNoun() {
        let recipe = Recipe(
            title: "Tofusalat",
            servings: 4,
            ingredientsText: """
            2 EL Pinienkerne
            1 EL Fett
            """,
            instructionsText: "In einer Pfanne ohne Fett Pinienkerne anrösten."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 4, formatter: formatter)
        let chips = recipe.ingredients(mentionedIn: recipe.steps[0], resolution: resolution)
        #expect(chips.map(\.name) == ["Pinienkerne"])
        #expect(resolution.suggestions(for: recipe.steps[0]).map(\.ingredientName) == ["Pinienkerne"])
    }

    // MARK: - Compound stems

    @Test("A step calling the seeds by their plant reaches the line — chip, suggestion, and amount")
    func compoundStemReachesTheLine() {
        let recipe = Recipe(
            title: "Ala Hodi",
            servings: 4,
            ingredientsText: """
            1 TL Bockshornkleesamen
            1 TL Kurkuma
            """,
            instructionsText: """
            Den Bockshornklee darin anrösten, bis er duftet.
            ½ TL Bockshornklee zum Schluss unterrühren.
            """
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 4, formatter: formatter)
        let chips = recipe.ingredients(mentionedIn: recipe.steps[0], resolution: resolution)
        #expect(chips.map(\.name) == ["Bockshornkleesamen"])
        #expect(resolution.suggestions(for: recipe.steps[0]).map(\.ingredientName) == ["Bockshornkleesamen"])
        #expect(resolution.mentionsAmount(of: recipe.ingredients[0], in: recipe.steps[1]))
    }

    @Test("A line saying exactly the word owns it — the powder never steals the onions")
    func exactNameOutranksCompoundStem() {
        let recipe = Recipe(
            title: "Gewürzmischung",
            servings: 4,
            ingredientsText: """
            2 Zwiebeln
            1 TL Zwiebelpulver
            """,
            instructionsText: "Die Zwiebeln würfeln und glasig dünsten."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 4, formatter: formatter)
        let chips = recipe.ingredients(mentionedIn: recipe.steps[0], resolution: resolution)
        #expect(chips.map(\.name) == ["Zwiebeln"])
        #expect(resolution.suggestions(for: recipe.steps[0]).map(\.ingredientName) == ["Zwiebeln"])
    }

    @Test("A line saying exactly the parent owns it — the variant does not steal the mention")
    func exactParentOutranksBundle() {
        let recipe = Recipe(
            title: "Salat",
            servings: 4,
            ingredientsText: """
            3 Tomaten
            250 g Kirschtomaten
            """,
            instructionsText: "Die Tomaten würfeln."
        )
        let resolution = StepAmountResolver.resolve(recipe, toServings: 4, formatter: formatter)
        let chips = recipe.ingredients(mentionedIn: recipe.steps[0], resolution: resolution)
        #expect(chips.map(\.name) == ["Tomaten"])
        #expect(resolution.suggestions(for: recipe.steps[0]).map(\.ingredientName) == ["Tomaten"])
    }
}
