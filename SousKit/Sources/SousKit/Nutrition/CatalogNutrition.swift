import Foundation

/// One set of per-100g values, and where they came from.
///
/// The provenance is not decoration: the concept asks that no number appear
/// without saying what it is based on, and "based on" for a BLS number means
/// a specific row of a specific release — "Kartoffel geschält, gekocht", not
/// "Kartoffel". Carried per state, because a food's raw and cooked values are
/// two different rows and each has to answer for itself.
public struct NutritionBasis: Codable, Hashable, Sendable {
    public var values: NutritionInfo
    /// The SBLS code these values are read from, `nil` for a cook's own
    /// numbers, which are a basis of equal standing with no code to name.
    public var code: String?
    /// The BLS catalog name at the time these values were shipped — what
    /// "beruht auf: …" prints.
    public var catalogName: String?

    public init(values: NutritionInfo, code: String? = nil, catalogName: String? = nil) {
        self.values = values
        self.code = code
        self.catalogName = catalogName
    }
}

/// What one catalog ingredient is worth, per 100 g, per preparation state.
///
/// Kept as a separate table from `CatalogIngredient`: the two are curated
/// independently — one is spellings, the other is a mapping into a food
/// database — and an ingredient with no nutrition must still be a recognized
/// ingredient, so that its gap can be *named* rather than look like a typo.
public struct CatalogNutrition: Hashable, Sendable, Codable {
    public var name: String
    /// Keyed by `IngredientState.rawValue`. BLS lists a food raw and cooked
    /// as separate rows with very different water content; they stay separate
    /// rows here too — nothing is averaged into a single blended entry.
    public var bases: [String: NutritionBasis]
    /// Grams a single unit of an imprecise or counted measure is worth for
    /// this ingredient specifically — "1 Zehe Knoblauch" ≈ 3 g. Keyed by
    /// `IngredientUnit.symbol`, filled from the measure table.
    public var unitWeightsGrams: [String: Double]
    /// Needed to turn a volume amount into grams — a teaspoon of oil and a
    /// teaspoon of honey do not weigh the same. Curated in `measures.json`
    /// but not yet consulted; phase 5 switches it on.
    public var densityGramsPerMl: Double?
    /// Where these numbers came from: "BLS 4.0" for everything bundled,
    /// "Eigene Angabe" for what a cook typed in. Carried per entry rather
    /// than assumed app-wide, because the catalog stops being one source's
    /// the moment a cook adds anything — and because CC BY 4.0 asks the data
    /// to say whose it is wherever it is shown.
    public var source: String
    /// Every BLS row this ingredient could be based on, best first. Carried
    /// through the result from here on; phase 4 turns it into a picker.
    public var candidateCodes: [String]

    public init(
        name: String,
        bases: [String: NutritionBasis],
        unitWeightsGrams: [String: Double] = [:],
        densityGramsPerMl: Double? = nil,
        source: String = CatalogNutrition.blsSource,
        candidateCodes: [String] = []
    ) {
        self.name = name
        self.bases = bases
        self.unitWeightsGrams = unitWeightsGrams
        self.densityGramsPerMl = densityGramsPerMl
        self.source = source
        self.candidateCodes = candidateCodes
    }

    /// For values that have no BLS row behind them — a cook's own numbers, or
    /// a test's. Same entry, just with nothing to name as its origin.
    public init(
        name: String,
        perHundredGrams: [String: NutritionInfo],
        unitWeightsGrams: [String: Double] = [:],
        densityGramsPerMl: Double? = nil,
        source: String = CatalogNutrition.blsSource
    ) {
        self.init(
            name: name,
            bases: perHundredGrams.mapValues { NutritionBasis(values: $0) },
            unitWeightsGrams: unitWeightsGrams,
            densityGramsPerMl: densityGramsPerMl,
            source: source
        )
    }

    public var perHundredGrams: [String: NutritionInfo] { bases.mapValues(\.values) }

    /// The Bundeslebensmittelschlüssel release everything bundled comes from.
    public static let blsSource = "BLS 4.0"
    /// What a cook's own numbers say by default.
    public static let ownSource = "Eigene Angabe"

    /// The basis for `state`, falling back to raw, then to the states in
    /// display order — a recipe almost never says an amount is post-cooking,
    /// so "unspecified" reads as raw when a raw variant exists at all.
    ///
    /// The last fallback walks `IngredientState.displayOrder` rather than
    /// taking whatever a dictionary hands out first: which row a figure is
    /// based on must not depend on hash order.
    public func basis(for state: IngredientState) -> NutritionBasis? {
        if let exact = bases[state.rawValue] { return exact }
        for fallback in IngredientState.displayOrder {
            if let match = bases[fallback.rawValue] { return match }
        }
        return nil
    }

    public func nutrition(for state: IngredientState) -> NutritionInfo? {
        basis(for: state)?.values
    }

    /// How the app says what a figure rests on: "beruht auf: Kartoffel
    /// geschält, gekocht (BLS 4.0)". `nil` where there is nothing to name —
    /// the cook's own values say "Quelle: Eigene Angabe" instead.
    public func provenance(for state: IngredientState) -> String? {
        guard let name = basis(for: state)?.catalogName else { return nil }
        return "\(name) (\(source))"
    }
}
