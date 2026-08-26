import Foundation

/// What a recipe's nutrition sum is actually based on — the concept's rule
/// that a figure never appears naked: "≈ 640 kcal pro Portion — 9 von 12
/// Zutaten, davon 4 unbestätigt", with every left-out line named and its
/// reason given.
///
/// Unquantified lines ("Salz nach Geschmack") are listed but deliberately do
/// not count against completeness: the line is fully understood, it just
/// carries no accountable amount — there is nothing to fix. The same holds
/// for a line the cook decided stays without values.
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
        /// The cook decided this ingredient carries no nutrition. An answer,
        /// not an open question: it must not keep asking.
        case deliberatelyWithout
        /// A basis was chosen once and the row behind it is not in the
        /// shipped data — it never resolved, or an update took it away.
        case orphanedBasis

        /// Whether this reason marks the sum as incomplete. Everything does
        /// except the two that are already settled: an unquantified line has
        /// nothing to fix, and a deliberate opt-out has been fixed.
        public var countsAsDefect: Bool {
            self != .unquantified && self != .deliberatelyWithout
        }

        /// Whether picking a basis is what would close this gap — what makes
        /// a line worth listing in "N Zutaten zu klären".
        public var wantsBasis: Bool {
            self == .noCatalogMatch || self == .noNutritionValues || self == .orphanedBasis
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
            case .orphanedBasis: "Zuordnung verwaist"
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
        ///
        /// Carried on gaps, not only on contributions: the line *without* a
        /// basis is precisely the one the picker exists for, and until now it
        /// was the only one that arrived without anything to offer.
        public var candidateCodes: [String]

        public init(
            ingredientName: String, reason: GapReason, sourceRecipeTitle: String? = nil,
            candidateCodes: [String] = []
        ) {
            self.ingredientName = ingredientName
            self.reason = reason
            self.sourceRecipeTitle = sourceRecipeTitle
            self.candidateCodes = candidateCodes
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
                ) ?? []
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
        /// Computed with a basis nobody has confirmed — decision A: the
        /// number counts, and says of itself that it is provisional.
        public var isProvisional: Bool

        public init(
            ingredientName: String, sourceRecipeTitle: String? = nil,
            basisName: String? = nil, basisCode: String? = nil,
            candidateCodes: [String] = [], isProvisional: Bool = false
        ) {
            self.ingredientName = ingredientName
            self.sourceRecipeTitle = sourceRecipeTitle
            self.basisName = basisName
            self.basisCode = basisCode
            self.candidateCodes = candidateCodes
            self.isProvisional = isProvisional
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
                isProvisional: try container.decodeIfPresent(
                    Bool.self, forKey: .isProvisional
                ) ?? false
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

    /// The "davon 4 unbestätigt": lines that count with a basis nobody has
    /// looked at. They are *not* gaps — they contribute — but the figure they
    /// contribute to has to say so (decision A).
    public var unconfirmedCount: Int { contributions.count { $0.isProvisional } }

    /// Whether any part of the sum rests on an unconfirmed guess.
    public var isProvisional: Bool { unconfirmedCount > 0 }

    /// The lines a "N Zutaten zu klären" flow would walk: everything a basis
    /// would settle, unconfirmed contributions first — they are the ones
    /// already moving a number.
    public var openIngredientNames: [String] {
        var seen = Set<String>()
        let provisional = contributions.filter(\.isProvisional).map(\.ingredientName)
        let missing = gaps.filter { $0.reason.wantsBasis }.map(\.ingredientName)
        return (provisional + missing).filter {
            seen.insert(IngredientCatalog.normalize($0)).inserted
        }
    }

    /// Whether the sum covers everything it claims to.
    ///
    /// Three conditions, and the third is the one phase 4 added: no defects,
    /// at least one contributing line, and nothing unconfirmed. A sum of
    /// nothing is not a complete sum — and neither is one whose lines were
    /// guessed. This gates the NRF badge (decision O1), and a health verdict
    /// computed from an unchecked mapping is exactly the misleading case the
    /// gate exists for: the Schmelzkäse guess can be off by threefold in fat,
    /// which is enough to move a letter grade. Provisional lines still count
    /// *into* the sum — they are not gaps — so the figure itself stays
    /// useful; it is only the verdict that waits.
    public var isComplete: Bool {
        defects.isEmpty && includedCount > 0 && unconfirmedCount == 0
    }
}

/// One ingredient line's fate in the aggregation: what it added to the sum,
/// how sure that is, or why it added nothing.
public struct NutritionLineReport: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        /// Counted, on a basis that has been confirmed or never needed to be.
        case contributed(NutritionInfo)
        /// Counted, on a basis the synonym table proposed and nobody checked.
        /// The third exit the status model asked for: not a gap — the number
        /// is in the sum — and not solid either.
        case provisional(NutritionInfo)
        case gap(NutritionCoverage.GapReason)

        /// What the line added, whether or not it is confirmed.
        public var contribution: NutritionInfo? {
            switch self {
            case .contributed(let info), .provisional(let info): info
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
            case .contributed, .provisional:
                included += 1
                contributions.append(NutritionCoverage.Contribution(
                    ingredientName: line.ingredientName,
                    sourceRecipeTitle: line.sourceRecipeTitle,
                    basisName: line.basis?.catalogName,
                    basisCode: line.basis?.code,
                    candidateCodes: line.candidateCodes,
                    isProvisional: line.outcome.isProvisional
                ))
            case .gap(let reason):
                gaps.append(NutritionCoverage.Gap(
                    ingredientName: line.ingredientName,
                    reason: reason,
                    sourceRecipeTitle: line.sourceRecipeTitle,
                    candidateCodes: line.candidateCodes
                ))
            }
        }
        return NutritionCoverage(includedCount: included, gaps: gaps, contributions: contributions)
    }
}

extension NutritionLineReport.Outcome {
    var isProvisional: Bool {
        if case .provisional = self { return true }
        return false
    }
}
