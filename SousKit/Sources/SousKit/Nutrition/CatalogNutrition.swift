import Foundation

/// One set of per-100g values, and where they came from.
///
/// The provenance is not decoration: the concept asks that no number appear
/// without saying what it is based on, and "based on" for a BLS number means
/// a specific row of a specific release — "Kartoffel geschält, gekocht", not
/// "Kartoffel". Carried per state, because a food's raw and cooked values are
/// two different rows and each has to answer for itself.
public struct NutritionBasis: Codable, Hashable, Sendable {
    /// Whether a basis is numbers or the settled answer that there are none.
    ///
    /// There is no axis of doubt any more (INGREDIENTS-DATA §3 A): the
    /// catalog answers, and the app does not ask. An inherited basis is simply
    /// the basis; where inheritance is wrong, the curator gives the variety a
    /// basis of its own. What used to be "proposed" and "orphaned" is gone with
    /// the questions they asked.
    public enum Status: String, Codable, Hashable, Sendable, CaseIterable {
        /// The values count.
        case computed
        /// The catalog says this ingredient stays without nutrition (CATALOG
        /// D). An answer, not a gap to fix.
        case deliberatelyWithout

        /// Whether a sum may be computed from this basis at all.
        public var contributes: Bool { self == .computed }
    }

    public var values: NutritionInfo
    /// The SBLS code these values are read from, `nil` for a cook's own
    /// numbers, which are a basis of equal standing with no code to name.
    public var code: String?
    /// The BLS catalog name at the time these values were shipped — what
    /// "beruht auf: …" prints.
    public var catalogName: String?
    public var status: Status
    /// How strongly the synonym table meant this row for this word.
    public var weight: Double
    /// Where these numbers came from: "BLS 4.0" for everything bundled,
    /// "Eigene Angabe" for what a cook typed in. Per basis rather than per
    /// entry, because an ingredient can perfectly well have the cook's own
    /// numbers for one state and the shipped ones for another.
    public var source: String
    /// The ingredient this basis was taken over from, where it was: a
    /// variety without numbers of its own computes with its parent's, and
    /// this names the parent so that every place that explains a figure can
    /// say "geerbt von Tomate" instead of presenting the parent's row as the
    /// variety's own. `nil` for a basis that is the ingredient's own.
    public var inheritedFrom: String?
    /// The generic word a product without label values counts like — "wie
    /// Margarine". An estimate, and said to be one wherever the figure is
    /// explained, until the label's values replace it.
    public var estimatedLike: String?

    public init(
        values: NutritionInfo,
        code: String? = nil,
        catalogName: String? = nil,
        status: Status = .computed,
        weight: Double = 0,
        source: String = CatalogNutrition.blsSource,
        inheritedFrom: String? = nil,
        estimatedLike: String? = nil
    ) {
        self.values = values
        self.code = code
        self.catalogName = catalogName
        self.status = status
        self.weight = weight
        self.source = source
        self.inheritedFrom = inheritedFrom
        self.estimatedLike = estimatedLike
    }

    /// This basis as a variety receives it from `parent`: the same basis,
    /// saying whose it was, so every place that explains a figure can say
    /// "geerbt von Tomate".
    func inherited(from parent: String) -> NutritionBasis {
        var basis = self
        basis.inheritedFrom = parent
        return basis
    }

    /// A basis kept as a *decision* rather than as numbers: the ingredient
    /// has none, on purpose.
    public static let deliberatelyWithout = NutritionBasis(
        values: .zero, status: .deliberatelyWithout, source: CatalogNutrition.ownSource
    )

    /// Decoded leniently: bases travel inside `CatalogNutrition`, which older
    /// callers may have encoded before there was a status to record, or with
    /// one of the retired statuses — every one of which carried numbers.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decodeIfPresent(String.self, forKey: .status)
        self.init(
            values: try container.decode(NutritionInfo.self, forKey: .values),
            code: try container.decodeIfPresent(String.self, forKey: .code),
            catalogName: try container.decodeIfPresent(String.self, forKey: .catalogName),
            status: status.flatMap(Status.init(rawValue:)) ?? .computed,
            weight: try container.decodeIfPresent(Double.self, forKey: .weight) ?? 0,
            source: try container.decodeIfPresent(String.self, forKey: .source)
                ?? CatalogNutrition.blsSource,
            inheritedFrom: try container.decodeIfPresent(String.self, forKey: .inheritedFrom),
            estimatedLike: try container.decodeIfPresent(String.self, forKey: .estimatedLike)
        )
    }

    /// How the app says what a figure rests on: "Kartoffel geschält, gekocht
    /// (BLS 4.0)". `nil` where there is nothing to name — the cook's own
    /// values say "Eigene Angabe" through `source` instead.
    public var provenance: String? {
        catalogName.map { "\($0) (\(source))" }
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
    /// The state a unit's weight is measured in, where the unit implies one
    /// — a can is weighed drained, which is cooked. Keyed like
    /// `unitWeightsGrams`; a line that names no state of its own is counted
    /// in this one.
    public var unitStates: [String: IngredientState]
    /// Needed to turn a volume amount into grams — a teaspoon of oil and a
    /// teaspoon of honey do not weigh the same. Curated in `measures.json`
    /// — the named row where there is one, the food group's otherwise. A
    /// weight authored for the very unit on the line still beats it: see
    /// `NutritionResolver.resolve`.
    public var densityGramsPerMl: Double?
    /// Where these numbers came from, for the entry as a whole. Kept beside
    /// the per-basis `source` for the catalog screen, which shows one line
    /// for one ingredient.
    public var source: String
    /// Every BLS row this ingredient could be based on, best first — what the
    /// candidate picker lists. Carried on gaps as well as on contributions:
    /// the line *without* a basis is the one the picker exists for.
    public var candidateCodes: [String]
    /// The ingredient this one is a variety of — "Cocktailtomate" of
    /// "Tomate". Any depth, and only ever a name: a variety inherits the
    /// basis and unit knowledge of the nearest ancestor that has any, as long
    /// as it has none of its own, which `NutritionCatalog` resolves at lookup
    /// time.
    public var parentName: String?
    /// Set on an entry that was resolved *through* its ancestry: the name of
    /// the ancestor whose bases these are. `nil` on an entry standing on its
    /// own numbers. What the form reads to label a figure as inherited.
    public var inheritedFrom: String?
    /// For a product without label values: the generic word it counts like
    /// (`like` in the data), resolved at lookup time like a parent, so a
    /// local answer about that word reaches the product too. Never used once
    /// the product has values of its own.
    public var likeName: String?

    public init(
        name: String,
        bases: [String: NutritionBasis],
        unitWeightsGrams: [String: Double] = [:],
        unitStates: [String: IngredientState] = [:],
        densityGramsPerMl: Double? = nil,
        source: String = CatalogNutrition.blsSource,
        candidateCodes: [String] = [],
        parentName: String? = nil
    ) {
        self.name = name
        self.bases = bases
        self.unitWeightsGrams = unitWeightsGrams
        self.unitStates = unitStates
        self.densityGramsPerMl = densityGramsPerMl
        self.source = source
        self.candidateCodes = candidateCodes
        self.parentName = parentName
    }

    /// For values that have no BLS row behind them — a cook's own numbers, or
    /// a test's. Same entry, just with nothing to name as its origin.
    public init(
        name: String,
        perHundredGrams: [String: NutritionInfo],
        unitWeightsGrams: [String: Double] = [:],
        densityGramsPerMl: Double? = nil,
        source: String = CatalogNutrition.blsSource,
        candidateCodes: [String] = [],
        parentName: String? = nil
    ) {
        self.init(
            name: name,
            bases: perHundredGrams.mapValues { NutritionBasis(values: $0, source: source) },
            unitWeightsGrams: unitWeightsGrams,
            densityGramsPerMl: densityGramsPerMl,
            source: source,
            candidateCodes: candidateCodes,
            parentName: parentName
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            bases: try container.decode([String: NutritionBasis].self, forKey: .bases),
            unitWeightsGrams: try container.decodeIfPresent(
                [String: Double].self, forKey: .unitWeightsGrams
            ) ?? [:],
            unitStates: try container.decodeIfPresent(
                [String: IngredientState].self, forKey: .unitStates
            ) ?? [:],
            densityGramsPerMl: try container.decodeIfPresent(Double.self, forKey: .densityGramsPerMl),
            source: try container.decodeIfPresent(String.self, forKey: .source) ?? Self.blsSource,
            candidateCodes: try container.decodeIfPresent(
                [String].self, forKey: .candidateCodes
            ) ?? [],
            parentName: try container.decodeIfPresent(String.self, forKey: .parentName)
        )
        likeName = try container.decodeIfPresent(String.self, forKey: .likeName)
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
    ///
    /// **A state the line asked for and the entry does not have falls back
    /// too**, and that stays so on purpose. "300 g Zucchini, gegart" with
    /// only a raw row is better counted as raw zucchini than as a gap: the
    /// error is a few percent of water, the alternative drops the line out of
    /// the sum entirely, and the concept's own answer to an imperfect number
    /// is to show it and say what it rests on rather than to hide it. What
    /// says so is ``hasOwnBasis(for:)``, which the drill-down reads to print
    /// the row's real state next to the line's.
    public func basis(for state: IngredientState) -> NutritionBasis? {
        if let exact = bases[state.rawValue] { return exact }
        for fallback in IngredientState.displayOrder {
            if let match = bases[fallback.rawValue] { return match }
        }
        return nil
    }

    /// Whether ``basis(for:)`` answers `state` from a row filed under exactly
    /// that state, rather than from the fallback.
    public func hasOwnBasis(for state: IngredientState) -> Bool {
        bases[state.rawValue] != nil
    }

    /// The values for `state`, or `nil` where the basis is a decision rather
    /// than numbers — "bewusst ohne" has a basis and no values.
    public func nutrition(for state: IngredientState) -> NutritionInfo? {
        guard let basis = basis(for: state), basis.status.contributes else { return nil }
        return basis.values
    }

    /// Whether this entry says anything about nutrition at all — a word that
    /// exists only to carry candidates or a piece weight does not.
    public var hasBases: Bool { !bases.isEmpty }

    /// How the app says what a figure rests on: "beruht auf: Kartoffel
    /// geschält, gekocht (BLS 4.0)". `nil` where there is nothing to name —
    /// the cook's own values say "Quelle: Eigene Angabe" instead.
    public func provenance(for state: IngredientState) -> String? {
        basis(for: state)?.provenance
    }

    /// This entry filled in from its parent — the variant relation's whole
    /// point: mapping "Tomate" once maps "Cocktailtomate" with it, until the
    /// variant says something of its own.
    public func inheriting(from parent: CatalogNutrition) -> CatalogNutrition {
        var merged = self
        // Every basis says whose it was — see `NutritionBasis.inherited`.
        merged.bases = parent.bases.mapValues { $0.inherited(from: parent.name) }
        merged.inheritedFrom = parent.name
        merged.unitWeightsGrams = parent.unitWeightsGrams.merging(unitWeightsGrams) { _, mine in mine }
        merged.unitStates = parent.unitStates.merging(unitStates) { _, mine in mine }
        merged.densityGramsPerMl = densityGramsPerMl ?? parent.densityGramsPerMl
        merged.source = parent.source
        if merged.candidateCodes.isEmpty { merged.candidateCodes = parent.candidateCodes }
        return merged
    }

    /// This product counted like `generic`: its values, weights and density,
    /// every basis marked as an estimate (INGREDIENTS-DATA-PLAN phase 7, "a
    /// product needs no values"). The same as a household's brand choice
    /// lends its target, said out loud here because it is the catalog's.
    public func estimating(like generic: CatalogNutrition) -> CatalogNutrition {
        var merged = inheriting(from: generic)
        merged.bases = generic.bases.mapValues {
            var basis = $0
            basis.estimatedLike = generic.name
            return basis
        }
        merged.inheritedFrom = nil
        return merged
    }
}
