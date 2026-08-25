import Foundation

/// The Nutrient Rich Foods Index (NRF9.3): how nutrient-dense a food is per
/// calorie, independent of what kind of dish it is — unlike Nutri-Score,
/// which compares similar products to each other, this works across
/// categories and is meant to be read per portion, not per 100g.
public enum NRF93Score {
    private struct Nutrient: Sendable {
        let amount: @Sendable (NutritionInfo) -> Double
        /// Adult reference daily value the FDA/NRF9.3 literature uses.
        let dailyValue: Double
    }

    /// The 9 nutrients to encourage, each %DV per 100 kcal capped at 100 so
    /// one abundant nutrient cannot carry the whole score.
    private static let beneficial: [Nutrient] = [
        Nutrient(amount: \.proteinG, dailyValue: 50),
        Nutrient(amount: \.fiberG, dailyValue: 28),
        Nutrient(amount: \.vitaminAMcg, dailyValue: 900),
        Nutrient(amount: \.vitaminCMg, dailyValue: 90),
        Nutrient(amount: \.vitaminEMg, dailyValue: 15),
        Nutrient(amount: \.calciumMg, dailyValue: 1300),
        Nutrient(amount: \.ironMg, dailyValue: 18),
        Nutrient(amount: \.magnesiumMg, dailyValue: 420),
        Nutrient(amount: \.potassiumMg, dailyValue: 4700),
    ]

    /// The 3 nutrients to limit, %DV per 100 kcal, uncapped — a genuinely
    /// poor nutritional profile is meant to pull the score negative.
    ///
    /// BLS reports total sugar, not "added sugar" specifically — no reliable
    /// free-sugar field exists for composite recipes, so total sugar stands
    /// in for it. This is a known, deliberate simplification versus the
    /// textbook NRF9.3 formula, not an oversight.
    private static let detrimental: [Nutrient] = [
        Nutrient(amount: \.saturatedFatG, dailyValue: 20),
        Nutrient(amount: \.sugarG, dailyValue: 50),
        Nutrient(amount: \.sodiumMg, dailyValue: 2300),
    ]

    /// Vitamin D is on `NutritionInfo` for display, but the standard NRF9.3
    /// basket does not include it — left out here on purpose.
    public static func score(for nutrition: NutritionInfo) -> Double {
        guard nutrition.kcal > 0 else { return 0 }
        let positive = beneficial.reduce(into: 0.0) { sum, nutrient in
            sum += min(100, percentPer100kcal(nutrient, nutrition))
        }
        let negative = detrimental.reduce(into: 0.0) { sum, nutrient in
            sum += percentPer100kcal(nutrient, nutrition)
        }
        return positive - negative
    }

    private static func percentPer100kcal(_ nutrient: Nutrient, _ nutrition: NutritionInfo) -> Double {
        (nutrient.amount(nutrition) / nutrient.dailyValue) * 100 * (100 / nutrition.kcal)
    }
}
