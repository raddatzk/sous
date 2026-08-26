import Foundation
import Testing
@testable import SousKit

/// The status model at the point where it decides something: whether a line
/// counts, whether it counts *provisionally*, and what that does to the
/// coverage a badge is gated on.
@Suite("The basis status model")
struct BasisStatusTests {
    private func info(kcal: Double) -> NutritionInfo {
        NutritionInfo(
            kcal: kcal, proteinG: 0, fatG: 0, saturatedFatG: 0, carbsG: 0, sugarG: 0,
            fiberG: 0, sodiumMg: 0, vitaminAMcg: 0, vitaminCMg: 0, vitaminDMcg: 0,
            vitaminEMg: 0, calciumMg: 0, ironMg: 0, magnesiumMg: 0, potassiumMg: 0
        )
    }

    private func catalog() -> IngredientCatalog {
        IngredientCatalog(ingredients: [
            CatalogIngredient(name: "Zucchini", category: .vegetables),
            CatalogIngredient(name: "Schmelzkäse", category: .dairy),
            CatalogIngredient(name: "Hackfleisch", category: .meat),
        ])
    }

    /// Zucchini is settled, Schmelzkäse is the synonym table's guess, and
    /// Hackfleisch is a known word with no basis at all.
    private func nutritionCatalog(
        cheese: NutritionBasis.Status = .proposed,
        cheeseCandidates: [String] = ["M771600", "M771400"]
    ) -> NutritionCatalog {
        NutritionCatalog(entries: [
            CatalogNutrition(name: "Zucchini", bases: ["raw": NutritionBasis(
                values: info(kcal: 20), code: "G100", catalogName: "Zucchini roh",
                status: .confirmed
            )]),
            CatalogNutrition(
                name: "Schmelzkäse",
                bases: ["unspecified": NutritionBasis(
                    values: info(kcal: 300), code: "M771600",
                    catalogName: "Schmelzkäse schnittfest, mind. 45 % Fett i. Tr.",
                    status: cheese
                )],
                candidateCodes: cheeseCandidates
            ),
            CatalogNutrition(name: "Hackfleisch", bases: [:], candidateCodes: ["U100", "U200"]),
        ])
    }

    private func aggregate(
        _ text: String, servings: Int = 1,
        nutrition: NutritionCatalog? = nil
    ) -> NutritionReport {
        NutritionAggregator.aggregate(
            recipe: Recipe(title: "Auflauf", servings: servings, ingredientsText: text),
            servings: servings, catalog: catalog(),
            nutritionCatalog: nutrition ?? nutritionCatalog(), resolve: { _ in nil }
        )
    }

    @Test("A proposed basis counts, and says that it is only proposed")
    func proposedContributesProvisionally() {
        let report = aggregate("200 g Zucchini\n100 g Schmelzkäse")

        // Both are in the sum — decision A: numbers now, marked, rather than
        // no numbers until fifteen mappings have been confirmed.
        #expect(report.total.kcal == 340)
        #expect(report.coverage.includedCount == 2)
        #expect(report.coverage.defects.isEmpty)
        #expect(report.coverage.unconfirmedCount == 1)
        #expect(report.coverage.isProvisional)
    }

    @Test("An unconfirmed line is not a gap, but does keep coverage incomplete")
    func unconfirmedBlocksCompleteness() {
        let provisional = aggregate("200 g Zucchini\n100 g Schmelzkäse")
        // Not a gap: it contributed, and the drill-down lists it as such.
        #expect(provisional.coverage.gaps.isEmpty)
        // Still not complete: the NRF badge is a health verdict, and one
        // computed on an unchecked mapping is exactly what O1 gated against.
        // The Schmelzkäse guess can be threefold off in fat.
        #expect(!provisional.coverage.isComplete)

        let confirmed = aggregate(
            "200 g Zucchini\n100 g Schmelzkäse",
            nutrition: nutritionCatalog(cheese: .confirmed)
        )
        #expect(confirmed.coverage.unconfirmedCount == 0)
        #expect(confirmed.coverage.isComplete)
    }

    @Test("Deliberately without ends the question instead of repeating it")
    func deliberatelyWithoutIsAnAnswer() {
        var entries = nutritionCatalog().entries
        entries.removeAll { $0.name == "Hackfleisch" }
        entries.append(CatalogNutrition(
            name: "Hackfleisch", bases: ["unspecified": .deliberatelyWithout]
        ))
        let decided = aggregate(
            "200 g Zucchini\n200 g Hackfleisch",
            nutrition: NutritionCatalog(entries: entries)
        )

        #expect(decided.coverage.gaps.first?.reason == .deliberatelyWithout)
        // Listed, but settled: no defect, so coverage can be complete, and
        // nothing puts it back on the list of things to clear up.
        #expect(decided.coverage.defects.isEmpty)
        #expect(decided.coverage.isComplete)
        #expect(!decided.coverage.openIngredientNames.contains("Hackfleisch"))

        // Before the decision the same line is a named gap that does ask.
        let undecided = aggregate("200 g Zucchini\n200 g Hackfleisch")
        #expect(undecided.coverage.gaps.first?.reason == .noNutritionValues)
        #expect(!undecided.coverage.isComplete)
        #expect(undecided.coverage.openIngredientNames.contains("Hackfleisch"))
    }

    @Test("A basis pointing at a row that is not there is orphaned, not silently absent")
    func orphanedBasisIsItsOwnGap() {
        let assignment = BasisAssignment.confirmed(
            code: "GONE", catalogName: "Etwas, das es gab", datasetVersion: "BLS 4.0"
        )
        let basis = assignment.basis(bls: BLSCatalog(
            source: .init(datasetVersion: "BLS 4.0", release: "", license: "", attribution: "", changeNote: ""),
            entries: []
        ), source: "BLS 4.0")
        #expect(basis.status == .orphaned)

        var entries = nutritionCatalog().entries
        entries.append(CatalogNutrition(name: "Hackfleisch", bases: ["unspecified": basis]))
        let report = aggregate(
            "200 g Hackfleisch", nutrition: NutritionCatalog(entries: entries.reversed())
        )

        #expect(report.coverage.gaps.first?.reason == .orphanedBasis)
        // A broken answer is a defect; only a *settled* one is not.
        #expect(report.coverage.defects.count == 1)
        #expect(report.coverage.gaps.first?.ingredientName == "Hackfleisch")
    }

    @Test("Candidates ride on gaps, not only on the lines that worked")
    func gapsCarryCandidates() {
        let report = aggregate("200 g Hackfleisch\n100 g Schmelzkäse")

        // The line *without* a basis is the one the picker exists for, and
        // until now it was the only one arriving with nothing to offer.
        let gap = report.coverage.gaps.first { $0.ingredientName == "Hackfleisch" }
        #expect(gap?.candidateCodes == ["U100", "U200"])

        let contribution = report.coverage.contributions.first { $0.ingredientName == "Schmelzkäse" }
        #expect(contribution?.candidateCodes == ["M771600", "M771400"])
    }

    @Test("Own values laid over a shipped entry keep its candidate list")
    func ownValuesKeepCandidates() {
        // The legacy path built an own entry from flat scalars and handed it
        // an empty candidate list, which then replaced the shipped entry
        // wholesale — so the one ingredient the cook had already touched was
        // the one the picker could offer nothing for.
        let merged = nutritionCatalog().merging([
            CatalogNutrition(
                name: "Schmelzkäse",
                perHundredGrams: ["unspecified": info(kcal: 250)],
                source: CatalogNutrition.ownSource
            )
        ])
        let entry = merged.nutrition(forCanonicalName: "Schmelzkäse")
        #expect(entry?.basis(for: .unspecified)?.values.kcal == 250)
        #expect(entry?.basis(for: .unspecified)?.status == .confirmed)
        #expect(entry?.candidateCodes == ["M771600", "M771400"])
    }

    @Test("A coverage cached before the status model still decodes")
    func oldCoverageStillDecodes() throws {
        // `RecipeNutrition` is JSON inside `StoredRecipeNutrition`. A new
        // non-optional field without a lenient decode fails silently, which
        // reads as a permanent cache miss rather than as an error.
        let json = Data("""
        {"includedCount":1,
         "gaps":[{"ingredientName":"Safran","reason":"noNutritionValues"}],
         "contributions":[{"ingredientName":"Zucchini","basisName":"Zucchini roh"}]}
        """.utf8)

        let coverage = try JSONDecoder().decode(NutritionCoverage.self, from: json)

        #expect(coverage.includedCount == 1)
        #expect(coverage.gaps.first?.candidateCodes == [])
        #expect(coverage.contributions.first?.isProvisional == false)
        #expect(coverage.unconfirmedCount == 0)
    }
}
