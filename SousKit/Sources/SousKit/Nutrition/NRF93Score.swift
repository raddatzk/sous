import Foundation

/// The Nutrient Rich Foods Index (NRF9.3): how nutrient-dense a food is per
/// calorie, independent of what kind of dish it is — unlike Nutri-Score,
/// which compares similar products to each other, this works across
/// categories and is meant to be read per portion, not per 100g.
public enum NRF93Score {
    /// Vitamin D is on `NutritionInfo` for display, but the standard NRF9.3
    /// basket does not include it — left out here on purpose.
    ///
    /// The reference table itself lives in ``NutrientReference``, shared
    /// with the dinner planner. The 9 nutrients to encourage count as %DV
    /// per 100 kcal capped at 100, so one abundant nutrient cannot carry
    /// the whole score; the 3 to limit count uncapped — a genuinely poor
    /// nutritional profile is meant to pull the score negative.
    public static func score(for nutrition: NutritionInfo) -> Double {
        guard nutrition.kcal > 0 else { return 0 }
        let positive = NutrientReference.lowerBounds.reduce(into: 0.0) { sum, nutrient in
            sum += min(100, percentPer100kcal(nutrient, nutrition))
        }
        let negative = NutrientReference.upperBounds.reduce(into: 0.0) { sum, nutrient in
            sum += percentPer100kcal(nutrient, nutrition)
        }
        return positive - negative
    }

    private static func percentPer100kcal(_ nutrient: NutrientReference, _ nutrition: NutritionInfo) -> Double {
        (nutrient.amount(nutrition) / nutrient.dailyValue) * 100 * (100 / nutrition.kcal)
    }
}
