import Foundation

/// What a recipe's nutrition sum is actually based on — the concept's rule
/// that a figure never appears naked: "≈ 640 kcal pro Portion — 9 von 12
/// Zutaten", with every left-out line named and its reason given.
///
/// Unquantified lines ("Salz nach Geschmack") are listed but deliberately do
/// not count against completeness: the line is fully understood, it just
/// carries no accountable amount — there is nothing to fix. The same holds
/// for a line the catalog settled as without values.
public struct NutritionCoverage: Codable, Hashable, Sendable {
    /// Why one line contributed nothing. The reasons stay distinguishable
    /// because their remedies differ: an unknown name wants a catalog entry,
    /// a known name without values wants numbers, a countable unit wants a
    /// weight.
    public enum GapReason: String, Codable, Hashable, Sendable, CaseIterable {
        /// The written name resolves to nothing — no catalog entry, no own
        /// nutrition values under that name.
        case noCatalogMatch
        /// The catalog knows the ingredient, but nobody has values for it —
        /// the case the catalog banner above it never sees.
        case noNutritionValues
        /// Values exist, but the amount cannot be turned into grams: a
        /// counted or imprecise unit with no weight on record.
        case noGramEquivalent
        /// The line links a recipe that cannot be followed — deleted, deeper
        /// than links are chased, or part of a cycle.
        case unresolvedLink
        /// No number at all — "nach Geschmack", "etwas", or simply none
        /// written. Recognized, not included, and not a defect.
        case unquantified
        /// The catalog says this ingredient carries no nutrition. An answer,
        /// not an open question.
        case deliberatelyWithout

        /// Whether this reason marks the sum as incomplete. Everything does
        /// except the two that are already settled: an unquantified line has
        /// nothing to fix, and a deliberate opt-out is already the answer.
        public var countsAsDefect: Bool {
            self != .unquantified && self != .deliberatelyWithout
        }

        /// How the drill-down names the reason.
        public var label: String {
            switch self {
            case .noCatalogMatch: "nicht im Katalog"
            case .noNutritionValues: "keine Nährwerte hinterlegt"
            case .noGramEquivalent: "kein Grammäquivalent"
            case .unresolvedLink: "Rezept nicht auflösbar"
            case .unquantified: "unbeziffert, nicht einberechnet"
            case .deliberatelyWithout: "bewusst ohne Nährwerte"
            }
        }
    }

    /// One line that contributed nothing, with the recipe it came from when
    /// it was carried up out of a linked sub-recipe ("aus Naan: Hefe").
    public struct Gap: Codable, Hashable, Sendable {
        public var ingredientName: String
        public var reason: GapReason
        /// The linked recipe this gap was inherited from, `nil` for the
        /// recipe's own lines — coverage propagates so sub-recipes cannot
        /// become honesty holes.
        public var sourceRecipeTitle: String?
        /// Every BLS row this line could be based on, best first.
        public var candidateCodes: [String]
        /// The state the line asked for.
        public var state: IngredientState

        public init(
            ingredientName: String, reason: GapReason, sourceRecipeTitle: String? = nil,
            candidateCodes: [String] = [], state: IngredientState = .unspecified
        ) {
            self.ingredientName = ingredientName
            self.reason = reason
            self.sourceRecipeTitle = sourceRecipeTitle
            self.candidateCodes = candidateCodes
            self.state = state
        }

        /// Decoded leniently — the whole coverage travels as JSON inside
        /// `StoredRecipeNutrition`, and a row cached before candidates were
        /// carried is still a valid row. Without this the decode fails
        /// silently and the figure looks like a cache miss forever.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                ingredientName: try container.decode(String.self, forKey: .ingredientName),
                reason: try container.decode(GapReason.self, forKey: .reason),
                sourceRecipeTitle: try container.decodeIfPresent(
                    String.self, forKey: .sourceRecipeTitle
                ),
                candidateCodes: try container.decodeIfPresent(
                    [String].self, forKey: .candidateCodes
                ) ?? [],
                state: try container.decodeIfPresent(
                    IngredientState.self, forKey: .state
                ) ?? .unspecified
            )
        }
    }

    /// One line that did contribute, and what its numbers rest on.
    ///
    /// The concept's rule that a figure never appears naked applies to the
    /// figures that *worked* too: "Tomate — beruht auf: Tomate roh (BLS 4.0)".
    /// Until now only the gaps had an explanation.
    public struct Contribution: Codable, Hashable, Sendable {
        public var ingredientName: String
        /// The linked recipe this line came from, `nil` for the recipe's own.
        public var sourceRecipeTitle: String?
        /// The BLS catalog name the numbers were read from — the source's
        /// word for the food, which is rarely the kitchen's.
        public var basisName: String?
        /// The SBLS code behind it, so a later phase can go back to the row
        /// itself rather than to a name that may have moved.
        public var basisCode: String?
        /// Every row this ingredient could have been based on, best first.
        public var candidateCodes: [String]
        /// The ancestor the basis was taken over from, where it was:
        /// "geerbt von Lachs".
        public var inheritedFrom: String?
        /// The generic word a product without label values was counted like:
        /// "Schätzung: wie Margarine".
        public var estimatedLike: String?
        /// The amount as the line wrote it — "2 EL". Kept beside the grams
        /// because the two together are the whole statement the gram bridge
        /// makes, and because correcting it means saying what one EL of this
        /// ingredient weighs.
        public var quantity: Quantity?
        /// What that amount was taken to be in grams.
        public var grams: Double?
        /// Whether those grams came out of the measure table rather than off
        /// the line. The "≈" and the "(Annahme)" hang on this.
        public var isAssumedGrams: Bool
        /// The state the line asked for.
        public var state: IngredientState
        /// Whether the basis is filed under exactly that state, or was
        /// answered by the fallback — see `CatalogNutrition.basis(for:)`.
        /// A line that says "gegart" and is counted with the raw row has to
        /// be able to say so.
        public var matchesState: Bool
        /// The energy the line added: what its share of each nutrient's
        /// coverage is weighed by.
        public var energy: Double
        /// The nutrients its basis does not state — a label's micronutrients,
        /// a BLS row's gap. Counted as nothing, and not as zero.
        public var absent: [Nutrient]

        public init(
            ingredientName: String, sourceRecipeTitle: String? = nil,
            basisName: String? = nil, basisCode: String? = nil,
            candidateCodes: [String] = [],
            inheritedFrom: String? = nil,
            quantity: Quantity? = nil, grams: Double? = nil, isAssumedGrams: Bool = false,
            state: IngredientState = .unspecified, matchesState: Bool = true,
            energy: Double = 0, absent: [Nutrient] = [], estimatedLike: String? = nil
        ) {
            self.ingredientName = ingredientName
            self.sourceRecipeTitle = sourceRecipeTitle
            self.basisName = basisName
            self.basisCode = basisCode
            self.candidateCodes = candidateCodes
            self.inheritedFrom = inheritedFrom
            self.quantity = quantity
            self.grams = grams
            self.isAssumedGrams = isAssumedGrams
            self.state = state
            self.matchesState = matchesState
            self.energy = energy
            self.absent = absent
            self.estimatedLike = estimatedLike
        }

        /// Decoded leniently, for the same reason `Gap` is.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                ingredientName: try container.decode(String.self, forKey: .ingredientName),
                sourceRecipeTitle: try container.decodeIfPresent(
                    String.self, forKey: .sourceRecipeTitle
                ),
                basisName: try container.decodeIfPresent(String.self, forKey: .basisName),
                basisCode: try container.decodeIfPresent(String.self, forKey: .basisCode),
                candidateCodes: try container.decodeIfPresent(
                    [String].self, forKey: .candidateCodes
                ) ?? [],
                inheritedFrom: try container.decodeIfPresent(String.self, forKey: .inheritedFrom),
                quantity: try container.decodeIfPresent(Quantity.self, forKey: .quantity),
                grams: try container.decodeIfPresent(Double.self, forKey: .grams),
                isAssumedGrams: try container.decodeIfPresent(
                    Bool.self, forKey: .isAssumedGrams
                ) ?? false,
                state: try container.decodeIfPresent(
                    IngredientState.self, forKey: .state
                ) ?? .unspecified,
                // Absent means "nothing ever said otherwise", which is what
                // every figure cached before states were read is claiming.
                matchesState: try container.decodeIfPresent(
                    Bool.self, forKey: .matchesState
                ) ?? true,
                energy: try container.decodeIfPresent(Double.self, forKey: .energy) ?? 0,
                absent: try container.decodeIfPresent([Nutrient].self, forKey: .absent) ?? [],
                estimatedLike: try container.decodeIfPresent(String.self, forKey: .estimatedLike)
            )
        }

        /// How the app says it: "Tomate roh (BLS 4.0)".
        public func provenance(source: String = CatalogNutrition.blsSource) -> String? {
            basisName.map { "\($0) (\(source))" }
        }
    }

    /// Lines whose nutrition made it into the sum.
    public var includedCount: Int
    /// Every line that did not contribute, unquantified ones included.
    public var gaps: [Gap]
    /// Every line that did, with what it rests on. Defaulted on decode: a
    /// figure cached before provenance existed is still a valid figure.
    public var contributions: [Contribution]

    public init(includedCount: Int, gaps: [Gap], contributions: [Contribution] = []) {
        self.includedCount = includedCount
        self.gaps = gaps
        self.contributions = contributions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            includedCount: try container.decode(Int.self, forKey: .includedCount),
            gaps: try container.decode([Gap].self, forKey: .gaps),
            contributions: try container.decodeIfPresent(
                [Contribution].self, forKey: .contributions
            ) ?? []
        )
    }

    /// The gaps that make the sum incomplete — everything but the two
    /// settled reasons.
    public var defects: [Gap] { gaps.filter { $0.reason.countsAsDefect } }

    /// The "12" in "9 von 12 Zutaten": every line that should have
    /// contributed. Unquantified lines stand outside on both sides.
    public var accountableCount: Int { includedCount + defects.count }

    /// Whether the sum covers everything it claims to: no defects, and at
    /// least one contributing line — a sum of nothing is not a complete sum.
    /// This gates the NRF badge (decision O1).
    public var isComplete: Bool {
        defects.isEmpty && includedCount > 0
    }

    // MARK: - Per nutrient

    /// How much of a nutrient's sum must rest on stated values before a
    /// claim may be made from it: the NRF badge for its twelve, the fibre
    /// tag for fibre.
    public static let minimumNutrientShare = 0.9

    /// The share of the counted energy whose lines state `nutrient`. A
    /// product that declares no vitamin C is a gap in the vitamin C sum, not
    /// a zero in it; weighed by energy, because the scores read the sum per
    /// 100 kcal, and a litre of stock without a vitamin row moves them by
    /// nothing. A sum without energy is covered where no line lacks it.
    public func share(of nutrient: Nutrient) -> Double {
        let energy = contributions.reduce(0) { $0 + max(0, $1.energy) }
        let lacking = contributions.filter { $0.absent.contains(nutrient) }
        guard energy > 0 else { return lacking.isEmpty ? 1 : 0 }
        return 1 - lacking.reduce(0) { $0 + max(0, $1.energy) } / energy
    }

    /// Whether the sum of `nutrient` may be claimed from.
    public func covers(_ nutrient: Nutrient) -> Bool {
        share(of: nutrient) >= Self.minimumNutrientShare
    }

    /// The lines that do not state `nutrient`, the heaviest first — what
    /// "nicht bestimmbar" names.
    public func lines(lacking nutrient: Nutrient) -> [Contribution] {
        contributions.filter { $0.absent.contains(nutrient) }.sorted { $0.energy > $1.energy }
    }

    /// The NRF score's nutrients that fall short of the share.
    public var nrfUncovered: [Nutrient] {
        NutrientReference.all.map(\.nutrient).filter { !covers($0) }
    }

    /// Whether the NRF badge may be shown: every line counted, and every
    /// one of its twelve nutrients stated for at least 90 % of the energy.
    /// A sum that lacks vitamin C for half its energy would otherwise score
    /// low for a reason the dish has nothing to do with.
    public var nrfIsDeterminable: Bool {
        isComplete && nrfUncovered.isEmpty
    }
}

/// One ingredient line's fate in the aggregation: what it added to the sum,
/// or why it added nothing.
public struct NutritionLineReport: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        /// Counted.
        case contributed(NutritionInfo)
        case gap(NutritionCoverage.GapReason)

        /// What the line added.
        public var contribution: NutritionInfo? {
            switch self {
            case .contributed(let info): info
            case .gap: nil
            }
        }
    }

    /// The written name, stripped of link syntax for display.
    public var ingredientName: String
    /// The linked recipe the line belongs to, `nil` for the recipe's own.
    public var sourceRecipeTitle: String?
    public var outcome: Outcome
    /// The BLS row the numbers came from, where there were numbers.
    public var basis: NutritionBasis?
    /// Every row this ingredient could have been based on, best first.
    public var candidateCodes: [String]
    /// The amount as written, and what it was taken to be in grams — the
    /// gram bridge's whole statement about this line.
    public var quantity: Quantity?
    public var resolvedAmount: NutritionResolver.ResolvedAmount?
    /// The state the line asked for, and whether the basis is really filed
    /// under it.
    public var state: IngredientState
    public var matchesState: Bool

    public init(
        ingredientName: String, sourceRecipeTitle: String? = nil, outcome: Outcome,
        basis: NutritionBasis? = nil, candidateCodes: [String] = [],
        quantity: Quantity? = nil, resolvedAmount: NutritionResolver.ResolvedAmount? = nil,
        state: IngredientState = .unspecified, matchesState: Bool = true
    ) {
        self.ingredientName = ingredientName
        self.sourceRecipeTitle = sourceRecipeTitle
        self.outcome = outcome
        self.basis = basis
        self.candidateCodes = candidateCodes
        self.quantity = quantity
        self.resolvedAmount = resolvedAmount
        self.state = state
        self.matchesState = matchesState
    }
}

/// What `NutritionAggregator` hands back: the sum, and the per-line account
/// of how it came together.
public struct NutritionReport: Hashable, Sendable {
    /// The total across every portion — the caller divides for per-portion.
    public var total: NutritionInfo
    /// Every line seen, linked sub-recipes' lines included.
    public var lines: [NutritionLineReport]

    public init(total: NutritionInfo, lines: [NutritionLineReport]) {
        self.total = total
        self.lines = lines
    }

    /// The lines condensed to what the UI and the cache carry around.
    public var coverage: NutritionCoverage {
        var included = 0
        var gaps: [NutritionCoverage.Gap] = []
        var contributions: [NutritionCoverage.Contribution] = []
        for line in lines {
            switch line.outcome {
            case .contributed:
                included += 1
                contributions.append(NutritionCoverage.Contribution(
                    ingredientName: line.ingredientName,
                    sourceRecipeTitle: line.sourceRecipeTitle,
                    basisName: line.basis?.catalogName,
                    basisCode: line.basis?.code,
                    candidateCodes: line.candidateCodes,
                    inheritedFrom: line.basis?.inheritedFrom,
                    quantity: line.quantity,
                    grams: line.resolvedAmount?.grams,
                    isAssumedGrams: line.resolvedAmount?.isAssumption ?? false,
                    state: line.state,
                    matchesState: line.matchesState,
                    energy: line.outcome.contribution.map { $0.states(.kcal) ? $0.kcal : 0 } ?? 0,
                    absent: line.outcome.contribution?.absent.sorted() ?? [],
                    estimatedLike: line.basis?.estimatedLike
                ))
            case .gap(let reason):
                gaps.append(NutritionCoverage.Gap(
                    ingredientName: line.ingredientName,
                    reason: reason,
                    sourceRecipeTitle: line.sourceRecipeTitle,
                    candidateCodes: line.candidateCodes,
                    state: line.state
                ))
            }
        }
        return NutritionCoverage(includedCount: included, gaps: gaps, contributions: contributions)
    }
}
