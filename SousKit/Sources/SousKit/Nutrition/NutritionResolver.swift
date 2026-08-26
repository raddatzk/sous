import Foundation

/// Turns a recipe ingredient line's amount into grams, so it can be weighed
/// against a per-100g nutrition table.
public enum NutritionResolver {
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
    /// the noteworthy exception at ~0.92. Wrong by a little is still far
    /// closer than the alternative this replaces: silently counting a
    /// spoonful of oil or a glass of milk as 0 kcal because nobody has
    /// authored its exact density yet.
    static let fallbackDensityGramsPerMl = 1.0

    /// Grams a single ingredient line represents, or `nil` when it truly
    /// cannot be resolved — an unquantified line ("Salz nach Geschmack"), or
    /// a counted unit with no per-ingredient weight on record.
    public static func resolvedGrams(
        for ingredient: RecipeIngredient,
        catalog: IngredientCatalog = .bundled,
        nutritionCatalog: NutritionCatalog = .bundled
    ) -> Double? {
        guard let quantity = ingredient.quantity else { return nil }

        switch quantity.unit.dimension {
        case .mass:
            return quantity.inBaseUnit

        case .volume:
            guard let milliliters = quantity.inBaseUnit else {
                return imprecise(quantity, name: ingredient.name, catalog: catalog, nutritionCatalog: nutritionCatalog)
            }
            let canonicalName = catalog.canonicalName(for: ingredient.name)
            let density = nutritionCatalog.nutrition(forCanonicalName: canonicalName)?.densityGramsPerMl
                ?? fallbackDensityGramsPerMl
            return milliliters * density

        case .count, .imprecise:
            return imprecise(quantity, name: ingredient.name, catalog: catalog, nutritionCatalog: nutritionCatalog)
        }
    }

    private static func imprecise(
        _ quantity: Quantity,
        name: String,
        catalog: IngredientCatalog,
        nutritionCatalog: NutritionCatalog
    ) -> Double? {
        let canonicalName = catalog.canonicalName(for: name)
        let symbol = quantity.unit.symbol
        if let specific = nutritionCatalog.nutrition(forCanonicalName: canonicalName)?.unitWeightsGrams[symbol] {
            return quantity.amount * specific
        }
        if let generic = measures.genericGrams(forUnit: symbol) {
            return quantity.amount * generic
        }
        return nil
    }
}
