import Foundation

/// A category a recipe's own numbers would justify — "proteinreich",
/// "ballaststoffreich" — offered to the cook rather than written for them.
///
/// These are ordinary `Recipe.categories` entries once accepted, with the
/// same free-text spelling the cook already uses. Nothing here writes a
/// category: a tag is a *suggestion* until somebody says yes, because the
/// numbers behind it rest on a catalog that does not know every ingredient,
/// and a claim about food is not the kind of thing to make on a recipe's
/// behalf.
///
/// The measures are energy-relative, not per portion, and deliberately so.
/// A library holds whole cakes filed as one serving; a per-portion threshold
/// reads those as extraordinary, while a share of the dish's own energy
/// divides the serving count out of the question entirely. It is also the
/// form the EU health claims take, which is where the default thresholds
/// come from.
public struct NutritionTag: Hashable, Sendable {
    public enum Kind: String, CaseIterable, Hashable, Sendable {
        case proteinRich
        case fiberRich

        /// The category name as it is written into the recipe. German, and
        /// lowercase, because that is how the cook writes categories.
        public var categoryName: String {
            switch self {
            case .proteinRich: "proteinreich"
            case .fiberRich: "ballaststoffreich"
            }
        }
    }

    public var kind: Kind
    /// The measured value the claim rests on, in the unit of its own measure:
    /// a fraction of energy for protein, grams per 100 kcal for fibre.
    public var value: Double
    /// How much of the recipe those numbers actually cover.
    public var completeness: Double

    public init(kind: Kind, value: Double, completeness: Double) {
        self.kind = kind
        self.value = value
        self.completeness = completeness
    }

    public var categoryName: String { kind.categoryName }

    /// What the suggestion says about itself — the house rule that a figure
    /// never appears naked applies to a tag as much as to a kcal line.
    public var reason: String {
        switch kind {
        case .proteinRich:
            String(format: "%.0f %% der Energie aus Eiweiß", value * 100)
        case .fiberRich:
            String(format: "%.1f g Ballaststoffe je 100 kcal", value)
        }
    }
}

/// Reads a recipe's nutrition and says which nutrition categories it would
/// support — the derivation behind ``NutritionTag``.
public enum NutritionTagging {
    /// The share of a dish's energy that has to come from protein. The EU
    /// health-claim value for "hoher Proteingehalt"; the claim for a mere
    /// "Proteinquelle" is 12 %, which a great many ordinary dishes clear and
    /// which would make the tag say nothing.
    public static let proteinEnergyShare = 0.20

    /// Grams of fibre per 100 kcal, the energy-relative half of the EU claim
    /// for "hoher Ballaststoffgehalt".
    public static let fiberPer100kcal = 3.0

    /// How much of a recipe the numbers must account for before a tag may be
    /// claimed at all.
    ///
    /// This is the part that decides whether the feature is honest. A dish
    /// whose protein-carrying ingredients are the ones the catalog failed to
    /// resolve measures low for a reason that has nothing to do with the
    /// dish — so below this line the answer is silence, not "no".
    public static let minimumCompleteness = 0.7

    /// Every tag `nutrition` supports, whatever the recipe already carries.
    public static func tags(for nutrition: RecipeNutrition) -> [NutritionTag] {
        let coverage = nutrition.coverage
        guard coverage.accountableCount > 0, nutrition.perPortion.kcal > 0 else { return [] }
        let completeness = Double(coverage.includedCount) / Double(coverage.accountableCount)
        guard completeness >= minimumCompleteness else { return [] }

        var tags: [NutritionTag] = []
        let energy = nutrition.perPortion.kcal
        let proteinShare = nutrition.perPortion.proteinG * 4 / energy
        if proteinShare >= proteinEnergyShare {
            tags.append(NutritionTag(kind: .proteinRich, value: proteinShare, completeness: completeness))
        }
        let fiberDensity = nutrition.perPortion.fiberG / (energy / 100)
        if fiberDensity >= fiberPer100kcal {
            tags.append(NutritionTag(kind: .fiberRich, value: fiberDensity, completeness: completeness))
        }
        return tags
    }

    /// The tags worth putting in front of the cook: supported by the numbers,
    /// not already on the recipe, and not one they have turned down before.
    ///
    /// A decline is permanent and is deliberately not stamped against the
    /// recipe's content the way a derived guess is. "Nein, das ist für mich
    /// kein proteinreiches Gericht" is a judgement about the dish, and it
    /// would be rude to ask again because a step was reworded.
    public static func suggestions(
        for nutrition: RecipeNutrition,
        existing categories: [String],
        declined: Set<NutritionTag.Kind> = []
    ) -> [NutritionTag] {
        let taken = Set(categories.map { $0.lowercased() })
        return tags(for: nutrition).filter { tag in
            !declined.contains(tag.kind) && !taken.contains(tag.categoryName.lowercased())
        }
    }
}
