import Foundation
import Testing
@testable import SousKit

@Suite("Nutrition gram resolution")
struct NutritionResolverTests {
    private func ingredient(
        name: String, quantity: Quantity?, state: IngredientState = .unspecified
    ) -> RecipeIngredient {
        RecipeIngredient(name: name, quantity: quantity, state: state)
    }

    @Test("A mass unit resolves directly, no catalog needed")
    func massResolvesDirectly() {
        let grams = NutritionResolver.resolvedGrams(
            for: ingredient(name: "Zucchini", quantity: Quantity(300, .gram)),
            catalog: IngredientCatalog(ingredients: []),
            nutritionCatalog: NutritionCatalog(entries: [])
        )
        #expect(grams == 300)
    }

    @Test("A volume unit resolves via the ingredient's own density")
    func volumeResolvesViaDensity() {
        let nutritionCatalog = NutritionCatalog(entries: [
            CatalogNutrition(name: "Olivenöl", perHundredGrams: [:], densityGramsPerMl: 0.92),
        ])
        let grams = NutritionResolver.resolvedGrams(
            for: ingredient(name: "Olivenöl", quantity: Quantity(2, .tablespoon)), // 30 ml
            catalog: IngredientCatalog(ingredients: [CatalogIngredient(name: "Olivenöl", category: .oils)]),
            nutritionCatalog: nutritionCatalog
        )
        #expect(grams == 27.6)
    }

    @Test("A volume unit with no density on record falls back to water density rather than vanishing")
    func volumeWithoutDensityFallsBackToWater() {
        // The fallback is for the liquids nobody has authored — stock, juice,
        // a syrup somebody invented — which sit within a few percent of
        // water. It is deliberately *not* what oil gets: oil has an entry,
        // and the test below is what proves the entry is reached.
        let grams = NutritionResolver.resolvedGrams(
            for: ingredient(name: "Gemüsebrühe", quantity: Quantity(200, .milliliter)),
            catalog: IngredientCatalog(ingredients: [CatalogIngredient(name: "Gemüsebrühe", category: .other)]),
            nutritionCatalog: NutritionCatalog(entries: [])
        )
        #expect(grams == 200) // 200 ml * 1.0 g/ml fallback
    }

    @Test("Oil computes through its density, not through water")
    func bundledOilUsesItsDensity() throws {
        // Against the shipped tables, not a fixture: the seam this closes is
        // that `NutritionCatalog.make` used to hardcode `densityGramsPerMl:
        // nil`, so a perfectly good curated density never reached anything.
        let amount = try #require(NutritionResolver.resolve(
            for: ingredient(name: "Olivenöl", quantity: Quantity(2, .tablespoon)) // 30 ml
        ))
        #expect(abs(amount.grams - 27.6) < 0.001) // 30 ml * 0.92 g/ml
        #expect(amount.isAssumption)
    }

    @Test("An oil nobody named individually takes its food group's density")
    func groupDensityAnswersUnnamedOils() throws {
        // The one group-only density row in the file — every edible fat at
        // 0.92 — used to be dropped on the floor by the index.
        let entry = try #require(
            NutritionCatalog.bundled.nutrition(forCanonicalName: "Erdnussöl")
        )
        #expect(entry.densityGramsPerMl == 0.92)
    }

    @Test("A mass is not an assumption; everything derived is")
    func onlyDerivedAmountsAreAssumptions() throws {
        let weighed = try #require(NutritionResolver.resolve(
            for: ingredient(name: "Zucchini", quantity: Quantity(300, .gram)),
            catalog: IngredientCatalog(ingredients: []),
            nutritionCatalog: NutritionCatalog(entries: [])
        ))
        #expect(weighed.grams == 300)
        #expect(weighed.isAssumption == false)

        let counted = try #require(NutritionResolver.resolve(
            for: ingredient(name: "Zwiebel", quantity: Quantity(2, .piece))
        ))
        #expect(counted.grams == 220)
        #expect(counted.isAssumption)
    }

    @Test("A weight written for the very unit on the line beats the density")
    func unitWeightBeatsDensity() {
        // The concept's "my onions are bigger", for a unit that is not Stk.:
        // saying what an Esslöffel of this honey weighs must not be overruled
        // by a density that is perfectly right about a litre of it.
        let nutritionCatalog = NutritionCatalog(entries: [
            CatalogNutrition(
                name: "Honig", perHundredGrams: [:],
                unitWeightsGrams: ["EL": 25], densityGramsPerMl: 1.42
            ),
        ])
        let grams = NutritionResolver.resolvedGrams(
            for: ingredient(name: "Honig", quantity: Quantity(2, .tablespoon)),
            catalog: IngredientCatalog(ingredients: [CatalogIngredient(name: "Honig", category: .baking)]),
            nutritionCatalog: nutritionCatalog
        )
        #expect(grams == 50) // not 2 * 15 ml * 1.42 = 42.6
    }

    @Test("A cup of flour is the grain group's cup, not the generic one")
    func groupWeightAnswersACup() {
        // `byGroup` used to be indexed nowhere and called from nowhere. It
        // answers the units that convert to no volume at all; the rows that
        // named a spoon left the file, because a spoon is a volume.
        let grams = NutritionResolver.resolvedGrams(
            for: ingredient(name: "Dinkelmehl", quantity: Quantity(1, .cup))
        )
        #expect(grams == 120) // group C, not the generic 150 g cup
    }

    @Test("A pinch of a spice is the spice group's pinch")
    func groupWeightAnswersAPinch() {
        let grams = NutritionResolver.resolvedGrams(
            for: ingredient(name: "Pfeffer", quantity: Quantity(1, .pinch))
        )
        #expect(grams == 0.4) // group R, not the generic 0.3 g pinch
    }

    @Test("A measure written under a spelling still reaches the word")
    func aliasReachesTheMeasure() throws {
        // "Vanillezucker" is a spelling of "Vanille" in the vocabulary, and
        // its packet weight was written down under the spelling — which made
        // it unreachable, since the build only ever asked for the word.
        let entry = try #require(NutritionCatalog.bundled.nutrition(forCanonicalName: "Vanille"))
        #expect(entry.unitWeightsGrams[IngredientUnit.package.symbol] == 8)
    }

    @Test("A clove resolves via the ingredient's own unit weight")
    func cloveResolvesViaUnitWeight() {
        let nutritionCatalog = NutritionCatalog(entries: [
            CatalogNutrition(name: "Knoblauch", perHundredGrams: [:], unitWeightsGrams: ["Zehe": 5]),
        ])
        let grams = NutritionResolver.resolvedGrams(
            for: ingredient(name: "Knoblauch", quantity: Quantity(2, .clove)),
            catalog: IngredientCatalog(ingredients: [CatalogIngredient(name: "Knoblauch", category: .vegetables)]),
            nutritionCatalog: nutritionCatalog
        )
        #expect(grams == 10)
    }

    @Test("A leaf with no specific weight falls back to the generic default")
    func leafFallsBackToGenericDefault() {
        let grams = NutritionResolver.resolvedGrams(
            for: ingredient(name: "Basilikum", quantity: Quantity(10, .leaf)),
            catalog: IngredientCatalog(ingredients: []),
            nutritionCatalog: NutritionCatalog(entries: [])
        )
        #expect(grams == 10) // 10 leaves * 1g generic default
    }

    @Test("An unquantified ingredient cannot be resolved")
    func unquantifiedIsNil() {
        let grams = NutritionResolver.resolvedGrams(
            for: ingredient(name: "Salz", quantity: nil),
            catalog: IngredientCatalog(ingredients: []),
            nutritionCatalog: NutritionCatalog(entries: [])
        )
        #expect(grams == nil)
    }

    @Test("A piece with no per-ingredient weight and no generic fallback stays nil")
    func pieceWithoutDataIsNil() {
        let grams = NutritionResolver.resolvedGrams(
            for: ingredient(name: "Zwiebel", quantity: Quantity(2, .piece)),
            catalog: IngredientCatalog(ingredients: []),
            nutritionCatalog: NutritionCatalog(entries: [])
        )
        #expect(grams == nil)
    }
}
