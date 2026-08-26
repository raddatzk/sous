import Foundation

/// Turns a recipe ingredient line's amount into grams, so it can be weighed
/// against a per-100g nutrition table.
public enum NutritionResolver {
    /// What a line's amount is worth in grams, and how firm that is.
    ///
    /// The concept's rule for the gram bridge: every derived number is an
    /// assumption and is displayed as one ("2 EL ≈ 28 g (Annahme)"). Only a
    /// mass on the line is not — 300 g is 300 g, and marking it would make
    /// the mark meaningless.
    public struct ResolvedAmount: Hashable, Sendable {
        public var grams: Double
        /// Whether the measure table had to be believed for this: a density,
        /// a piece weight, a group default, or water standing in for a
        /// density nobody authored.
        public var isAssumption: Bool

        public init(grams: Double, isAssumption: Bool) {
            self.grams = grams
            self.isAssumption = isAssumption
        }
    }

    /// Generic per-unit-type weights for imprecise units, used only when the
    /// specific ingredient has no `unitWeightsGrams` entry of its own — always
    /// shows *something* rather than nothing, at the cost of precision.
    ///
    /// These used to be six literals here. They are the same six numbers, read
    /// from `measures.json` now: a value a cook is meant to be able to correct
    /// has no business being a compiled constant.
    static let measures: MeasureTable = .bundled

    /// Water's density, used as the fallback for a volume amount whose
    /// ingredient has no density on record. Most kitchen liquids — stock,
    /// milk, vinegar, wine, juice — sit within a few percent of this; oil is
    /// the noteworthy exception at ~0.92, which is why oil has an entry.
    /// Wrong by a little is still far closer than the alternative this
    /// replaces: silently counting a spoonful of oil or a glass of milk as
    /// 0 kcal because nobody has authored its exact density yet.
    static let fallbackDensityGramsPerMl = 1.0

    /// Grams a single ingredient line represents, or `nil` when it truly
    /// cannot be resolved — an unquantified line ("Salz nach Geschmack"), or
    /// a counted unit with no per-ingredient weight on record.
    public static func resolvedGrams(
        for ingredient: RecipeIngredient,
        catalog: IngredientCatalog = .bundled,
        nutritionCatalog: NutritionCatalog = .bundled
    ) -> Double? {
        resolve(for: ingredient, catalog: catalog, nutritionCatalog: nutritionCatalog)?.grams
    }

    /// The same, with the answer's firmness attached — what the coverage
    /// drill-down needs in order to put a "≈" on the number it shows.
    ///
    /// The order is most-specific-first, and a weight authored for the very
    /// unit written on the line comes before the general rule for that unit's
    /// dimension. That is what lets a cook say "an Esslöffel of my honey is
    /// 25 g" without their correction being overruled by a density that is
    /// perfectly right about a litre of it.
    public static func resolve(
        for ingredient: RecipeIngredient,
        catalog: IngredientCatalog = .bundled,
        nutritionCatalog: NutritionCatalog = .bundled
    ) -> ResolvedAmount? {
        guard let quantity = ingredient.quantity else { return nil }

        // A mass is not a conversion; nothing about the ingredient can make
        // 300 g weigh anything else.
        if quantity.unit.dimension == .mass, let grams = quantity.inBaseUnit {
            return ResolvedAmount(grams: grams, isAssumption: false)
        }

        let entry = nutritionCatalog.nutrition(
            forCanonicalName: catalog.nutritionName(for: ingredient)
        )

        if let specific = entry?.unitWeightsGrams[quantity.unit.symbol] {
            return ResolvedAmount(grams: quantity.amount * specific, isAssumption: true)
        }

        if quantity.unit.dimension == .volume, let milliliters = quantity.inBaseUnit {
            let density = entry?.densityGramsPerMl ?? fallbackDensityGramsPerMl
            return ResolvedAmount(grams: milliliters * density, isAssumption: true)
        }

        if let generic = measures.genericGrams(forUnit: quantity.unit.symbol) {
            return ResolvedAmount(grams: quantity.amount * generic, isAssumption: true)
        }
        return nil
    }
}
