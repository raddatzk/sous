import Foundation
import Testing
@testable import SousKit

@Suite("Turning the model's claims into mentions")
struct AmountAIExtractorTests {
    @Test("A quantity that occurs nowhere in the recipe is discarded, not trusted")
    func hallucinationIsDiscarded() {
        let steps = [RecipeStep(text: "Den Knoblauch dazugeben und kurz mitbraten.")]
        let claimed = ExtractedQuantity(
            quantityText: "die Hälfte", modifiedNoun: "Sellerie", kind: .fraction, fractionValue: 0.5, stepNumber: 1
        )

        let mentions = AmountAIExtractor.mentions(from: [claimed], steps: steps)
        #expect(mentions.isEmpty)
    }

    @Test("A mention is relocated to the step where its text actually occurs, not the model's claimed step")
    func wrongStepNumberIsCorrected() throws {
        let steps = [
            RecipeStep(text: "Die Zwiebeln fein würfeln."),
            RecipeStep(text: "400 g Kartoffeln würfeln und die Kokosmilch dazugeben."),
        ]
        // The model claims step 1, but "400 g" only occurs in step 2.
        let claimed = ExtractedQuantity(
            quantityText: "400 g", modifiedNoun: "Kartoffeln", kind: .absolute, fractionValue: nil, stepNumber: 1
        )

        let mentions = AmountAIExtractor.mentions(from: [claimed], steps: steps)
        #expect(mentions[steps[0].id] == nil)
        let resolved = try #require(mentions[steps[1].id]?.first)
        #expect(String(resolved.namePhrase) == "Kartoffeln")
        guard case .absolute(let quantity) = resolved.kind else {
            Issue.record("Expected an absolute amount, got \(resolved.kind)")
            return
        }
        #expect(quantity == Quantity(400, .gram))
    }

    @Test("One relative phrase naming two ingredients becomes two mentions")
    func compoundNounSplitsIntoTwoMentions() throws {
        let steps = [RecipeStep(text: "Die restlichen Zwiebeln und Karotten zur Füllung geben.")]
        let claimed = [
            ExtractedQuantity(quantityText: "restlichen", modifiedNoun: "Zwiebeln", kind: .remaining, fractionValue: nil, stepNumber: 1),
            ExtractedQuantity(quantityText: "restlichen", modifiedNoun: "Karotten", kind: .remaining, fractionValue: nil, stepNumber: 1),
        ]

        let mentions = AmountAIExtractor.mentions(from: claimed, steps: steps)
        let found = try #require(mentions[steps[0].id])
        #expect(found.count == 2)
        #expect(found.map { String($0.namePhrase) }.sorted() == ["Karotten", "Zwiebeln"])
        #expect(found.allSatisfy { if case .remaining = $0.kind { true } else { false } })
    }

    @Test("A fraction word regex was never taught resolves through its decimal value, not a hand-written list")
    func openEndedFractionWordsWork() throws {
        let steps = [RecipeStep(text: "Ein Drittel des Teigs beiseitestellen.")]
        let claimed = ExtractedQuantity(
            quantityText: "Ein Drittel", modifiedNoun: "Teig", kind: .fraction, fractionValue: 1.0 / 3.0, stepNumber: 1
        )

        let mentions = AmountAIExtractor.mentions(from: [claimed], steps: steps)
        let resolved = try #require(mentions[steps[0].id]?.first)
        guard case .fraction(let value) = resolved.kind else {
            Issue.record("Expected a fraction, got \(resolved.kind)")
            return
        }
        #expect(abs(value - 1.0 / 3.0) < 0.0001)
    }

    @Test("Durations are never turned into mentions, even if the model calls them one")
    func notAQuantityIsDropped() {
        let steps = [RecipeStep(text: "20 Minuten köcheln lassen.")]
        let claimed = ExtractedQuantity(
            quantityText: "20 Minuten", modifiedNoun: "", kind: .notAQuantity, fractionValue: nil, stepNumber: 1
        )

        let mentions = AmountAIExtractor.mentions(from: [claimed], steps: steps)
        #expect(mentions.isEmpty)
    }

    @Test("A fraction with no value, or one that isn't positive, does not resolve")
    func malformedFractionIsDiscarded() {
        let steps = [RecipeStep(text: "Die Hälfte der Butter schmelzen.")]
        let missingValue = ExtractedQuantity(
            quantityText: "Die Hälfte", modifiedNoun: "Butter", kind: .fraction, fractionValue: nil, stepNumber: 1
        )
        let zeroValue = ExtractedQuantity(
            quantityText: "Die Hälfte", modifiedNoun: "Butter", kind: .fraction, fractionValue: 0, stepNumber: 1
        )

        #expect(AmountAIExtractor.mentions(from: [missingValue], steps: steps).isEmpty)
        #expect(AmountAIExtractor.mentions(from: [zeroValue], steps: steps).isEmpty)
    }
}
