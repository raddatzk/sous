import Foundation
import Testing
@testable import SousKit

/// The basis at the point where it decides something: whether a line counts,
/// and what that does to the coverage a badge is gated on. Since phase 6b a
/// basis is numbers or the settled answer that there are none — nothing is
/// "proposed" or "orphaned" any more (INGREDIENTS-DATA §3 A).
@Suite("The basis model")
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

    /// Zucchini and Schmelzkäse have a basis, and Hackfleisch is a known
    /// word with none at all.
    private func nutritionCatalog(
        cheeseCandidates: [String] = ["M771600", "M771400"]
    ) -> NutritionCatalog {
        NutritionCatalog(entries: [
            CatalogNutrition(name: "Zucchini", bases: ["raw": NutritionBasis(
                values: info(kcal: 20), code: "G100", catalogName: "Zucchini roh"
            )]),
            CatalogNutrition(
                name: "Schmelzkäse",
                bases: ["unspecified": NutritionBasis(
                    values: info(kcal: 300), code: "M771600",
                    catalogName: "Schmelzkäse schnittfest, mind. 45 % Fett i. Tr."
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

    @Test("A mapped basis simply counts, and a sum of mapped lines is complete")
    func aMappedBasisCounts() {
        let report = aggregate("200 g Zucchini\n100 g Schmelzkäse")

        // The catalog answers: the synonym table's mapping is the basis, not
        // a guess waiting for the cook.
        #expect(report.total.kcal == 340)
        #expect(report.coverage.includedCount == 2)
        #expect(report.coverage.gaps.isEmpty)
        #expect(report.coverage.isComplete)
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

        // Without the catalog's answer the same line is a named gap.
        let undecided = aggregate("200 g Zucchini\n200 g Hackfleisch")
        #expect(undecided.coverage.gaps.first?.reason == .noNutritionValues)
        #expect(!undecided.coverage.isComplete)
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

    @Test("A coverage cached before or with the status model still decodes")
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
        #expect(coverage.isComplete == false)

        // One cached while there was a status model carries a flag nothing
        // reads any more; it is ignored, not an error.
        let withFlag = Data("""
        {"includedCount":1,"gaps":[],
         "contributions":[{"ingredientName":"Zucchini","basisName":"Zucchini roh","isProvisional":true}]}
        """.utf8)
        #expect(try JSONDecoder().decode(NutritionCoverage.self, from: withFlag).isComplete)
    }

    @Test("A basis encoded with a retired status reads as numbers")
    func retiredStatusesDecode() throws {
        for status in ["proposed", "confirmed", "orphaned"] {
            let json = Data("""
            {"values":{"kcal":20,"proteinG":0,"fatG":0,"saturatedFatG":0,"carbsG":0,"sugarG":0,
             "fiberG":0,"sodiumMg":0,"vitaminAMcg":0,"vitaminCMg":0,"vitaminDMcg":0,"vitaminEMg":0,
             "calciumMg":0,"ironMg":0,"magnesiumMg":0,"potassiumMg":0},"status":"\(status)"}
            """.utf8)
            let basis = try JSONDecoder().decode(NutritionBasis.self, from: json)
            #expect(basis.status == .computed)
        }
        let without = try JSONDecoder().decode(
            NutritionBasis.self, from: JSONEncoder().encode(NutritionBasis.deliberatelyWithout)
        )
        #expect(without.status == .deliberatelyWithout)
    }

    @Test("A coverage cached before states and grams were carried still decodes")
    func oldCoverageDecodesWithoutTheGramBridge() throws {
        // Phase 5's additions travel in the same blob, and the share
        // extension can have written an older one — it runs no migration and
        // builds its own stack, so it may well be the last writer.
        let json = Data("""
        {"includedCount":1,
         "gaps":[],
         "contributions":[{"ingredientName":"Olivenöl","basisName":"Olivenöl"}]}
        """.utf8)

        let coverage = try JSONDecoder().decode(NutritionCoverage.self, from: json)
        let line = try #require(coverage.contributions.first)

        #expect(line.grams == nil)
        #expect(line.quantity == nil)
        #expect(line.isAssumedGrams == false)
        #expect(line.state == .unspecified)
        // "Nothing ever said otherwise" is exactly what a figure cached
        // before states were read is claiming, so it must not read as a
        // mismatch and put a state on screen that nobody wrote.
        #expect(line.matchesState)
    }

    @Test("A coverage carrying the gram bridge round-trips")
    func gramBridgeRoundTrips() throws {
        let coverage = NutritionCoverage(includedCount: 1, gaps: [], contributions: [
            NutritionCoverage.Contribution(
                ingredientName: "Olivenöl", basisName: "Olivenöl",
                quantity: Quantity(2, .tablespoon), grams: 27.6, isAssumedGrams: true,
                state: .cooked, matchesState: false
            ),
        ])

        let decoded = try JSONDecoder().decode(
            NutritionCoverage.self, from: JSONEncoder().encode(coverage)
        )
        let line = try #require(decoded.contributions.first)

        #expect(line.quantity == Quantity(2, .tablespoon))
        #expect(line.grams == 27.6)
        #expect(line.isAssumedGrams)
        #expect(line.state == .cooked)
        #expect(line.matchesState == false)
    }
}
