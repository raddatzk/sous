import Foundation

/// One catalog ingredient's nutrition, as curated from BLS.
///
/// `perHundredGrams` is keyed by `IngredientState.rawValue` rather than the
/// enum itself: BLS often lists a food raw and cooked separately (very
/// different water content), which the merge step folds into one entry with
/// several state variants instead of two unrelated catalog ingredients.
public struct CatalogNutrition: Hashable, Sendable {
    public var name: String
    public var perHundredGrams: [String: NutritionInfo]
    /// Grams a single unit of an imprecise or counted measure is worth for
    /// this ingredient specifically — "1 Zehe Knoblauch" ≈ 5 g. Keyed by
    /// `IngredientUnit.symbol`. Absent unless authored by hand.
    public var unitWeightsGrams: [String: Double]
    /// Needed to turn a volume amount into grams — a teaspoon of oil and a
    /// teaspoon of honey do not weigh the same. `nil` unless authored by hand.
    public var densityGramsPerMl: Double?

    public init(
        name: String,
        perHundredGrams: [String: NutritionInfo],
        unitWeightsGrams: [String: Double] = [:],
        densityGramsPerMl: Double? = nil
    ) {
        self.name = name
        self.perHundredGrams = perHundredGrams
        self.unitWeightsGrams = unitWeightsGrams
        self.densityGramsPerMl = densityGramsPerMl
    }

    /// The values for `state`, falling back to raw, then to whatever is
    /// there — a recipe almost never says an amount is post-cooking, so
    /// "unspecified" reads as raw when a raw variant exists at all.
    public func nutrition(for state: IngredientState) -> NutritionInfo? {
        perHundredGrams[state.rawValue]
            ?? perHundredGrams[IngredientState.raw.rawValue]
            ?? perHundredGrams.values.first
    }
}

extension CatalogNutrition: Codable {
    private enum CodingKeys: String, CodingKey {
        case name, perHundredGrams, unitWeightsGrams, densityGramsPerMl
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            perHundredGrams: try container.decode([String: NutritionInfo].self, forKey: .perHundredGrams),
            unitWeightsGrams: try container.decodeIfPresent([String: Double].self, forKey: .unitWeightsGrams) ?? [:],
            densityGramsPerMl: try container.decodeIfPresent(Double.self, forKey: .densityGramsPerMl)
        )
    }
}
