import Foundation

/// The gram bridge: what a spoon, a clove, a bunch or a piece of something
/// weighs, and what a milliliter of it weighs.
///
/// BLS computes per 100 g and ships neither piece weights nor densities, so
/// every one of these numbers is hand-made. They are assumptions and say so —
/// `assumption` is carried per entry rather than assumed table-wide, because
/// the UI that shows "2 EL ≈ 28 g (Annahme)" needs it per number.
///
/// **Which table answers which unit** (phase 5's decision, and the reason the
/// file lost four rows when it landed): a unit that converts to milliliters —
/// `ml`, `l`, `TL` at 5 ml, `EL` at 15 ml — goes through a **density**, since
/// that is the one mechanism that also covers `ml` and `l` and needs no entry
/// per (unit, food) pair. Everything that converts to nothing — `Prise`,
/// `Tasse`, `Bund`, `Zehe`, `Blatt`, `Pck.`, `Stk.` — goes through a weight,
/// most specific first: the cook's own correction, then `byIngredient`, then
/// `byGroup`, then the generic `units`. `byGroup` therefore held two kinds of
/// row and one of them was unreachable by construction; the spoon rows became
/// group densities instead.
///
/// A weight authored for a *volume* unit still wins over the density — that
/// is how "an Esslöffel is not filled to the brim" gets said for one
/// ingredient without claiming anything about a litre of it.
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
    private var weightsByGroup: [String: [String: Double]]
    private var weightsByIngredient: [String: [String: Double]]
    private var densityByIngredient: [String: Double]
    private var densityByGroup: [String: Double]

    public init(
        units: [UnitWeight] = [], byGroup: [GroupWeight] = [],
        byIngredient: [IngredientWeight] = [], densities: [Density] = []
    ) {
        self.units = units
        self.byGroup = byGroup
        self.byIngredient = byIngredient
        self.densities = densities
        genericByUnit = Dictionary(units.map { ($0.unit, $0.grams) }, uniquingKeysWith: { first, _ in first })
        weightsByGroup = byGroup.reduce(into: [:]) { result, entry in
            result[entry.group, default: [:]][entry.unit] = entry.grams
        }
        weightsByIngredient = byIngredient.reduce(into: [:]) { result, entry in
            result[IngredientCatalog.normalize(entry.name), default: [:]][entry.unit] = entry.grams
        }
        densityByIngredient = densities.reduce(into: [:]) { result, entry in
            guard let name = entry.name else { return }
            result[IngredientCatalog.normalize(name)] = entry.gramsPerMl
        }
        // The group rows used to fall out here, silently: the ingredient
        // index skipped every entry without a name, and the one group density
        // in the file — all edible oils at 0.92 — was that entry.
        densityByGroup = densities.reduce(into: [:]) { result, entry in
            guard entry.name == nil, let group = entry.group else { return }
            result[group] = entry.gramsPerMl
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

    /// The weights authored for any spelling of one ingredient, the first
    /// spelling that has any winning.
    ///
    /// A measure row is written down under whichever word its author had in
    /// mind, and that is not always the word the vocabulary settled on:
    /// "Vanillezucker" is a spelling of "Vanille" here, and its packet weight
    /// used to be unreachable for exactly that reason.
    public func grams(forAnyOf spellings: [String]) -> [String: Double] {
        for spelling in spellings {
            let weights = grams(forIngredient: spelling)
            if !weights.isEmpty { return weights }
        }
        return [:]
    }

    /// The density authored for any spelling of one ingredient — see
    /// ``grams(forAnyOf:)``.
    public func density(forAnyOf spellings: [String]) -> Double? {
        spellings.lazy.compactMap { density(forIngredient: $0) }.first
    }

    /// The weights authored for a whole BLS food group — "a cup of anything
    /// from the grain group is 120 g". Keyed by the group letter, which is
    /// also an SBLS code's first character.
    public func grams(forGroup group: String) -> [String: Double] {
        weightsByGroup[group] ?? [:]
    }

    /// What a milliliter of this ingredient weighs, where anyone has said.
    public func density(forIngredient name: String) -> Double? {
        densityByIngredient[IngredientCatalog.normalize(name)]
    }

    /// What a milliliter of anything in this BLS food group weighs — the
    /// coarse answer for every oil nobody named individually.
    public func density(forGroup group: String) -> Double? {
        densityByGroup[group]
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
