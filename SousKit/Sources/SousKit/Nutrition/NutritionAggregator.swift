import Foundation

/// Sums a recipe's nutrition from its ingredients, following linked
/// sub-recipes the same way `ShoppingListBuilder` follows them for a
/// shopping list — a curry's linked naan contributes flour and yeast, not a
/// generic "1 portion" placeholder.
///
/// Nothing is skipped silently: every line either contributes or is reported
/// with the reason it could not, so the sum always says what it is based on.
public enum NutritionAggregator {
    /// A curry references its naan, which might reference a spice mix;
    /// beyond that it is a loop or a mistake. Matches `ShoppingListBuilder`.
    private static let maxLinkDepth = 3

    /// The nutrition for `recipe` at `servings` — the total across every
    /// portion, not per portion; the caller divides by `servings` for that —
    /// together with the per-line account of contributions and gaps.
    public static func aggregate(
        recipe: Recipe,
        servings: Int,
        catalog: IngredientCatalog = .bundled,
        nutritionCatalog: NutritionCatalog = .bundled,
        resolve: (UUID) -> Recipe?
    ) -> NutritionReport {
        var lines: [NutritionLineReport] = []
        let total = collect(
            recipe: recipe, servings: servings, depth: 0, visited: [],
            catalog: catalog, nutritionCatalog: nutritionCatalog, resolve: resolve,
            lines: &lines
        )
        return NutritionReport(total: total, lines: lines)
    }

    private static func collect(
        recipe: Recipe,
        servings: Int,
        depth: Int,
        visited: Set<UUID>,
        catalog: IngredientCatalog,
        nutritionCatalog: NutritionCatalog,
        resolve: (UUID) -> Recipe?,
        lines: inout [NutritionLineReport]
    ) -> NutritionInfo {
        var seen = visited
        seen.insert(recipe.id)

        var total = NutritionInfo.zero
        for ingredient in recipe.scaledIngredients(toServings: servings) {
            let displayName = ShoppingItem.displayName(for: ingredient.name)

            // A linked recipe contributes what it is made of, not itself —
            // and its coverage comes along, marked with where it came from,
            // so a gap inside the naan still shows up on the curry.
            if let linkedID = RecipeLink.referencedIDs(in: ingredient.name).first {
                guard depth < maxLinkDepth, !seen.contains(linkedID), let linked = resolve(linkedID) else {
                    lines.append(NutritionLineReport(ingredientName: displayName, outcome: .gap(.unresolvedLink)))
                    continue
                }
                var linkedLines: [NutritionLineReport] = []
                total = total + collect(
                    recipe: linked,
                    servings: portions(of: ingredient) ?? linked.servings,
                    depth: depth + 1,
                    visited: seen,
                    catalog: catalog,
                    nutritionCatalog: nutritionCatalog,
                    resolve: resolve,
                    lines: &linkedLines
                )
                for var line in linkedLines {
                    // The deepest source wins: a gap two links down names the
                    // recipe it actually sits in.
                    line.sourceRecipeTitle = line.sourceRecipeTitle ?? linked.title
                    lines.append(line)
                }
                continue
            }

            // No number at all — recognized, not included, not a defect.
            guard ingredient.quantity != nil else {
                lines.append(NutritionLineReport(ingredientName: displayName, outcome: .gap(.unquantified)))
                continue
            }

            let canonicalName = catalog.canonicalName(for: ingredient.name)
            let entry = nutritionCatalog.nutrition(forCanonicalName: canonicalName)
            // The candidates ride along on every outcome, gaps included: the
            // line with no basis is the one the picker exists for.
            let candidates = entry?.candidateCodes ?? []

            func report(_ outcome: NutritionLineReport.Outcome, basis: NutritionBasis? = nil) {
                lines.append(NutritionLineReport(
                    ingredientName: displayName, outcome: outcome,
                    basis: basis, candidateCodes: candidates
                ))
            }

            guard let basis = entry?.basis(for: ingredient.state) else {
                // A name nothing knows wants a catalog entry first; a known
                // name without numbers wants the numbers — different fixes,
                // different reasons.
                let reason: NutritionCoverage.GapReason =
                    entry == nil && catalog.ingredient(for: ingredient.name) == nil
                        ? .noCatalogMatch : .noNutritionValues
                report(.gap(reason))
                continue
            }

            // A basis that is a *decision* rather than numbers ends the line
            // here. "Bewusst ohne" is an answer and stops counting as a
            // defect; an orphaned mapping is a question and keeps counting.
            guard basis.status.contributes else {
                report(
                    .gap(basis.status == .deliberatelyWithout ? .deliberatelyWithout : .orphanedBasis),
                    basis: basis
                )
                continue
            }

            guard let grams = NutritionResolver.resolvedGrams(
                for: ingredient, catalog: catalog, nutritionCatalog: nutritionCatalog
            ) else {
                report(.gap(.noGramEquivalent))
                continue
            }

            let contribution = basis.values.scaled(byGrams: grams)
            // The basis and the alternatives ride along with the number, so
            // whatever shows it can say what it rests on — and so the picker
            // has the candidate list without recomputing anything. The status
            // decides which of the two counting outcomes this is: both land
            // in the sum, only one of them without a caveat.
            report(
                basis.status == .confirmed
                    ? .contributed(contribution) : .provisional(contribution),
                basis: basis
            )
            total = total + contribution
        }
        return total
    }

    /// "2 Portionen Naan" means the naan recipe at two servings; without an
    /// amount, it is taken as written. Matches `ShoppingListBuilder.portions`.
    private static func portions(of ingredient: RecipeIngredient) -> Int? {
        guard let quantity = ingredient.quantity, quantity.unit == .portion else { return nil }
        return max(1, Int(quantity.amount.rounded()))
    }
}
