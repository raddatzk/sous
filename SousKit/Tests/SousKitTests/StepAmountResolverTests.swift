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

    /// `marks(for:)` reported as "kind(the words it sits under)", so a test
    /// reads as what the editor would draw.
    private func markedText(_ marks: [StepTextMark], in step: RecipeStep) -> [String] {
        marks.map { "\($0.kind)(\(step.text[$0.range]))" }
    }

    @Test("Every mark sits under the words it was made of")
    func marksSitUnderTheirOwnWords() {
        let recipe = Recipe(
            title: "Kartoffelpfanne",
            servings: 4,
            ingredientsText: """
            1 kg Kartoffel
            2 Zwiebeln
            """,
            instructionsText: """
            300 g Kartoffeln 7 Minuten köcheln lassen.
            Die Hälfte der Zwiebeln fein würfeln.
            Zwiebeln und Kartoffeln anbraten.
            """
        )
        let steps = recipe.steps
        let resolution = StepAmountResolver.resolve(recipe, toServings: 4, formatter: formatter)

        // A written share, marked over what was written — not over the
        // number that will be drawn in its place.
        #expect(markedText(resolution.marks(for: steps[0]), in: steps[0]) == ["bound(300 g)"])
        // The scanner's span, trimmed to its ink: "Hälfte der " loses its
        // trailing space, and "Die" was never part of what it read.
        #expect(markedText(resolution.marks(for: steps[1]), in: steps[1]) == ["bound(Hälfte der)"])

        // The third step names both lines with something left of each:
        // each takes what is left, marked over its own name.
        let bare = markedText(resolution.marks(for: steps[2]), in: steps[2])
        #expect(bare == ["bound(Zwiebeln)", "bound(Kartoffeln)"])
    }

    @Test("A number belonging to no ingredient line is marked loose, not bound")
    func numberWithoutALineIsLoose() {
        let recipe = Recipe(
            title: "Nudeln",
            servings: 2,
            ingredientsText: "500 g Nudeln",
            instructionsText: "200 ml Weißwein angießen."
        )
        let step = recipe.steps[0]
        let marks = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter).marks(for: step)

        #expect(markedText(marks, in: step) == ["loose(200 ml)"])
    }

    @Test("A bare mention takes the whole line, marked over its name, as a chip beneath the step")
    func bareMentionTakesTheWholeLine() {
        let recipe = Recipe(
            title: "Nudeln",
            servings: 2,
            ingredientsText: "500 g Nudeln",
            instructionsText: "Nudeln abgießen."
        )
        let step = recipe.steps[0]
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        #expect(markedText(resolution.marks(for: step), in: step) == ["bound(Nudeln)"])
        #expect(resolution.segments(for: step) == [.text("Nudeln abgießen.")])
        let chips = recipe.ingredients(mentionedIn: step, resolution: resolution)
        #expect(chips.map(\.name) == ["Nudeln"])
        #expect(chips.first?.quantity == Quantity(500, .gram))
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

        // Relative wording stays as written; the amount is the chip beneath.
        #expect(resolution.segments(for: steps[1]) == [.text(steps[1].text)])
        let step2Chips = recipe.ingredients(mentionedIn: steps[1], resolution: resolution, scaledToServings: 12)
        #expect(step2Chips.map(\.name) == ["Kartoffel"])
        #expect(step2Chips.first?.quantity.map { formatter.string(for: $0) } == "2,1 kg")

        #expect(resolution.segments(for: steps[2]) == [.text(steps[2].text)])
        let step3Chips = recipe.ingredients(mentionedIn: steps[2], resolution: resolution, scaledToServings: 12)
        #expect(step3Chips.map(\.name) == ["Zwiebeln"])
        #expect(step3Chips.first?.quantity?.amount == 3)

        // The chip beneath a step loses the ingredient whose amount is
        // part of the sentence.
        let kartoffel = recipe.ingredients.first { $0.name == "Kartoffel" }!
        #expect(resolution.mentionsAmount(of: kartoffel, in: steps[0]))
        #expect(recipe.ingredients(mentionedIn: steps[0], scaledToServings: 12).isEmpty)
    }

    @Test("A relative amount leaves the sentence as written and becomes a chip")
    func relativeAmountBecomesAChip() {
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
        let step = recipe.steps[1]
        // "Restlichen" already reads correctly at every serving count, so
        // nothing is put into the sentence — the chip says what it is.
        #expect(resolution.segments(for: step) == [.text("Restlichen Kartoffeln nur schälen.")])
        #expect(markedText(resolution.marks(for: step), in: step) == ["bound(Restlichen)"])
        let chips = recipe.ingredients(mentionedIn: step, resolution: resolution)
        #expect(chips.map(\.name) == ["Kartoffel"])
        #expect(chips.first?.quantity.map { formatter.string(for: $0) } == "700 g")
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

        // "Die restliche Butter" is the pot's other half — one chip for
        // the pot, not one per line.
        let step1Chips = recipe.ingredients(mentionedIn: steps[1], resolution: resolution, scaledToServings: 8)
        #expect(step1Chips.map(\.name) == ["Butter"])
        #expect(step1Chips.first?.quantity == Quantity(300, .gram))

        // Binding the pot binds both lines — no chip repeats the butter
        // beneath the first step. The egg, named with no amount anywhere
        // in the step, is the chip left there.
        let butterLines = recipe.ingredients.filter { $0.name == "Butter" }
        #expect(butterLines.count == 2)
        for butter in butterLines {
            #expect(resolution.mentionsAmount(of: butter, in: steps[0]))
        }
        #expect(recipe.ingredients(mentionedIn: steps[0], resolution: resolution, scaledToServings: 8).map(\.name) == ["Ei"])
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
        let chips = recipe.ingredients(mentionedIn: steps[1], resolution: resolution)
        #expect(chips.map(\.name) == ["Butter"])
        #expect(chips.first?.quantity == Quantity(50, .gram))
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
        let chips = recipe.ingredients(mentionedIn: recipe.steps[0], resolution: resolution)
        #expect(chips.map(\.name) == ["Knoblauch"])
        #expect(chips.first?.quantity?.amount == 2)
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
        // silently dropped — "Rindfleisch" is still the chip beneath.
        #expect(recipe.ingredients(mentionedIn: recipe.steps[0], resolution: resolution).map(\.name) == ["Rindfleisch"])
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

@Suite("Chips for bare mentions")
struct BareMentionChipTests {
    private let formatter = QuantityFormatter(locale: Locale(identifier: "de_DE"))

    private func chips(_ ingredients: String, _ instructions: String, servings: Int = 2) -> [[String]] {
        let recipe = Recipe(title: "t", servings: 2, ingredientsText: ingredients, instructionsText: instructions)
        let resolution = StepAmountResolver.resolve(recipe, toServings: servings, formatter: formatter)
        return recipe.steps.map { step in
            recipe.ingredients(mentionedIn: step, resolution: resolution).map { chip in
                chip.quantity.map { "\(formatter.string(for: $0)) \(chip.name)" } ?? chip.name
            }
        }
    }

    @Test("A name anywhere in the step earns its chip — start, middle or end")
    func namesAnywhere() {
        #expect(chips("200 g Butter\n2 Zwiebeln\n1 kg Kartoffel", "Butter schmelzen, die Zwiebeln darin dünsten und die Kartoffeln zugeben.")
            == [["200 g Butter", "2 Zwiebeln", "1 kg Kartoffel"]])
    }

    @Test("A unit word never claims an ingredient as its compound head")
    func unitWordIsNoCompoundHead() {
        #expect(chips("2 Zwiebeln\n300 g Mehl", "Mehl mit 2 EL Wasser anrühren.") == [["300 g Mehl"]])
    }

    @Test("An ingredient never named in the step gets no chip")
    func unnamedGetsNoChip() {
        #expect(chips("200 g Butter\n2 Zwiebeln", "Butter schmelzen.") == [["200 g Butter"]])
    }

    @Test("A name mentioned twice in one step is one chip")
    func twiceInOneStepIsOneChip() {
        #expect(chips("2 Zwiebeln", "Zwiebeln schälen, Zwiebeln würfeln.") == [["2 Zwiebeln"]])
    }

    @Test("An amount written in the sentence leaves no chip for the same pot")
    func writtenAmountLeavesNoChip() {
        #expect(chips("200 g Butter", "100 g Butter schmelzen und die Butter bräunen.") == [[]])
    }

    @Test("Inflected forms are found via the catalog, same as a written amount would be")
    func inflectedForms() {
        #expect(chips("2 Zwiebeln", "Die Zwiebel würfeln.") == [["2 Zwiebeln"]])
        #expect(chips("1 Zwiebel", "Die Zwiebeln würfeln.") == [["1 Zwiebel"]])
    }

    @Test("A name only mentioned inside an exclusion clause gets no chip")
    func negatedOnly() {
        #expect(chips("1 EL Fett\n2 EL Pinienkerne", "In einer Pfanne ohne Fett die Pinienkerne anrösten.") == [["2 EL Pinienkerne"]])
    }

    @Test("A name mentioned both inside and outside an exclusion clause still gets its chip")
    func negatedAndNot() {
        #expect(chips("1 EL Fett", "Ohne Fett anrösten, dann das Fett zugeben.") == [["1 EL Fett"]])
    }

    @Test("A line without a quantity is a plain chip wherever it is named")
    func unquantifiedLine() {
        #expect(chips("Salz\n200 g Butter", "Butter schmelzen und mit Salz würzen.\nMit Salz abschmecken.") == [["200 g Butter", "Salz"], ["Salz"]])
    }

    @Test("The remainder chip follows the serving count of the resolution")
    func chipScales() {
        #expect(chips("200 g Butter", "50 g Butter schmelzen.\nDie Butter unterheben.", servings: 4).last == ["300 g Butter"])
    }
}

@Suite("Back-references to what earlier steps took out")
struct StepBackReferenceTests {
    private let formatter = QuantityFormatter(locale: Locale(identifier: "de_DE"))

    private func markedText(_ marks: [StepTextMark], in step: RecipeStep) -> [String] {
        marks.map { "\($0.kind)(\(step.text[$0.range]))" }
    }

    private func amounts(_ segments: [StepAmountSegment]) -> [String] {
        segments.compactMap { if case .amount(let s) = $0 { s } else { nil } }
    }

    @Test("One step per ingredient, then everything together — nothing is taken out twice")
    func pestoPreparesEachIngredientThenCombines() throws {
        let recipe = Recipe(
            title: "Basilikum-Pesto",
            servings: 4,
            ingredientsText: """
            3 Bund Basilikum
            100 g Parmesan
            100 g Pinienkerne
            125 ml Olivenöl
            2 Zehen Knoblauch
            Salz
            """,
            instructionsText: """
            Pinienkerne (100 g) in einer Pfanne ohne Fett goldbraun anrösten und abkühlen lassen.
            Basilikum (3 Bund) waschen, trocken schütteln und die Blätter abzupfen.
            Parmesan (100 g) fein reiben.
            Knoblauchzehen (2 Zehe) schälen und grob hacken.
            Basilikum, natives Olivenöl (125 ml) extra, Knoblauch und die Hälfte der Pinienkerne mit einem Stabmixer zerkleinern.
            Fein geriebenen Parmesan hinzugeben und untermischen.
            Restliche gekühlte Pinienkerne grob hacken und unterrühren.
            Mit Salz abschmecken.
            """
        )
        let steps = recipe.steps
        let resolution = StepAmountResolver.resolve(recipe, toServings: 4, formatter: formatter)

        // The roasting step keeps its amount: the later mentions no longer
        // overbook the pot it binds to.
        #expect(markedText(resolution.marks(for: steps[0]), in: steps[0]) == ["bound(100 g)"])

        // Basil and garlic were taken out whole by their own steps; "die
        // Hälfte der Pinienkerne" draws on what the roasting step holds —
        // as a chip, the sentence keeps its words.
        #expect(markedText(resolution.marks(for: steps[4]), in: steps[4]) == [
            "backReference(Basilikum)", "bound(125 ml)", "backReference(Knoblauch)", "bound(Hälfte der)",
        ])
        #expect(amounts(resolution.segments(for: steps[4])) == ["125 ml"])
        let blenderChips = recipe.ingredients(mentionedIn: steps[4], resolution: resolution)
        #expect(blenderChips.map(\.name) == ["Pinienkerne"])
        #expect(blenderChips.first?.quantity == Quantity(50, .gram))
        #expect(markedText(resolution.marks(for: steps[5]), in: steps[5]) == ["backReference(Parmesan)"])
        // "Restliche gekühlte Pinienkerne": the other half of what the
        // roasting step holds — read past the qualifier, drawn from the
        // earlier step, not from the pot.
        #expect(markedText(resolution.marks(for: steps[6]), in: steps[6]) == ["bound(Restliche)"])
        #expect(recipe.ingredients(mentionedIn: steps[6], resolution: resolution).first?.quantity == Quantity(50, .gram))
        let restIntake = try #require(resolution.intakes(for: steps[6]).first)
        #expect(restIntake.source == .steps([steps[0].id]))
        #expect(restIntake.share == 0.5)

        let pinienkerne = try #require(recipe.ingredients.first { $0.name == "Pinienkerne" })
        let halfIntake = try #require(resolution.intakes(for: steps[4]).first { $0.share != nil && $0.ingredientLineIDs == [pinienkerne.id] })
        #expect(halfIntake.source == .steps([steps[0].id]))
        #expect(halfIntake.share == 0.5)

        // Nothing left to ask, every pot accounted for, and the fallback
        // list under the blending step does not offer the basil again.
        #expect(resolution.isFullyClaimed)
        let fallback = recipe.ingredients(mentionedIn: steps[4], resolution: resolution)
        #expect(!fallback.contains { $0.name == "Basilikum" })
    }

    @Test("A pot only partly taken out gives its next mention what is left, not the whole of it")
    func partlyTakenOutGivesTheRest() throws {
        let recipe = Recipe(
            title: "Butterkuchen",
            servings: 2,
            ingredientsText: "300 g Butter",
            instructionsText: """
            200 g Butter schmelzen.
            Die Butter unterrühren.
            """
        )
        let steps = recipe.steps
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)

        #expect(markedText(resolution.marks(for: steps[1]), in: steps[1]) == ["bound(Butter)"])
        let chips = recipe.ingredients(mentionedIn: steps[1], resolution: resolution)
        #expect(chips.first?.quantity == Quantity(100, .gram))
        #expect(resolution.isFullyClaimed)
    }
    @Test("A fraction the list cannot cover any more draws on what the earlier step holds")
    func fractionAfterPartialWithdrawalDrawsOnTheEarlierStep() throws {
        // 200 g of 300 g are gone; half the pot is more than the list has
        // left, so "die Hälfte der Butter" is half of what was melted.
        // In 163 real recipes the case never came up — the rule is what
        // the register does everywhere else, not a reading of the sentence.
        let recipe = Recipe(
            title: "Butterkuchen",
            servings: 2,
            ingredientsText: "300 g Butter",
            instructionsText: """
            200 g Butter schmelzen.
            Die Hälfte der Butter unterrühren.
            """
        )
        let steps = recipe.steps
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        #expect(markedText(resolution.marks(for: steps[0]), in: steps[0]) == ["bound(200 g)"])
        #expect(markedText(resolution.marks(for: steps[1]), in: steps[1]) == ["bound(Hälfte der)"])
        let half = try #require(resolution.intakes(for: steps[1]).first)
        #expect(half.source == .steps([steps[0].id]))
        #expect(half.quantity == Quantity(100, .gram))
    }
    @Test("A chain: the first mention takes the whole line, every later one is a back-reference")
    func chainTakesOnceAndRefersBack() {
        let recipe = Recipe(
            title: "Carbonara",
            servings: 4,
            ingredientsText: "200 g Räuchertofu",
            instructionsText: """
            Räuchertofu würfeln.
            Räuchertofu knusprig anbraten.
            Räuchertofu unter die Nudeln heben.
            """
        )
        let steps = recipe.steps
        let resolution = StepAmountResolver.resolve(recipe, toServings: 4, formatter: formatter)

        #expect(markedText(resolution.marks(for: steps[0]), in: steps[0]) == ["bound(Räuchertofu)"])
        #expect(recipe.ingredients(mentionedIn: steps[0], resolution: resolution).first?.quantity == Quantity(200, .gram))
        #expect(markedText(resolution.marks(for: steps[1]), in: steps[1]) == ["backReference(Räuchertofu)"])
        #expect(markedText(resolution.marks(for: steps[2]), in: steps[2]) == ["backReference(Räuchertofu)"])
        #expect(recipe.ingredients(mentionedIn: steps[1], resolution: resolution).isEmpty)
        #expect(recipe.ingredients(mentionedIn: steps[2], resolution: resolution).isEmpty)
        #expect(resolution.isFullyClaimed)
    }
    @Test("A written number in a later step is reserved first — an earlier bare mention gets nothing")
    func writtenNumberLaterIsReservedFirst() {
        let recipe = Recipe(
            title: "Salat",
            servings: 2,
            ingredientsText: "100 g Pinienkerne",
            instructionsText: """
            Pinienkerne rösten.
            100 g Pinienkerne über den Salat streuen.
            """
        )
        let steps = recipe.steps
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        // Not a back-reference either: nothing was taken out before it.
        #expect(resolution.marks(for: steps[0]).isEmpty)
        #expect(recipe.ingredients(mentionedIn: steps[0], resolution: resolution).isEmpty)
        #expect(amounts(resolution.segments(for: steps[1])) == ["100 g"])
    }
    @Test("A written number is a withdrawal wherever it stands — even after the pot was emptied")
    func writtenNumberNeverBecomesABackReference() {
        let recipe = Recipe(
            title: "Bruschetta",
            servings: 2,
            ingredientsText: "2 EL Olivenöl",
            instructionsText: """
            2 EL Olivenöl erhitzen.
            2 EL Olivenöl darüberträufeln.
            """
        )
        let steps = recipe.steps
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        // Both overbook the pot, so neither binds — and the name beside a
        // number is never read as a bare mention on top of it.
        #expect(markedText(resolution.marks(for: steps[0]), in: steps[0]) == ["loose(2 EL)"])
        #expect(markedText(resolution.marks(for: steps[1]), in: steps[1]) == ["loose(2 EL)"])
        #expect(recipe.ingredients(mentionedIn: steps[0], resolution: resolution).isEmpty)
    }

    @Test("\"Restliche\" after the pot was emptied is what earlier steps still hold")
    func remainingDrawsOnEarlierSteps() throws {
        let recipe = Recipe(
            title: "Pesto",
            servings: 2,
            ingredientsText: "100 g Pinienkerne",
            instructionsText: """
            Pinienkerne (100 g) rösten.
            Die Hälfte der Pinienkerne mixen.
            Die restlichen Pinienkerne unterrühren.
            """
        )
        let steps = recipe.steps
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)

        #expect(recipe.ingredients(mentionedIn: steps[1], resolution: resolution).first?.quantity == Quantity(50, .gram))
        #expect(recipe.ingredients(mentionedIn: steps[2], resolution: resolution).first?.quantity == Quantity(50, .gram))
        let rest = try #require(resolution.intakes(for: steps[2]).first)
        #expect(rest.source == .steps([steps[0].id]))
        #expect(rest.share == 0.5)
        #expect(resolution.intakes(for: steps[0]).first?.source == .list)
    }
}

@Suite("Fraction and remainder words the scanner reads on its own")
struct ClosedGrammarScannerTests {
    private let formatter = QuantityFormatter(locale: Locale(identifier: "de_DE"))

    /// Per step: the sentence with its inline amounts in «», then the chips.
    private func rendered(_ ingredients: String, _ instructions: String, servings: Int = 2) -> [String] {
        let recipe = Recipe(title: "t", servings: servings, ingredientsText: ingredients, instructionsText: instructions)
        let resolution = StepAmountResolver.resolve(recipe, toServings: servings, formatter: formatter)
        return recipe.steps.map { step in
            let sentence = resolution.segments(for: step).map { segment in
                switch segment {
                case .text(let s): s
                case .amount(let s): "«\(s)»"
                }
            }.joined()
            let chips = recipe.ingredients(mentionedIn: step, resolution: resolution)
                .map { chip in chip.quantity.map { "\(formatter.string(for: $0)) \(chip.name)" } ?? chip.name }
            return ([sentence] + chips).joined(separator: " | ")
        }
    }

    @Test("Drittel and Viertel, spelled out or in digits, resolve like Hälfte")
    func fractionWords() {
        #expect(rendered("300 g Paprika", "Ein Drittel der Paprika in Scheiben schneiden.") == ["Ein Drittel der Paprika in Scheiben schneiden. | 100 g Paprika"])
        #expect(rendered("300 ml Milch", "Zwei Drittel der Milch aufkochen.") == ["Zwei Drittel der Milch aufkochen. | 200 ml Milch"])
        #expect(rendered("200 g Butter", "Ein Viertel der Butter schmelzen.") == ["Ein Viertel der Butter schmelzen. | 50 g Butter"])
        #expect(rendered("200 g Butter", "Drei Viertel der Butter schmelzen.") == ["Drei Viertel der Butter schmelzen. | 150 g Butter"])
        #expect(rendered("300 g Heidelbeeren", "2/3 der Heidelbeeren unterheben.") == ["2/3 der Heidelbeeren unterheben. | 200 g Heidelbeeren"])
        #expect(rendered("10 ml Sesamöl", "Die Hälfte vom Sesamöl zum Reis geben.") == ["Die Hälfte vom Sesamöl zum Reis geben. | 5 ml Sesamöl"])
    }

    @Test("'übrig' and 'der Rest' mean what 'restlich' means")
    func remainderWords() {
        #expect(rendered("200 g Butter", "50 g Butter schmelzen.\nDie übrige Butter einrühren.") == ["«50 g» Butter schmelzen.", "Die übrige Butter einrühren. | 150 g Butter"])
        #expect(rendered("200 g Butter", "50 g Butter schmelzen.\nDen Rest der Butter einrühren.") == ["«50 g» Butter schmelzen.", "Den Rest der Butter einrühren. | 150 g Butter"])
    }

    @Test("A qualifier between the share word and the name is stepped over")
    func qualifiersBetweenShareWordAndName() {
        #expect(rendered("100 g Pinienkerne", "Die Hälfte der Pinienkerne pürieren.\nRestliche gekühlte Pinienkerne grob hacken.")
            == ["Die Hälfte der Pinienkerne pürieren. | 50 g Pinienkerne", "Restliche gekühlte Pinienkerne grob hacken. | 50 g Pinienkerne"])
        #expect(rendered("4 EL Olivenöl", "1 EL Olivenöl erhitzen.\nMit dem restlichem Olivenöl beträufeln.")
            == ["«1 EL» Olivenöl erhitzen.", "Mit dem restlichem Olivenöl beträufeln. | 3 EL Olivenöl"])
        #expect(rendered("4 Zwiebeln", "Die Hälfte der fein gehackten Zwiebeln anbraten.")
            == ["Die Hälfte der fein gehackten Zwiebeln anbraten. | 2 Zwiebeln"])
    }
}

@Suite("Loose numbers that never scale")
struct LooseNumberScalingTests {
    private func scaled(_ instructions: String) -> [String] {
        let recipe = Recipe(title: "t", servings: 2, ingredientsText: "1 Kürbis\n300 g Mehl", instructionsText: instructions)
        return recipe.steps.map { recipe.scaledStepText($0, toServings: 4) }
    }

    @Test("A size in centimetres stays a size at every serving count")
    func sizesDoNotScale() {
        #expect(scaled("Kürbis in ca. 3 cm große Würfel schneiden.") == ["Kürbis in ca. 3 cm große Würfel schneiden."])
        #expect(scaled("Eine Springform (Ø 26 cm) fetten.") == ["Eine Springform (Ø 26 cm) fetten."])
    }

    @Test("An amount given per piece is a property of the piece, not of the batch")
    func perPieceAmountsDoNotScale() {
        #expect(scaled("Aus der Masse Bällchen von je ca. 40 g formen.") == ["Aus der Masse Bällchen von je ca. 40 g formen."])
        #expect(scaled("Bällchen formen, etwa 40 g schwer.") == ["Bällchen formen, etwa 40 g schwer."])
        #expect(scaled("Patties à 90 g formen.") == ["Patties à 90 g formen."])
    }

    @Test("Everything else loose still moves with the serving count")
    func otherLooseNumbersStillScale() {
        #expect(scaled("300 ml Wasser aufkochen.") == ["600 ml Wasser aufkochen."])
        #expect(scaled("1 Dose Kokosmilch zugeben.").first?.hasPrefix("2 ") == true)
    }

    @Test("A size gets no loose mark either — nothing about it was understood as an amount")
    func sizesAreNotMarkedLoose() {
        let recipe = Recipe(title: "t", servings: 2, ingredientsText: "1 Kürbis", instructionsText: "Kürbis in 3 cm große Würfel schneiden.")
        let marks = StepAmountResolver.resolve(recipe, toServings: 2).marks(for: recipe.steps[0])
        #expect(!marks.contains { $0.kind == .loose })
    }
}

@Suite("Chips stop at word boundaries")
struct ChipWordBoundaryTests {
    private func chips(_ ingredients: String, _ step: String) -> [String] {
        let recipe = Recipe(title: "t", servings: 2, ingredientsText: ingredients, instructionsText: step)
        return recipe.ingredients(mentionedIn: recipe.steps[0]).map(\.name)
    }

    @Test("A name at the start of an unrelated compound is not a mention")
    func unrelatedCompounds() {
        #expect(chips("1 TL Salz\n500 g Nudeln", "Nudeln in Salzwasser kochen.") == ["Nudeln"])
        #expect(chips("400 g Tomaten", "Tomatenmark einrühren.") == [])
        #expect(chips("1 TL Chilipulver", "Chili entkernen und hacken.") == [])
    }

    @Test("A name inside another word is not a mention")
    func insideAnotherWord() {
        #expect(chips("1 Stange Lauch", "Knoblauch pressen.") == [])
        #expect(chips("100 g Zucker", "Mit Puderzucker bestäuben.") == [])
    }

    @Test("A prepared form or an inflection still names the ingredient")
    func preparedFormsAndInflections() {
        #expect(chips("2 Zwiebeln", "Zwiebelwürfel glasig dünsten.") == ["Zwiebeln"])
        #expect(chips("1 Blumenkohl", "Blumenkohlröschen dämpfen.") == ["Blumenkohl"])
        #expect(chips("1 Zitrone", "Mit Zitronenzesten bestreuen.") == ["Zitrone"])
        #expect(chips("2 Karotten", "Karotten schälen.") == ["Karotten"])
        #expect(chips("1 Wirsing", "Blätter des Wirsings ablösen.") == ["Wirsing"])
    }

    @Test("A name of two or three letters must stand alone as a word")
    func shortNamesStandAlone() {
        #expect(chips("2 Eier", "In einen Topf geben und ein wenig rühren.") == [])
        #expect(chips("2 Eier", "Ein Ei verquirlen.") == ["Eier"])
        #expect(chips("2 EL Öl", "Kokosöl erhitzen.") == [])
    }

    @Test("The compound stem still reaches a real compound, never a derivative")
    func stemTierRefusesDerivatives() {
        #expect(chips("1 TL Bockshornkleesamen", "Bockshornklee anrösten.") == ["Bockshornkleesamen"])
        #expect(chips("500 ml Gemüsebrühe", "Das Gemüse anbraten.") == [])
    }
}

@Suite("Which pot a name means, without a step heading")
struct GroupCueTests {
    private let formatter = QuantityFormatter(locale: Locale(identifier: "de_DE"))

    private func chips(_ ingredients: String, _ instructions: String) -> [[String]] {
        let recipe = Recipe(title: "t", servings: 2, ingredientsText: ingredients, instructionsText: instructions)
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        return recipe.steps.map { step in
            recipe.ingredients(mentionedIn: step, resolution: resolution).map { chip in
                chip.quantity.map { "\(formatter.string(for: $0)) \(chip.name)" } ?? chip.name
            }
        }
    }

    @Test("The line's own qualifier in the sentence picks the line — each one named gets its chip")
    func qualifierInTheSentence() {
        #expect(chips("500 g weißer Spargel\n500 g grüner Spargel", "Weißen Spargel komplett, grünen Spargel im unteren Drittel schälen.")
            == [["500 g weißer Spargel", "500 g grüner Spargel"]])
        #expect(chips("400 g stückige Tomaten\n400 g passierte Tomaten", "Die passierten Tomaten zugeben.")
            == [["400 g passierte Tomaten"]])
    }

    @Test("A qualifier every candidate carries tells nothing apart — the next cue decides")
    func sharedQualifierFallsThrough() {
        #expect(chips("# Teig\n150 g Weizenmehl\n300 ml fettarme Kokosmilch\n# Füllung\n80 g Kokosraspeln\n100 ml fettarme Kokosmilch",
                      "Weizenmehl vermengen. Fettarme Kokosmilch einarbeiten.\nFettarme Kokosmilch erhitzen und über die Kokosraspeln gießen.")
            == [["150 g Weizenmehl", "300 ml fettarme Kokosmilch"], ["100 ml fettarme Kokosmilch", "80 g Kokosraspeln"]])
    }

    @Test("The group's name in the sentence picks the group")
    func groupNameInTheSentence() {
        #expect(chips("# Für den Teig\n200 g Butter\n# Für die Streusel\n100 g Butter",
                      "Für den Teig Mehl mit Butter verkneten.\nFür die Streusel Butter in Stücken hinzugeben.")
            == [["200 g Butter"], ["100 g Butter"]])
        #expect(chips("# Teig\n200 g Butter\n# Füllung\n50 g Butter", "Für den Mürbteig kalte Butter in Stücken zugeben.")
            == [["200 g Butter"]])
    }

    @Test("Company picks the group: an ingredient only one group lists, named alongside")
    func companyInTheSentence() {
        #expect(chips("# Teig\n300 g Mehl\n100 g Butter\n# Füllung\n500 g Milchreis\n50 g Butter", "Mehl, Puderzucker und Butter verkneten.")
            == [["300 g Mehl", "100 g Butter"]])
    }

    @Test("Company counts an ingredient named the way a step names it, by its head noun")
    func companyByHeadNoun() {
        #expect(chips("# Teig\n300 ml fettarme Kokosmilch\n# Füllung\n80 g getrocknete Kokosraspeln\n100 ml fettarme Kokosmilch",
                      "Getrocknete Kokosraspeln anrösten.\nFettarme Kokosmilch erhitzen und über die Kokosraspeln gießen.")
            == [["80 g getrocknete Kokosraspeln"], ["100 ml fettarme Kokosmilch"]])
    }

    @Test("A later mention in the same step reaches the pot the first one was not given to")
    func laterMentionReachesTheOtherPot() {
        #expect(Set(chips("# Teig\n230 g Mehl\n120 g kalte Butter\n# Füllung\n170 g Milchreis\n80 g kalte Butter",
                          "Mehl vermischen. Kalte Butter zugeben und den Teig verkneten. Butter in den warmen Milchreis rühren.")[0])
            == ["230 g Mehl", "120 g kalte Butter", "80 g kalte Butter", "170 g Milchreis"])
    }

    @Test("The same pot named twice stays one pot — a repeat claims nothing the sentence does not point to")
    func repeatedMentionStaysOnePot() {
        #expect(chips("# Teig\n200 g Butter\n# Streusel\n100 g Butter", "Für den Teig Butter schmelzen und die Butter unterrühren.")
            == [["200 g Butter"]])
    }

    @Test("Each mention is read in its own sentence before the whole step")
    func sentenceBeforeStep() {
        #expect(Set(chips("# Teig\n200 g Mehl\n100 g Butter\n# Füllung\n500 g Milchreis\n50 g Butter",
                          "Butter in den Milchreis rühren. Mehl und Butter verkneten.")[0])
            == ["200 g Mehl", "100 g Butter", "500 g Milchreis", "50 g Butter"])
    }

    @Test("A name a written amount already took is not a bare mention for another pot of that name")
    func writtenNameIsSpokenFor() {
        #expect(Set(chips("# Kartoffeln\n600 g Kartoffeln\n1 EL Olivenöl\n# Hack\n1 Zwiebel\n1 TL Olivenöl\n# Sauce\n400 g Seidentofu\n1 EL Olivenöl",
                          "Kartoffeln mit 1 EL Olivenöl vermengen. Zwiebel mit dem Olivenöl anbraten.")[0])
            == ["600 g Kartoffeln", "1 Zwiebel", "1 TL Olivenöl"])
    }

    @Test("One name over every variant in one group adds them up, under the name as written")
    func variantsAddUp() {
        #expect(chips("1 Paprika rot\n1 Paprika gelb\n1 Paprika grün", "Paprika in Streifen schneiden.") == [["3 Paprika"]])
    }

    @Test("What nothing tells apart shows its name and no amount, and charges no pot")
    func ambiguousShowsNoAmount() {
        let recipe = Recipe(title: "t", servings: 2, ingredientsText: "# Teig\n100 g Zucker\n# Belag\n50 g Zucker", instructionsText: "Zucker darüberstreuen.")
        let resolution = StepAmountResolver.resolve(recipe, toServings: 2, formatter: formatter)
        let chips = recipe.ingredients(mentionedIn: recipe.steps[0], resolution: resolution)
        #expect(chips.map(\.name) == ["Zucker"])
        #expect(chips.first?.quantity == nil)
        #expect(!resolution.isFullyClaimed)
        #expect(resolution.marks(for: recipe.steps[0]).isEmpty)
    }

    @Test("A step heading still settles it before any sentence cue")
    func headingWins() {
        #expect(chips("# Teig\n200 g Butter\n# Füllung\n50 g Butter", "# Füllung\nButter schmelzen.") == [["50 g Butter"]])
    }
}
