import Foundation
import Testing
@testable import SousKit

@Suite("NutritionTag")
struct NutritionTagTests {
    /// Builds a nutrition figure with the given macros and a coverage of
    /// `included` counted lines against `missing` unresolved ones.
    private func nutrition(
        kcal: Double, proteinG: Double = 0, fiberG: Double = 0,
        servings: Int = 4, included: Int = 10, missing: Int = 0
    ) -> RecipeNutrition {
        var values = NutritionInfo.zero
        values.kcal = kcal
        values.proteinG = proteinG
        values.fiberG = fiberG
        let gaps = (0..<missing).map {
            NutritionCoverage.Gap(ingredientName: "Zutat \($0)", reason: .noCatalogMatch)
        }
        let contributions = (0..<included).map {
            NutritionCoverage.Contribution(ingredientName: "Bekannt \($0)")
        }
        return RecipeNutrition(
            perPortion: values, servings: servings, nrf93Score: 0,
            coverage: NutritionCoverage(
                includedCount: included, gaps: gaps, contributions: contributions
            )
        )
    }

    @Test("A dish drawing a fifth of its energy from protein is protein-rich")
    func proteinAboveThreshold() {
        // 30 g protein = 120 kcal of a 500 kcal portion: 24 %.
        let tags = NutritionTagging.tags(for: nutrition(kcal: 500, proteinG: 30))
        #expect(tags.map(\.kind) == [.proteinRich])
        #expect(tags.first?.reason == "24 % der Energie aus Eiweiß")
    }

    @Test("Just under the share is not a claim")
    func proteinBelowThreshold() {
        // 24 g protein = 96 kcal of 500: 19.2 %.
        #expect(NutritionTagging.tags(for: nutrition(kcal: 500, proteinG: 24)).isEmpty)
    }

    @Test("Fibre is measured against the dish's energy, not its portion")
    func fibreDensity() {
        // 18 g fibre in 600 kcal = 3 g per 100 kcal, exactly the claim.
        let tags = NutritionTagging.tags(for: nutrition(kcal: 600, fiberG: 18))
        #expect(tags.map(\.kind) == [.fiberRich])
    }

    /// The case the calibration bench turned up: a whole cake filed as one
    /// serving carries more fibre per "portion" than a day's reference, and
    /// an absolute threshold would call it fibre-rich. An energy-relative one
    /// sees a cake.
    @Test("A whole cake filed as one serving is not fibre-rich")
    func wholeCakeIsNotFibreRich() {
        let cake = nutrition(kcal: 6984, fiberG: 55.9, servings: 1)
        #expect(NutritionTagging.tags(for: cake).isEmpty)
    }

    @Test("Both claims can hold at once")
    func bothTags() {
        let tags = NutritionTagging.tags(for: nutrition(kcal: 500, proteinG: 30, fiberG: 20))
        #expect(Set(tags.map(\.kind)) == [.proteinRich, .fiberRich])
    }

    /// Thin coverage means silence, not "no" — the dish whose protein sits in
    /// the ingredient the catalog could not resolve must not be judged by
    /// what is left.
    @Test("Below the coverage floor nothing is claimed")
    func thinCoverageStaysSilent() {
        let thin = nutrition(kcal: 500, proteinG: 30, included: 6, missing: 4)
        #expect(NutritionTagging.tags(for: thin).isEmpty)

        let enough = nutrition(kcal: 500, proteinG: 30, included: 7, missing: 3)
        #expect(NutritionTagging.tags(for: enough).map(\.kind) == [.proteinRich])
    }

    @Test("A recipe with no numbers at all claims nothing")
    func noNumbers() {
        #expect(NutritionTagging.tags(for: nutrition(kcal: 0, proteinG: 30)).isEmpty)
    }

    @Test("A category the recipe already carries is not suggested again")
    func existingCategoryIsNotSuggested() {
        let figure = nutrition(kcal: 500, proteinG: 30)
        #expect(NutritionTagging.suggestions(for: figure, existing: ["Proteinreich"]).isEmpty)
        #expect(NutritionTagging.suggestions(for: figure, existing: ["Hauptgerichte"]).count == 1)
    }

    @Test("A declined tag is not offered again")
    func declinedIsNotSuggested() {
        let figure = nutrition(kcal: 500, proteinG: 30, fiberG: 20)
        let remaining = NutritionTagging.suggestions(
            for: figure, existing: [], declined: [.proteinRich]
        )
        #expect(remaining.map(\.kind) == [.fiberRich])
    }
}
