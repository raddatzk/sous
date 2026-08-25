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
    /// Where these numbers came from: "BLS 4.0" for everything bundled,
    /// "Eigene Angabe" for what a cook typed in. Carried per entry rather
    /// than assumed app-wide, because the catalog stops being one source's
    /// the moment a cook adds anything — and because CC BY 4.0 asks the data
    /// to say whose it is wherever it is shown.
    public var source: String

    public init(
        name: String,
        perHundredGrams: [String: NutritionInfo],
        unitWeightsGrams: [String: Double] = [:],
        densityGramsPerMl: Double? = nil,
        source: String = CatalogNutrition.blsSource
    ) {
        self.name = name
        self.perHundredGrams = perHundredGrams
        self.unitWeightsGrams = unitWeightsGrams
        self.densityGramsPerMl = densityGramsPerMl
        self.source = source
    }

    /// The Bundeslebensmittelschlüssel release everything bundled comes from.
    public static let blsSource = "BLS 4.0"
    /// What a cook's own numbers say by default.
    public static let ownSource = "Eigene Angabe"

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
        case name, perHundredGrams, unitWeightsGrams, densityGramsPerMl, source
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            perHundredGrams: try container.decode([String: NutritionInfo].self, forKey: .perHundredGrams),
            unitWeightsGrams: try container.decodeIfPresent([String: Double].self, forKey: .unitWeightsGrams) ?? [:],
            densityGramsPerMl: try container.decodeIfPresent(Double.self, forKey: .densityGramsPerMl),
            // The bundled file predates this field and is BLS-derived
            // throughout, so its absence says BLS rather than "unknown".
            source: try container.decodeIfPresent(String.self, forKey: .source) ?? CatalogNutrition.blsSource
        )
    }
}
