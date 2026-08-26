import Foundation
import Testing
@testable import SousKit

/// The state belongs to the *use*, not to the ingredient: 500 g raw and 300 g
/// cooked potatoes compute with different values and are still one thing to
/// buy. These are the two halves of that sentence, and the fallback order
/// that decides what happens when the data has only one of the two rows.
@Suite("Preparation states")
struct PreparationStateTests {
    private func info(kcal: Double) -> NutritionInfo {
        NutritionInfo(
            kcal: kcal, proteinG: 0, fatG: 0, saturatedFatG: 0, carbsG: 0, sugarG: 0,
            fiberG: 0, sodiumMg: 0, vitaminAMcg: 0, vitaminCMg: 0, vitaminDMcg: 0,
            vitaminEMg: 0, calciumMg: 0, ironMg: 0, magnesiumMg: 0, potassiumMg: 0
        )
    }

    private func basis(_ kcal: Double, _ name: String) -> NutritionBasis {
        NutritionBasis(values: info(kcal: kcal), code: name, catalogName: name, status: .confirmed)
    }

    // MARK: - The fallback order

    @Test("An exact state wins over every fallback")
    func exactStateWins() {
        let entry = CatalogNutrition(name: "Kartoffel", bases: [
            "raw": basis(70, "Kartoffel roh"),
            "cooked": basis(50, "Kartoffel gekocht"),
            "unspecified": basis(99, "Kartoffel"),
        ])
        #expect(entry.basis(for: .raw)?.values.kcal == 70)
        #expect(entry.basis(for: .cooked)?.values.kcal == 50)
        #expect(entry.basis(for: .unspecified)?.values.kcal == 99)
    }

    @Test("Saying nothing reads as raw, which is how the food was bought")
    func unspecifiedReadsAsRaw() {
        // The concept's default state: "normally raw / as purchased". The
        // order is `displayOrder`, not whatever a dictionary hands out first
        // — which row a figure rests on must not depend on hash order.
        let entry = CatalogNutrition(name: "Kartoffel", bases: [
            "raw": basis(70, "Kartoffel roh"),
            "cooked": basis(50, "Kartoffel gekocht"),
        ])
        #expect(entry.basis(for: .unspecified)?.catalogName == "Kartoffel roh")
    }

    @Test("Cooked falls back to raw rather than to nothing, and says so")
    func askedForCookedWithOnlyRaw() {
        // Kept deliberately: the error is a few percent of water, and the
        // alternative drops the line out of the sum entirely. What makes it
        // honest rather than silent is `hasOwnBasis(for:)`, which the
        // drill-down reads to print the line's state beside the row's.
        let entry = CatalogNutrition(name: "Zucchini", bases: ["raw": basis(20, "Zucchini roh")])

        #expect(entry.basis(for: .cooked)?.catalogName == "Zucchini roh")
        #expect(entry.hasOwnBasis(for: .cooked) == false)
        #expect(entry.hasOwnBasis(for: .raw))
    }

    @Test("With only a cooked row, even raw reads as cooked")
    func onlyCookedIsStillAnAnswer() {
        let entry = CatalogNutrition(name: "Nudeln", bases: ["cooked": basis(150, "Nudeln gekocht")])

        #expect(entry.basis(for: .raw)?.catalogName == "Nudeln gekocht")
        #expect(entry.basis(for: .unspecified)?.catalogName == "Nudeln gekocht")
        #expect(entry.hasOwnBasis(for: .raw) == false)
    }

    @Test("An entry with no bases has no basis for any state")
    func noBasesNoAnswer() {
        let entry = CatalogNutrition(name: "Kurkuma", bases: [:])

        for state in IngredientState.displayOrder {
            #expect(entry.basis(for: state) == nil)
        }
    }

    // MARK: - Two states, one recipe

    private func potatoCatalog() -> (IngredientCatalog, NutritionCatalog) {
        (
            IngredientCatalog(ingredients: [
                CatalogIngredient(name: "Kartoffel", aliases: ["Kartoffeln"], category: .vegetables),
            ]),
            NutritionCatalog(entries: [
                CatalogNutrition(name: "Kartoffel", bases: [
                    "raw": basis(70, "Kartoffel geschält, roh"),
                    "cooked": basis(50, "Kartoffel geschält, gekocht"),
                ]),
            ])
        )
    }

    @Test("Raw and cooked demand of one ingredient compute differently")
    func statesComputeApart() throws {
        let (catalog, nutrition) = potatoCatalog()
        let recipe = Recipe(
            title: "Auflauf", servings: 1,
            ingredientsText: "500 g Kartoffeln\n300 g Kartoffeln, gegart"
        )
        let report = NutritionAggregator.aggregate(
            recipe: recipe, servings: 1, catalog: catalog,
            nutritionCatalog: nutrition, resolve: { _ in nil }
        )

        // 500 g raw at 70 kcal/100 g plus 300 g cooked at 50 — not 800 g of
        // one blended number, which is what one averaged row would give.
        #expect(report.total.kcal == 350 + 150)
        let cooked = try #require(report.coverage.contributions.first { $0.state == .cooked })
        #expect(cooked.basisName == "Kartoffel geschält, gekocht")
        #expect(cooked.matchesState)
        let raw = try #require(report.coverage.contributions.first { $0.state == .unspecified })
        #expect(raw.basisName == "Kartoffel geschält, roh")
    }

    @Test("A state the entry does not have counts, and the line says which row it used")
    func mismatchedStateIsMarked() throws {
        let catalog = IngredientCatalog(ingredients: [
            CatalogIngredient(name: "Zucchini", category: .vegetables),
        ])
        let nutrition = NutritionCatalog(entries: [
            CatalogNutrition(name: "Zucchini", bases: ["raw": basis(20, "Zucchini roh")]),
        ])
        let report = NutritionAggregator.aggregate(
            recipe: Recipe(title: "Pfanne", servings: 1, ingredientsText: "200 g Zucchini, gegart"),
            servings: 1, catalog: catalog, nutritionCatalog: nutrition, resolve: { _ in nil }
        )

        #expect(report.total.kcal == 40)
        let line = try #require(report.coverage.contributions.first)
        #expect(line.state == .cooked)
        #expect(line.matchesState == false)
        #expect(line.basisName == "Zucchini roh")
    }

    // MARK: - One place on the list

    @Test("Raw and cooked demand land on one item, annotated")
    func shoppingBundlesAcrossStatesAndAnnotates() throws {
        let catalog = IngredientCatalog(ingredients: [
            CatalogIngredient(name: "Kartoffel", aliases: ["Kartoffeln"], category: .vegetables),
        ])
        let recipe = Recipe(
            title: "Auflauf", servings: 2,
            ingredientsText: "500 g Kartoffeln\n300 g Kartoffeln, gegart"
        )
        let capture = ShoppingListBuilder.build(
            from: [(recipe, 2)], catalog: catalog, resolve: { _ in nil }
        )

        // One key, two demands: the state is carried, not bundled by.
        #expect(Set(capture.demands.map(\.key)).count == 1)
        let item = ShoppingItem(
            key: "kartoffel", name: "Kartoffel",
            demands: capture.demands.map(\.demand)
        )
        #expect(item.quantities.map(\.amount) == [800])

        let stated = item.statedQuantities
        #expect(stated.count == 1)
        let cooked = try #require(stated.first)
        #expect(cooked.state == .cooked)
        #expect(cooked.quantities.map(\.amount) == [300])
        #expect(cooked.state.shoppingAnnotation == "gegart gewogen")
    }

    // MARK: - The concept's own two cases, against the shipped data

    @Test("The potato case: 500 g raw and 300 g cooked, against the real tables")
    func potatoCaseAgainstBundledData() throws {
        // Concept §9. Not a fixture: the whole point of the case is that the
        // shipped synonym table really does carry two codes for "Kartoffel"
        // and that a line can reach the second one.
        let report = NutritionAggregator.aggregate(
            recipe: Recipe(
                title: "Auflauf", servings: 1,
                ingredientsText: "500 g Kartoffeln\n300 g Kartoffeln, gegart"
            ),
            servings: 1, resolve: { _ in nil }
        )

        let names = report.coverage.contributions.map(\.basisName)
        #expect(names.contains("Kartoffel geschält, roh"))
        #expect(names.contains("Kartoffel geschält, gekocht"))
        #expect(report.coverage.contributions.allSatisfy { $0.matchesState })
        // Weighed on the line, so no assumption is involved on either.
        #expect(report.coverage.contributions.allSatisfy { $0.isAssumedGrams == false })
    }

    @Test("The oil case: a spoonful of oil is not a spoonful of water")
    func oilCaseAgainstBundledData() throws {
        let report = NutritionAggregator.aggregate(
            recipe: Recipe(title: "Dressing", servings: 1, ingredientsText: "2 EL Olivenöl"),
            servings: 1, resolve: { _ in nil }
        )
        let line = try #require(report.coverage.contributions.first)

        let grams = try #require(line.grams)
        #expect(line.quantity == Quantity(2, .tablespoon))
        #expect(abs(grams - 27.6) < 0.001)
        // The drill-down's "≈" and "(Annahme)" hang on this flag.
        #expect(line.isAssumedGrams)
        // Water would have made it 30 g, and the difference is what the
        // whole density path exists for.
        #expect(report.total.kcal < 30 * 9)
    }

    @Test("An item nobody stated anything about annotates nothing")
    func noStateNoAnnotation() {
        let item = ShoppingItem(
            key: "tomate", name: "Tomate",
            demands: [ShoppingDemand(writtenName: "Tomaten", quantity: Quantity(500, .gram))]
        )
        #expect(item.statedQuantities.isEmpty)
    }

    @Test("Lapsed demand is not annotated — it is not wanted any more")
    func lapsedStaysOut() {
        let item = ShoppingItem(
            key: "kartoffel", name: "Kartoffel",
            demands: [
                ShoppingDemand(
                    writtenName: "Kartoffeln", quantity: Quantity(300, .gram),
                    state: .cooked, isLapsed: true
                ),
            ]
        )
        #expect(item.statedQuantities.isEmpty)
        #expect(item.quantities.isEmpty)
    }
}
