import Foundation
import Testing
@testable import SousKit

/// Prints where "proteinreich" and "ballaststoffreich" actually sit in a real
/// library, against the cook's own hand-set categories, so the thresholds can
/// be chosen from labelled dishes rather than from a regulation read out of
/// context.
///
/// Not a test: it asserts almost nothing and exists for its output, the same
/// way ``RecipeEffortCalibrationTests`` does. The EU health-claim thresholds
/// (20% of energy from protein; 3 g fibre per 100 kcal) are the starting
/// guess printed alongside — whether they agree with this kitchen is the
/// question the output answers.
///
///     SOUS_TAG_LIBRARY=./Rezepte.melarecipes \
///         swift test --filter NutritionTagCalibration
@Suite(
    "NutritionTagCalibration",
    .enabled(if: ProcessInfo.processInfo.environment["SOUS_TAG_LIBRARY"] != nil)
)
struct NutritionTagCalibrationTests {
    /// One recipe measured, with the labels its cook gave it.
    private struct Measured {
        var title: String
        var perPortion: NutritionInfo
        var coverage: NutritionCoverage
        var categories: [String]

        /// Protein's share of the dish's energy — the EU claim's own measure,
        /// and the one that survives a dish being large or small.
        var proteinEnergyShare: Double? {
            guard perPortion.kcal > 0 else { return nil }
            return perPortion.proteinG * 4 / perPortion.kcal
        }

        /// Fibre per 100 kcal, the energy-relative half of the EU claim.
        var fiberPer100kcal: Double? {
            guard perPortion.kcal > 0 else { return nil }
            return perPortion.fiberG / (perPortion.kcal / 100)
        }

        /// How much of the dish the numbers actually rest on.
        var completeness: Double {
            guard coverage.accountableCount > 0 else { return 0 }
            return Double(coverage.includedCount) / Double(coverage.accountableCount)
        }

        func isLabelled(_ label: String) -> Bool {
            categories.contains { $0.compare(label, options: .caseInsensitive) == .orderedSame }
        }
    }

    @Test("Where the cook's own protein and fibre labels fall")
    func thresholds() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SOUS_TAG_LIBRARY"])
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let batch = try MelaImport.read(try Data(contentsOf: url), named: url.lastPathComponent)

        let recipes = batch.recipes.map(\.recipe)
        let byID = Dictionary(recipes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let measured = recipes.map { recipe -> Measured in
            let report = NutritionAggregator.aggregate(
                recipe: recipe, servings: recipe.servings, resolve: { byID[$0] }
            )
            return Measured(
                title: recipe.title,
                perPortion: report.total.scaled(by: 1 / Double(max(1, recipe.servings))),
                coverage: report.coverage,
                categories: recipe.categories
            )
        }

        print("\n=== \(url.lastPathComponent) ===")
        print("recipes: \(recipes.count), problems: \(batch.problems.count)")

        // Coverage first: a tag may only be claimed on a dish whose numbers
        // are worth claiming anything about, so the shape of coverage across
        // the library decides how many recipes are even eligible.
        let completeness = measured.map(\.completeness).sorted()
        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            return values[min(values.count - 1, max(0, Int((Double(values.count - 1) * fraction).rounded())))]
        }
        print(String(
            format: "\ncoverage  p10 %.2f  p25 %.2f  median %.2f  p75 %.2f  p90 %.2f",
            percentile(completeness, 0.10), percentile(completeness, 0.25),
            percentile(completeness, 0.50), percentile(completeness, 0.75),
            percentile(completeness, 0.90)
        ))
        for floor in [0.6, 0.7, 0.8, 0.9, 1.0] {
            let eligible = measured.filter { $0.completeness >= floor && $0.perPortion.kcal > 0 }
            print(String(format: "  ≥ %.0f%% complete: %3d of %d recipes",
                         floor * 100, eligible.count, measured.count))
        }

        report(
            label: "proteinreich",
            measured: measured,
            value: { $0.proteinEnergyShare },
            format: { String(format: "%.0f%% der Energie", $0 * 100) },
            candidates: [0.12, 0.15, 0.18, 0.20, 0.22, 0.25, 0.30],
            euClaim: 0.20
        )

        report(
            label: "ballaststoffreich",
            measured: measured,
            value: { $0.fiberPer100kcal },
            format: { String(format: "%.1f g/100 kcal", $0) },
            candidates: [1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 5.0],
            euClaim: 3.0
        )

        // Fibre has a second, absolute reading worth seeing beside the first:
        // NutrientReference puts a day at 28 g, so a portion carrying a third
        // of that is a defensible "reich" on its own terms.
        report(
            label: "ballaststoffreich",
            measured: measured,
            value: { $0.perPortion.fiberG },
            format: { String(format: "%.1f g pro Portion", $0) },
            candidates: [5, 7, 8, 9, 10, 12, 14],
            euClaim: 28.0 / 3
        )

        // The only thing worth asserting: the measure ran over a real library
        // and produced numbers for a meaningful part of it.
        #expect(measured.contains { $0.perPortion.kcal > 0 })
    }

    /// Prints, for one label and one measure, how the cook's own labelled
    /// dishes separate from the rest — and what each candidate threshold
    /// would have got right and wrong.
    private func report(
        label: String,
        measured: [Measured],
        value: (Measured) -> Double?,
        format: (Double) -> String,
        candidates: [Double],
        euClaim: Double
    ) {
        // Only dishes the numbers can speak for. A dish whose coverage is
        // thin is not evidence either way, so it is neither a hit nor a miss.
        let usable = measured.compactMap { dish -> (Measured, Double)? in
            guard dish.completeness >= 0.7, let v = value(dish) else { return nil }
            return (dish, v)
        }
        let labelled = usable.filter { $0.0.isLabelled(label) }
        let unlabelled = usable.filter { !$0.0.isLabelled(label) }

        print("\n\n════ \(label) — \(format(euClaim)) wäre der EU-Claim ════")
        print("usable (coverage ≥ 70%, kcal > 0): \(usable.count)")
        print("  davon vom Koch gelabelt: \(labelled.count)")
        let missed = measured.filter { $0.isLabelled(label) }.count - labelled.count
        if missed > 0 { print("  (\(missed) gelabelte Rezepte fielen wegen Abdeckung raus)") }
        guard !labelled.isEmpty else { print("  keine Labels — nichts zu kalibrieren"); return }

        let labelledValues = labelled.map(\.1).sorted()
        let unlabelledValues = unlabelled.map(\.1).sorted()
        print("\n  gelabelt    min \(format(labelledValues.first!))  " +
              "p25 \(format(percentile(labelledValues, 0.25)))  " +
              "median \(format(percentile(labelledValues, 0.5)))  " +
              "max \(format(labelledValues.last!))")
        if !unlabelledValues.isEmpty {
            print("  ungelabelt  min \(format(unlabelledValues.first!))  " +
                  "median \(format(percentile(unlabelledValues, 0.5)))  " +
                  "p75 \(format(percentile(unlabelledValues, 0.75)))  " +
                  "p90 \(format(percentile(unlabelledValues, 0.90)))  " +
                  "max \(format(unlabelledValues.last!))")
        }

        print("\n  Schwelle           trifft  verpasst  zusätzlich  Recall  Precision")
        for threshold in candidates {
            let hit = labelled.count { $0.1 >= threshold }
            let missedHere = labelled.count - hit
            let extra = unlabelled.count { $0.1 >= threshold }
            let recall = Double(hit) * 100 / Double(labelled.count)
            let precision = hit + extra > 0 ? Double(hit) * 100 / Double(hit + extra) : 0
            print(String(format: "  %-18@ %5d %9d %11d %6.0f%% %9.0f%%",
                         format(threshold) as NSString,
                         hit, missedHere, extra, recall, precision))
        }

        print("\n  --- gelabelt, aber niedrigster Wert (die Grenzfälle) ---")
        for (dish, v) in labelled.sorted(by: { $0.1 < $1.1 }).prefix(6) {
            print("   " + format(v).padding(toLength: 20, withPad: " ", startingAt: 0)
                  + dish.title.prefix(52))
        }
        print("  --- ungelabelt, aber höchster Wert (die Vorschlagskandidaten) ---")
        for (dish, v) in unlabelled.sorted(by: { $0.1 > $1.1 }).prefix(8) {
            print("   " + format(v).padding(toLength: 20, withPad: " ", startingAt: 0)
                  + dish.title.prefix(52))
        }
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        return values[min(values.count - 1, max(0, Int((Double(values.count - 1) * fraction).rounded())))]
    }

    /// Names the lines behind the most extreme figures in the library.
    ///
    /// A threshold is only worth arguing about once the numbers under it are
    /// sound, and the distribution above holds portions carrying more fibre
    /// than a whole day's reference — which is not a threshold question but a
    /// data question. This prints who contributed what, so the wrong line can
    /// be found by name.
    @Test("What the extreme figures are actually made of")
    func outliers() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SOUS_TAG_LIBRARY"])
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let batch = try MelaImport.read(try Data(contentsOf: url), named: url.lastPathComponent)
        let recipes = batch.recipes.map(\.recipe)
        let byID = Dictionary(recipes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        struct Row {
            var recipe: Recipe
            var report: NutritionReport
            var perPortion: NutritionInfo
        }
        let rows = recipes.map { recipe -> Row in
            let report = NutritionAggregator.aggregate(
                recipe: recipe, servings: recipe.servings, resolve: { byID[$0] }
            )
            return Row(
                recipe: recipe, report: report,
                perPortion: report.total.scaled(by: 1 / Double(max(1, recipe.servings)))
            )
        }

        func dump(_ row: Row, _ nutrient: String, _ pick: (NutritionInfo) -> Double) {
            print("\n─── \(row.recipe.title) — \(row.recipe.servings) Portionen, " +
                  String(format: "%.1f %@ pro Portion, %.0f kcal",
                         pick(row.perPortion), nutrient, row.perPortion.kcal))
            let servingFactor = 1 / Double(max(1, row.recipe.servings))
            let contributors = row.report.lines.compactMap { line -> (String, Double, String)? in
                guard let contribution = line.outcome.contribution else { return nil }
                let amount = line.resolvedAmount.map { String(format: "%.0f g", $0.grams) } ?? "?"
                return (line.ingredientName, pick(contribution) * servingFactor,
                        "\(amount) → \(line.basis?.catalogName ?? "?")")
            }
            for (name, value, basis) in contributors.sorted(by: { $0.1 > $1.1 }).prefix(6)
            where value > 0.05 {
                print(String(format: "   %6.1f  ", value)
                      + String(name.prefix(26)).padding(toLength: 28, withPad: " ", startingAt: 0)
                      + basis)
            }
        }

        print("\n\n════ Die höchsten Ballaststoffwerte pro Portion ════")
        for row in rows.sorted(by: { $0.perPortion.fiberG > $1.perPortion.fiberG }).prefix(6) {
            dump(row, "g Ballaststoffe", \.fiberG)
        }

        print("\n\n════ Die höchsten Proteinwerte pro Portion ════")
        for row in rows.sorted(by: { $0.perPortion.proteinG > $1.perPortion.proteinG }).prefix(4) {
            dump(row, "g Eiweiß", \.proteinG)
        }

        print("\n\n════ Gelabelt \"proteinreich\", aber niedrig gemessen ════")
        let labelledLow = rows
            .filter { $0.recipe.categories.contains { $0.caseInsensitiveCompare("proteinreich") == .orderedSame } }
            .filter { $0.perPortion.kcal > 0 && $0.perPortion.proteinG * 4 / $0.perPortion.kcal < 0.18 }
        for row in labelledLow.prefix(4) {
            dump(row, "g Eiweiß", \.proteinG)
            let coverage = row.report.coverage
            print("   Abdeckung: \(coverage.includedCount)/\(coverage.accountableCount)" +
                  ", fehlt: " + coverage.defects.map(\.ingredientName).prefix(6).joined(separator: ", "))
        }
    }

    /// The library's own gap list, most frequent first.
    ///
    /// Coverage is what decides whether a nutrition tag may be claimed at
    /// all, so the shortest path to more tags is not a cleverer threshold but
    /// these names — and the ones that carry protein are worth more than the
    /// ones that carry parsley.
    @Test("What the library is missing, most frequent first")
    func gaps() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SOUS_TAG_LIBRARY"])
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let batch = try MelaImport.read(try Data(contentsOf: url), named: url.lastPathComponent)
        let recipes = batch.recipes.map(\.recipe)
        let byID = Dictionary(recipes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var byName: [String: (count: Int, reasons: Set<NutritionCoverage.GapReason>)] = [:]
        var servingsOfOne = 0
        for recipe in recipes {
            if recipe.servings <= 1 { servingsOfOne += 1 }
            let report = NutritionAggregator.aggregate(
                recipe: recipe, servings: recipe.servings, resolve: { byID[$0] }
            )
            for gap in report.coverage.defects {
                let key = IngredientCatalog.normalize(gap.ingredientName)
                byName[key, default: (0, [])].count += 1
                byName[key, default: (0, [])].reasons.insert(gap.reason)
            }
        }

        print("\n\n════ Was der Bibliothek fehlt ════")
        print("Rezepte mit servings ≤ 1: \(servingsOfOne) von \(recipes.count)")
        print("verschiedene ungelöste Zutaten: \(byName.count)\n")
        for key in byName.keys.sorted(by: { byName[$0]!.count > byName[$1]!.count }).prefix(40) {
            let entry = byName[key]!
            let reasons = entry.reasons.map(\.label).sorted().joined(separator: ", ")
            print(String(format: "  %3d×  ", entry.count)
                  + String(key.prefix(30)).padding(toLength: 32, withPad: " ", startingAt: 0)
                  + reasons)
        }
    }
}
