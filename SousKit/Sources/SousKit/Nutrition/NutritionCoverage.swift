import Foundation

/// What a recipe's nutrition sum is actually based on — the concept's rule
/// that a figure never appears naked: "≈ 640 kcal pro Portion — 9 von 12
/// Zutaten", with every left-out line named and its reason given.
///
/// Unquantified lines ("Salz nach Geschmack") are listed but deliberately do
/// not count against completeness: the line is fully understood, it just
/// carries no accountable amount — there is nothing to fix.
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
        /// the case the old "N Zutaten unbekannt" banner never saw.
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

        /// Whether this reason marks the sum as incomplete. Everything does
        /// except "unquantified", per the concept.
        public var countsAsDefect: Bool { self != .unquantified }

        /// How the drill-down names the reason.
        public var label: String {
            switch self {
            case .noCatalogMatch: "nicht im Katalog"
            case .noNutritionValues: "keine Nährwerte hinterlegt"
            case .noGramEquivalent: "kein Grammäquivalent"
            case .unresolvedLink: "Rezept nicht auflösbar"
            case .unquantified: "unbeziffert, nicht einberechnet"
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

        public init(ingredientName: String, reason: GapReason, sourceRecipeTitle: String? = nil) {
            self.ingredientName = ingredientName
            self.reason = reason
            self.sourceRecipeTitle = sourceRecipeTitle
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
        /// Carried through the result from phase 3 on and deliberately not
        /// shown yet — phase 4 builds the candidate picker on it.
        public var candidateCodes: [String]

        public init(
            ingredientName: String, sourceRecipeTitle: String? = nil,
            basisName: String? = nil, basisCode: String? = nil,
            candidateCodes: [String] = []
        ) {
            self.ingredientName = ingredientName
            self.sourceRecipeTitle = sourceRecipeTitle
            self.basisName = basisName
            self.basisCode = basisCode
            self.candidateCodes = candidateCodes
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

    /// The gaps that make the sum incomplete — everything but unquantified.
    public var defects: [Gap] { gaps.filter { $0.reason.countsAsDefect } }

    /// The "12" in "9 von 12 Zutaten": every line that should have
    /// contributed. Unquantified lines stand outside on both sides.
    public var accountableCount: Int { includedCount + defects.count }

    /// Whether the sum covers everything it claims to. Requires at least one
    /// contributing line: a sum of nothing is not a complete sum, and a badge
    /// computed from it would be exactly the misleading case the gate exists
    /// for.
    public var isComplete: Bool { defects.isEmpty && includedCount > 0 }
}

/// One ingredient line's fate in the aggregation: what it added to the sum,
/// or why it added nothing.
public struct NutritionLineReport: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        case contributed(NutritionInfo)
        case gap(NutritionCoverage.GapReason)
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

    public init(
        ingredientName: String, sourceRecipeTitle: String? = nil, outcome: Outcome,
        basis: NutritionBasis? = nil, candidateCodes: [String] = []
    ) {
        self.ingredientName = ingredientName
        self.sourceRecipeTitle = sourceRecipeTitle
        self.outcome = outcome
        self.basis = basis
        self.candidateCodes = candidateCodes
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
                    candidateCodes: line.candidateCodes
                ))
            case .gap(let reason):
                gaps.append(NutritionCoverage.Gap(
                    ingredientName: line.ingredientName,
                    reason: reason,
                    sourceRecipeTitle: line.sourceRecipeTitle
                ))
            }
        }
        return NutritionCoverage(includedCount: included, gaps: gaps, contributions: contributions)
    }
}
