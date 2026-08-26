import Foundation

/// The gram bridge: what a spoon, a clove, a bunch or a piece of something
/// weighs, and what a milliliter of it weighs.
///
/// BLS computes per 100 g and ships neither piece weights nor densities, so
/// every one of these numbers is hand-made. They are assumptions and say so —
/// `assumption` is carried per entry rather than assumed table-wide, because
/// the UI that will show "2 EL ≈ 20 g (Annahme)" needs it per number.
///
/// **Phase 3 uses only what the app already used**: the generic per-unit
/// weights that used to be a Swift constant, and the per-ingredient piece
/// weights that used to sit in `nutrition.json`. Densities, the per-group
/// weights and "Tasse" ship here now but are not yet consulted — switching
/// them on changes what recipes add up to, and that is phase 5's job.
public struct MeasureTable: Sendable {
    public struct UnitWeight: Codable, Hashable, Sendable {
        public var unit: String
        public var grams: Double
        public var assumption: Bool
        public var note: String?
    }

    public struct GroupWeight: Codable, Hashable, Sendable {
        public var group: String
        public var unit: String
        public var grams: Double
        public var assumption: Bool
        public var note: String?
    }

    public struct IngredientWeight: Codable, Hashable, Sendable {
        public var name: String
        public var unit: String
        public var grams: Double
        public var assumption: Bool
        public var note: String?
    }

    public struct Density: Codable, Hashable, Sendable {
        public var name: String?
        public var group: String?
        public var gramsPerMl: Double
        public var assumption: Bool
        public var note: String?
    }

    private struct File: Codable {
        var units: [UnitWeight]
        var byGroup: [GroupWeight]
        var byIngredient: [IngredientWeight]
        var densities: [Density]
    }

    public private(set) var units: [UnitWeight]
    public private(set) var byGroup: [GroupWeight]
    public private(set) var byIngredient: [IngredientWeight]
    public private(set) var densities: [Density]

    private var genericByUnit: [String: Double]
    private var weightsByIngredient: [String: [String: Double]]
    private var densityByIngredient: [String: Double]

    public init(
        units: [UnitWeight] = [], byGroup: [GroupWeight] = [],
        byIngredient: [IngredientWeight] = [], densities: [Density] = []
    ) {
        self.units = units
        self.byGroup = byGroup
        self.byIngredient = byIngredient
        self.densities = densities
        genericByUnit = Dictionary(units.map { ($0.unit, $0.grams) }, uniquingKeysWith: { first, _ in first })
        weightsByIngredient = byIngredient.reduce(into: [:]) { result, entry in
            result[IngredientCatalog.normalize(entry.name), default: [:]][entry.unit] = entry.grams
        }
        densityByIngredient = densities.reduce(into: [:]) { result, entry in
            guard let name = entry.name else { return }
            result[IngredientCatalog.normalize(name)] = entry.gramsPerMl
        }
    }

    /// What one of `unit` weighs when nothing more specific is known — the
    /// table that used to be `NutritionResolver.genericImpreciseGrams`.
    /// `Stk.` is deliberately absent, as it was there: a piece weight that
    /// applies across every food is not defensible the way "1 Blatt ≈ 1 g" is.
    public func genericGrams(forUnit unit: String) -> Double? { genericByUnit[unit] }

    /// The weights authored for one ingredient, keyed by unit symbol.
    public func grams(forIngredient name: String) -> [String: Double] {
        weightsByIngredient[IngredientCatalog.normalize(name)] ?? [:]
    }

    /// Curated, and not yet consulted — see the note on the type. Phase 5
    /// hands this to `NutritionResolver` in place of water's density.
    public func density(forIngredient name: String) -> Double? {
        densityByIngredient[IngredientCatalog.normalize(name)]
    }

    /// The table shipped with the app.
    public static let bundled: MeasureTable = {
        guard let url = Bundle.module.url(forResource: "measures", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else {
            assertionFailure("The bundled measure table is missing or unreadable")
            return MeasureTable()
        }
        return MeasureTable(
            units: file.units, byGroup: file.byGroup,
            byIngredient: file.byIngredient, densities: file.densities
        )
    }()
}
