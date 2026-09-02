import Foundation

/// One set of per-100g values, where they came from, and how sure anyone is
/// that they belong to the ingredient they were found for.
///
/// The provenance is not decoration: the concept asks that no number appear
/// without saying what it is based on, and "based on" for a BLS number means
/// a specific row of a specific release — "Kartoffel geschält, gekocht", not
/// "Kartoffel". Carried per state, because a food's raw and cooked values are
/// two different rows and each has to answer for itself.
public struct NutritionBasis: Codable, Hashable, Sendable {
    /// How a basis got attached to an ingredient, and what the cook has said
    /// about it. The concept's status model, one enum for the whole app.
    ///
    /// The distinction that matters for every sum is `proposed` vs.
    /// `confirmed`: a proposed basis is the synonym table's guess at what a
    /// kitchen word means in catalog language, and the app computes with it
    /// (decision A) while saying so. A confirmed one is the cook's word.
    public enum Status: String, Codable, Hashable, Sendable, CaseIterable {
        /// The synonym table found a candidate and nobody has looked at it.
        case proposed
        /// The cook accepted the candidate, picked another, or typed values.
        ///
        /// Also what a word carries that *is* the catalog's own name for the
        /// row — "Kartoffel geschält, gekocht" written out in a recipe leaves
        /// no mapping decision to confirm, so asking about it would be asking
        /// the cook to agree that a word means itself.
        case confirmed
        /// The cook decided this ingredient stays without nutrition. A
        /// confirmed answer, not an open question — whoever settled that
        /// veganes Hackfleisch has no values must not be nagged again.
        case deliberatelyWithout
        /// The row this rests on is not in the shipped data — it never
        /// resolved, or a data update took it away. Needs the cook, and says
        /// so instead of quietly counting as nothing.
        case orphaned

        /// Whether a sum may be computed from this basis at all.
        public var contributes: Bool { self == .proposed || self == .confirmed }

        /// How the app names the status where it has to be spelled out.
        public var label: String {
            switch self {
            case .proposed: "vorgeschlagen"
            case .confirmed: "bestätigt"
            case .deliberatelyWithout: "bewusst ohne Nährwerte"
            case .orphaned: "Zuordnung verwaist"
            }
        }
    }

    public var values: NutritionInfo
    /// The SBLS code these values are read from, `nil` for a cook's own
    /// numbers, which are a basis of equal standing with no code to name.
    public var code: String?
    /// The BLS catalog name at the time these values were shipped — what
    /// "beruht auf: …" prints.
    public var catalogName: String?
    public var status: Status
    /// How strongly the synonym table meant this row for this word. Carried
    /// so the picker can order alternatives the way the data ranks them, and
    /// so the reason a basis counts as proposed is auditable rather than
    /// recomputed from a table nobody consults at run time.
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

    /// A basis built by hand — a cook's numbers, or a test's — is one whoever
    /// built it stands behind, so it is confirmed unless said otherwise.
    public init(
        values: NutritionInfo,
        code: String? = nil,
        catalogName: String? = nil,
        status: Status = .confirmed,
        weight: Double = 0,
        source: String = CatalogNutrition.blsSource,
        inheritedFrom: String? = nil
    ) {
        self.values = values
        self.code = code
        self.catalogName = catalogName
        self.status = status
        self.weight = weight
        self.source = source
        self.inheritedFrom = inheritedFrom
    }

    /// This basis as a variety receives it from `parent`.
    ///
    /// **Inheritance is a proposal, never a confirmation** — catalog target,
    /// decision B. The parent's row may have been confirmed by the cook, but
    /// that was a decision about the parent; whether Räucherlachs is Lachs is
    /// a different question, and one that turned out to be wrong by a factor
    /// of 37 while nothing on screen said the number had been inherited at
    /// all. So a confirmed basis arrives as *proposed*: still computed with,
    /// marked, counted as unconfirmed, and asked about once.
    ///
    /// Two statuses pass through unchanged, because they are not numbers to
    /// doubt but answers to keep: a parent that deliberately has no values
    /// (Minze, and so Pfefferminze) and a parent whose row is orphaned.
    func inherited(from parent: String) -> NutritionBasis {
        var basis = self
        basis.inheritedFrom = parent
        if basis.status == .confirmed { basis.status = .proposed }
        return basis
    }

    /// A basis kept as a *decision* rather than as numbers: the cook said
    /// this ingredient has none, on purpose.
    public static let deliberatelyWithout = NutritionBasis(
        values: .zero, status: .deliberatelyWithout, source: CatalogNutrition.ownSource
    )

    /// Decoded leniently: bases travel inside `CatalogNutrition`, which older
    /// callers may have encoded before there was a status to record.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            values: try container.decode(NutritionInfo.self, forKey: .values),
            code: try container.decodeIfPresent(String.self, forKey: .code),
            catalogName: try container.decodeIfPresent(String.self, forKey: .catalogName),
            status: try container.decodeIfPresent(Status.self, forKey: .status) ?? .confirmed,
            weight: try container.decodeIfPresent(Double.self, forKey: .weight) ?? 0,
            source: try container.decodeIfPresent(String.self, forKey: .source)
                ?? CatalogNutrition.blsSource,
            inheritedFrom: try container.decodeIfPresent(String.self, forKey: .inheritedFrom)
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

    public init(
        name: String,
        bases: [String: NutritionBasis],
        unitWeightsGrams: [String: Double] = [:],
        densityGramsPerMl: Double? = nil,
        source: String = CatalogNutrition.blsSource,
        candidateCodes: [String] = [],
        parentName: String? = nil
    ) {
        self.name = name
        self.bases = bases
        self.unitWeightsGrams = unitWeightsGrams
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
            densityGramsPerMl: try container.decodeIfPresent(Double.self, forKey: .densityGramsPerMl),
            source: try container.decodeIfPresent(String.self, forKey: .source) ?? Self.blsSource,
            candidateCodes: try container.decodeIfPresent(
                [String].self, forKey: .candidateCodes
            ) ?? [],
            parentName: try container.decodeIfPresent(String.self, forKey: .parentName)
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

    /// This entry with `other` laid over it, state by state.
    ///
    /// A cook's entry is rarely a whole replacement: it may say what the
    /// ingredient is worth cooked and nothing about raw, or nothing at all
    /// about nutrition and only that it is a variety of something. Replacing
    /// wholesale is how own entries used to lose the candidate list they were
    /// never given in the first place.
    public func overlaid(by other: CatalogNutrition) -> CatalogNutrition {
        var merged = self
        merged.name = other.name
        merged.bases.merge(other.bases) { _, theirs in theirs }
        merged.unitWeightsGrams.merge(other.unitWeightsGrams) { _, theirs in theirs }
        merged.densityGramsPerMl = other.densityGramsPerMl ?? densityGramsPerMl
        if !other.bases.isEmpty { merged.source = other.source }
        if !other.candidateCodes.isEmpty { merged.candidateCodes = other.candidateCodes }
        merged.parentName = other.parentName ?? parentName
        return merged
    }

    /// This entry filled in from its parent — the variant relation's whole
    /// point: mapping "Tomate" once maps "Cocktailtomate" with it, including
    /// the confirmation, until the variant says something of its own.
    public func inheriting(from parent: CatalogNutrition) -> CatalogNutrition {
        var merged = self
        // Every basis says whose it was and, unless it is a settled non-answer,
        // drops from confirmed to proposed — see `NutritionBasis.inherited`.
        merged.bases = parent.bases.mapValues { $0.inherited(from: parent.name) }
        merged.inheritedFrom = parent.name
        merged.unitWeightsGrams = parent.unitWeightsGrams.merging(unitWeightsGrams) { _, mine in mine }
        merged.densityGramsPerMl = densityGramsPerMl ?? parent.densityGramsPerMl
        merged.source = parent.source
        if merged.candidateCodes.isEmpty { merged.candidateCodes = parent.candidateCodes }
        return merged
    }
}
