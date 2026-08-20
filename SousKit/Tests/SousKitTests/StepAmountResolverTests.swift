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

    @Test("A second noun under one shared 'restlichen' — which regex alone can never reach — resolves via a supplementary mention")
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
        #expect(rendered.contains("amount(4)"))  // Zwiebeln, found by regex
        #expect(rendered.contains("amount(6)"))  // Karotten, only found via the supplementary mention
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
        // beneath either step.
        let butterLines = recipe.ingredients.filter { $0.name == "Butter" }
        #expect(butterLines.count == 2)
        for butter in butterLines {
            #expect(resolution.mentionsAmount(of: butter, in: steps[0]))
            #expect(resolution.mentionsAmount(of: butter, in: steps[1]))
        }
        #expect(recipe.ingredients(mentionedIn: steps[0], resolution: resolution, scaledToServings: 8).isEmpty)
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
        // this app's own review sheet writes too — either way, the regex
        // scanner never reads it as a mention (it only understands "amount
        // name" order), so without this check the chip would repeat what
        // the sentence already says right next to it.
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
