import Foundation

/// What the cook has decided about one ingredient of their vocabulary.
///
/// The concept's middle layer, made persistent: an ingredient is neither the
/// line a recipe wrote nor the row a food catalog holds, but the cook's own
/// word for a thing — "Tomate", "Ajvar", "veganes Hackfleisch". Everything
/// that should hold *across* recipes hangs here: the spellings it answers to,
/// the basis its numbers rest on, whether it is a variety of something else,
/// what a piece of it weighs, and whether it lives in the pantry.
///
/// Rows exist only where the cook has state. A bundled ingredient nobody has
/// touched has no entry — the shipped data already says everything about it,
/// and mirroring 2,675 words into the store would make every app update a
/// merge problem for no gain.
public struct IngredientVocabularyEntry: Identifiable, Hashable, Sendable {
    /// Identity is the UUID, not the name: a rename must not orphan
    /// everything that points here, and the variant relation joins by it.
    public var id: UUID
    public var name: String
    /// Other spellings of *this* word. Varieties are separate entries.
    public var aliases: [String]
    /// Set only where the cook chose one — otherwise whatever the shipped
    /// entry or the parent says stands.
    public var category: IngredientCategory?
    /// The ingredient this is a variety of, by name.
    public var parentName: String?
    /// Whether this entry *is* the ingredient rather than notes about a
    /// shipped one. An entry that only carries a pantry flag or one extra
    /// spelling must not shadow the bundled word's name and category.
    public var isOwnIngredient: Bool
    /// Salt, oil, flour: checked against the shelf, not hunted through the
    /// store. Absorbed from the old, separate pantry-flag table.
    public var isPantry: Bool
    /// What one unit of a counted or imprecise measure weighs for this
    /// ingredient — "1 Zwiebel ≈ 90 g", keyed by `IngredientUnit.symbol`.
    public var unitWeightsGrams: [String: Double]
    /// The basis per preparation state, keyed by `IngredientState.rawValue`.
    public var bases: [String: BasisAssignment]
    /// The re-key from phase 3 could not find any row for this name. Kept as
    /// the question it is: the entry works, and the review flow has a list of
    /// what to ask about.
    public var needsBasisReview: Bool
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        aliases: [String] = [],
        category: IngredientCategory? = nil,
        parentName: String? = nil,
        isOwnIngredient: Bool = false,
        isPantry: Bool = false,
        unitWeightsGrams: [String: Double] = [:],
        bases: [String: BasisAssignment] = [:],
        needsBasisReview: Bool = false,
        updatedAt: Date = .nowInSyncPrecision
    ) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.category = category
        self.parentName = parentName
        self.isOwnIngredient = isOwnIngredient
        self.isPantry = isPantry
        self.unitWeightsGrams = unitWeightsGrams
        self.bases = bases
        self.needsBasisReview = needsBasisReview
        self.updatedAt = updatedAt
    }

    /// The join key from recipe text: the normalized name, exactly as
    /// everything else in the app normalizes.
    public var key: String { IngredientCatalog.normalize(name) }

    /// Whether this entry still says anything. One that does not is swept:
    /// the vocabulary is meant to hold decisions, not the residue of having
    /// opened a form once.
    public var isEmpty: Bool {
        !isOwnIngredient && !isPantry && aliases.isEmpty && bases.isEmpty
            && unitWeightsGrams.isEmpty && parentName == nil && category == nil
            && !needsBasisReview
    }

    /// The identity half, for `IngredientCatalog`.
    public func catalogIngredient(fallback: CatalogIngredient?) -> CatalogIngredient {
        CatalogIngredient(
            name: isOwnIngredient ? name : (fallback?.name ?? name),
            aliases: (fallback?.aliases ?? []) + aliases,
            category: category ?? fallback?.category ?? .other,
            parentName: parentName ?? fallback?.parentName
        )
    }

    /// The nutrition half, as an override laid over the shipped catalog —
    /// `nil` where this entry says nothing a sum would notice.
    ///
    /// The BLS table is needed because an assignment stores a *code*, never
    /// the numbers: the concept's most important invariant is that user data
    /// references the shipped world by key, so that a release can be swapped
    /// in wholesale and the values follow silently (decision D).
    public func nutritionOverride(
        bls: BLSCatalog, source: String, measures: MeasureTable = .bundled
    ) -> CatalogNutrition? {
        var resolved: [String: NutritionBasis] = [:]
        var group: String?
        for (state, assignment) in bases {
            let basis = assignment.basis(bls: bls, source: source)
            resolved[state] = basis
            group = group ?? basis.code.flatMap { bls.entry(for: $0)?.group }
        }
        guard !resolved.isEmpty || !unitWeightsGrams.isEmpty || parentName != nil else {
            return nil
        }
        // An own ingredient has no density of its own to give — there is no
        // field for one, and asking a cook for grams per milliliter would be
        // asking the wrong question. What it does have is the row the cook
        // mapped it onto, and that row's food group answers it: whatever
        // "Grandmas Öl" was pinned to in group Q pours like the oils do.
        // `overlaid(by:)` keeps the shipped density where this finds none, so
        // an entry that says nothing about measures still says nothing.
        let density = group.flatMap(measures.density(forGroup:))
        return CatalogNutrition(
            name: name,
            bases: resolved,
            unitWeightsGrams: unitWeightsGrams,
            densityGramsPerMl: density,
            source: resolved.values.first?.source ?? source,
            candidateCodes: [],
            parentName: parentName
        )
    }
}

/// One decision about what an ingredient's numbers rest on, in one state.
///
/// Either a reference into the shipped catalog (a code), or the cook's own
/// values, or the decision to have neither. Never the shipped numbers
/// themselves: copying them here would freeze them, and a data update would
/// stop reaching the cook who confirmed the mapping first.
public struct BasisAssignment: Codable, Hashable, Sendable {
    public var status: NutritionBasis.Status
    /// The SBLS code this rests on. Kept even beside own values, where it
    /// records which row the cook's numbers stand in for.
    public var code: String?
    /// What the row was called when the mapping was made — what an orphaned
    /// mapping can still name, once the row itself is gone.
    public var catalogName: String?
    /// The dataset the confirmation was made against, for phase 6's trace.
    public var datasetVersion: String?
    /// The cook's own numbers, per 100 g. Present exactly for an own-values
    /// basis; a code-backed one reads its numbers from the shipped table.
    public var values: NutritionInfo?
    public var source: String?
    public var decidedAt: Date?

    public init(
        status: NutritionBasis.Status,
        code: String? = nil,
        catalogName: String? = nil,
        datasetVersion: String? = nil,
        values: NutritionInfo? = nil,
        source: String? = nil,
        decidedAt: Date? = .nowInSyncPrecision
    ) {
        self.status = status
        self.code = code
        self.catalogName = catalogName
        self.datasetVersion = datasetVersion
        self.values = values
        self.source = source
        self.decidedAt = decidedAt
    }

    /// The cook's own numbers as a basis — confirmed by the act of typing.
    public static func ownValues(
        _ values: NutritionInfo, code: String? = nil, source: String = CatalogNutrition.ownSource
    ) -> BasisAssignment {
        BasisAssignment(status: .confirmed, code: code, values: values, source: source)
    }

    /// A BLS row the cook picked.
    public static func confirmed(code: String, catalogName: String?, datasetVersion: String?) -> BasisAssignment {
        BasisAssignment(
            status: .confirmed, code: code, catalogName: catalogName,
            datasetVersion: datasetVersion
        )
    }

    /// The confirmed opt-out: no numbers, on purpose, and no more asking.
    public static let deliberatelyWithout = BasisAssignment(status: .deliberatelyWithout)

    /// This assignment as a basis a sum can use.
    ///
    /// A code whose row is not in the shipped data comes back *orphaned*
    /// rather than missing: the difference between "nobody ever said" and
    /// "what was said points nowhere" is the difference between a question
    /// and a broken answer, and only the second needs repairing.
    public func basis(bls: BLSCatalog, source datasetSource: String) -> NutritionBasis {
        if status == .deliberatelyWithout { return .deliberatelyWithout }
        if let values {
            return NutritionBasis(
                values: values, code: code, catalogName: catalogName,
                status: status == .orphaned ? .confirmed : status,
                source: source ?? CatalogNutrition.ownSource
            )
        }
        guard let code, let row = bls.entry(for: code) else {
            return NutritionBasis(
                values: .zero, code: code, catalogName: catalogName,
                status: .orphaned, source: source ?? datasetSource
            )
        }
        return NutritionBasis(
            values: row.perHundredGrams, code: row.code, catalogName: row.name,
            status: status == .orphaned ? .confirmed : status,
            weight: 1, source: datasetSource
        )
    }
}
