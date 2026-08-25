import Foundation

/// Nutrition values for the ingredients `IngredientCatalog` knows by name.
///
/// Kept as a separate table rather than a field on `CatalogIngredient`: the
/// two are curated independently (one from hand-picked spellings, the other
/// from a bulk BLS import) and a missing nutrition entry should not stand in
/// the way of an ingredient being recognized at all.
public struct NutritionCatalog: Sendable {
    private var byName: [String: CatalogNutrition]

    public init(entries: [CatalogNutrition]) {
        byName = Dictionary(entries.map { (IngredientCatalog.normalize($0.name), $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The catalog shipped with the app.
    public static let bundled: NutritionCatalog = {
        guard let url = Bundle.module.url(forResource: "nutrition", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([CatalogNutrition].self, from: data)
        else {
            assertionFailure("The bundled nutrition catalog is missing or unreadable")
            return NutritionCatalog(entries: [])
        }
        return NutritionCatalog(entries: entries)
    }()

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
