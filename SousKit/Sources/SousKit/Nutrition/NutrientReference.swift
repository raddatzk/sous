import Foundation

/// One nutrient with the adult reference daily value the FDA/NRF9.3
/// literature uses — the table ``NRF93Score`` has always scored against,
/// lifted out so the dinner planner reads the same numbers. Two readers of
/// one table cannot drift apart on what "enough protein" means.
struct NutrientReference: Sendable {
    let nutrient: Nutrient
    /// Adult reference daily value, per 2000 kcal.
    let dailyValue: Double

    /// The same reference as a density: how much of the nutrient 100 kcal
    /// of the day carries when the day exactly meets the daily value.
    var densityPer100kcal: Double { dailyValue / 20 }

    /// The word the app already uses for this nutrient in a label.
    var label: String { nutrient.label }

    func amount(_ nutrition: NutritionInfo) -> Double { nutrition[keyPath: nutrient.keyPath] }

    /// All twelve: what the NRF score needs stated before it may be shown.
    static var all: [NutrientReference] { lowerBounds + upperBounds }

    /// The 9 nutrients to encourage — under-delivery is what costs.
    static let lowerBounds: [NutrientReference] = [
        NutrientReference(nutrient: .proteinG, dailyValue: 50),
        NutrientReference(nutrient: .fiberG, dailyValue: 28),
        NutrientReference(nutrient: .vitaminAMcg, dailyValue: 900),
        NutrientReference(nutrient: .vitaminCMg, dailyValue: 90),
        NutrientReference(nutrient: .vitaminEMg, dailyValue: 15),
        NutrientReference(nutrient: .calciumMg, dailyValue: 1300),
        NutrientReference(nutrient: .ironMg, dailyValue: 18),
        NutrientReference(nutrient: .magnesiumMg, dailyValue: 420),
        NutrientReference(nutrient: .potassiumMg, dailyValue: 4700),
    ]

    /// The 3 nutrients to limit — over-delivery is what costs.
    ///
    /// BLS reports total sugar, not "added sugar" specifically — no reliable
    /// free-sugar field exists for composite recipes, so total sugar stands
    /// in for it. This is a known, deliberate simplification versus the
    /// textbook NRF9.3 formula, not an oversight.
    static let upperBounds: [NutrientReference] = [
        NutrientReference(nutrient: .saturatedFatG, dailyValue: 20),
        NutrientReference(nutrient: .sugarG, dailyValue: 50),
        NutrientReference(nutrient: .sodiumMg, dailyValue: 2300),
    ]
}
