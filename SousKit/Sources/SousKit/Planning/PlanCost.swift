import Foundation

/// How good a set of dinners is as a mixture, scored without any absolute
/// target.
///
/// The household's members need different amounts of energy — 1800 kcal for
/// one, 1300 for another — so the planner never asks whether a week delivers
/// enough of anything in grams. It asks whether the *mix* is right: nutrients
/// relative to the energy that carries them, per 100 kcal, against the same
/// reference table ``NRF93Score`` has always scored against. A mix that is
/// right is right at every portion size.
enum PlanCost {
    /// What seating a "Will ich kochen" recipe is worth. Small on purpose:
    /// a single squared nutrient term moves by ~0.1–0.3 for a meaningful
    /// density change, so the mark wins ties and near-ties but loses
    /// whenever honouring it costs a real nutrient regression — a bonus,
    /// not a queue.
    static let wantToCookBonus = 0.05

    /// A swap must beat this to count as an improvement, or floating-point
    /// noise keeps the pass "improving" forever.
    static let improvementEpsilon = 1e-9

    /// The nutrient term alone: squared relative shortfalls below the nine
    /// lower bounds plus squared relative excesses above the three caps,
    /// each clamped to [0, 1] so one hopeless micronutrient cannot drown
    /// every other term. Squared, so fixing the worst gap pays more than
    /// polishing a small one. Range [0, 12].
    static func nutrientCost(of mix: NutritionInfo) -> Double {
        // Anything at or below a single kilocalorie is "an empty week":
        // maximally short of everything that matters, over in nothing.
        // Defined rather than computed, so no division can produce NaN, and
        // so any real food strictly improves on nothing — which is the
        // gradient the greedy pass climbs.
        guard mix.kcal > 1 else {
            return Double(NutrientReference.lowerBounds.count)
        }
        let short = NutrientReference.lowerBounds.reduce(into: 0.0) { sum, nutrient in
            let density = nutrient.amount(mix) * 100 / mix.kcal
            let reference = nutrient.densityPer100kcal
            let shortfall = min(1, max(0, (reference - density) / reference))
            sum += shortfall * shortfall
        }
        let over = NutrientReference.upperBounds.reduce(into: 0.0) { sum, nutrient in
            let density = nutrient.amount(mix) * 100 / mix.kcal
            let reference = nutrient.densityPer100kcal
            let excess = min(1, max(0, (density - reference) / reference))
            sum += excess * excess
        }
        return short + over
    }

    /// The full objective the planner minimizes.
    static func totalCost(of mix: NutritionInfo, wantToCookCount: Int) -> Double {
        nutrientCost(of: mix) - wantToCookBonus * Double(wantToCookCount)
    }

    /// The mix judged nutrient by nutrient, for the proposal sheet's
    /// summary line — "Protein gut · Ballaststoffe knapp · Natrium hoch".
    public static func summary(of mix: NutritionInfo) -> MixSummary {
        guard mix.kcal > 1 else {
            return MixSummary(items: NutrientReference.lowerBounds.map {
                MixSummary.Item(label: $0.label, status: .short)
            })
        }
        var items: [MixSummary.Item] = []
        for nutrient in NutrientReference.lowerBounds {
            let density = nutrient.amount(mix) * 100 / mix.kcal
            let shortfall = (nutrient.densityPer100kcal - density) / nutrient.densityPer100kcal
            items.append(MixSummary.Item(
                label: nutrient.label,
                status: shortfall > MixSummary.threshold ? .short : .ok
            ))
        }
        for nutrient in NutrientReference.upperBounds {
            let density = nutrient.amount(mix) * 100 / mix.kcal
            let excess = (density - nutrient.densityPer100kcal) / nutrient.densityPer100kcal
            items.append(MixSummary.Item(
                label: nutrient.label,
                status: excess > MixSummary.threshold ? .over : .ok
            ))
        }
        return MixSummary(items: items)
    }
}

/// The proposal's mix, one verdict per nutrient. Densities and statuses,
/// never absolute amounts — the scoring is volume-blind by design, and a
/// summary claiming "coverage" would pretend otherwise.
public struct MixSummary: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        case short
        case ok
        case over
    }

    public struct Item: Hashable, Sendable {
        public var label: String
        public var status: Status
    }

    /// How far off a density may be before the summary names it — ±15%,
    /// matching where a squared cost term starts to matter.
    static let threshold = 0.15

    public var items: [Item]

    /// The nutrients worth a word: everything short, everything over.
    public var findings: [Item] {
        items.filter { $0.status != .ok }
    }
}
