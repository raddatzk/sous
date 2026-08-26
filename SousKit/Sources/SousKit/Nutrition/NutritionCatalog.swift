import Foundation

/// Nutrition values for the ingredients `IngredientCatalog` knows by name.
///
/// The chain a written name walks is: name → aliases → synonym table → SBLS
/// code → BLS row. This type is where the last three steps happen; the first
/// belongs to `IngredientCatalog`, so that exactly one place decides what a
/// written ingredient means.
public struct NutritionCatalog: Sendable {
    private var byName: [String: CatalogNutrition]

    public init(entries: [CatalogNutrition]) {
        byName = Dictionary(entries.map { (IngredientCatalog.normalize($0.name), $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The catalog shipped with the app, assembled rather than read: the
    /// synonym table says which codes a kitchen word means, the BLS table
    /// holds the values, and the measure table holds what a piece of it
    /// weighs. Three files that each say one thing, joined by value.
    ///
    /// A word with no target gets no entry at all, on purpose: the aggregator
    /// tells "the catalog does not know this" and "the catalog knows it and
    /// has no values for it" apart by asking both catalogs, and the second
    /// reason is the one the 28 spice entries have to produce.
    public static let bundled: NutritionCatalog = {
        make(synonyms: .bundled, bls: .bundled, measures: .bundled)
    }()

    /// Injectable so a test can assemble the same thing from fixture data.
    public static func make(
        synonyms: SynonymTable, bls: BLSCatalog, measures: MeasureTable
    ) -> NutritionCatalog {
        var entries: [CatalogNutrition] = []
        entries.reserveCapacity(synonyms.entries.count)
        for word in synonyms.entries {
            var bases: [String: NutritionBasis] = [:]
            for state in IngredientState.displayOrder {
                guard let target = word.target(for: state),
                      let row = bls.entry(for: target.code)
                else { continue }
                bases[state.rawValue] = NutritionBasis(
                    values: row.perHundredGrams, code: row.code, catalogName: row.name
                )
            }
            let unitWeights = measures.grams(forIngredient: word.word)
            guard !bases.isEmpty || !unitWeights.isEmpty else { continue }
            entries.append(CatalogNutrition(
                name: word.word,
                bases: bases,
                unitWeightsGrams: unitWeights,
                // Curated in measures.json, deliberately not read yet — see
                // `MeasureTable`. Phase 5 puts it here.
                densityGramsPerMl: nil,
                source: bls.source.datasetVersion.isEmpty
                    ? CatalogNutrition.blsSource : bls.source.datasetVersion,
                candidateCodes: word.candidateCodes
            ))
        }
        return NutritionCatalog(entries: entries)
    }

    /// Looked up only by a name already resolved to its canonical form via
    /// `IngredientCatalog.canonicalName(for:)` — this catalog does no alias
    /// or plural matching of its own, so there is exactly one place that
    /// decides what a written ingredient means.
    public func nutrition(forCanonicalName name: String) -> CatalogNutrition? {
        byName[IngredientCatalog.normalize(name)]
    }

    public var entries: [CatalogNutrition] { Array(byName.values) }

    /// This catalog with the cook's own numbers laid over it — theirs win,
    /// since `init` keeps the first entry for a name and they go in front.
    public func merging(_ overrides: [CatalogNutrition]) -> NutritionCatalog {
        NutritionCatalog(entries: overrides + entries)
    }
}
