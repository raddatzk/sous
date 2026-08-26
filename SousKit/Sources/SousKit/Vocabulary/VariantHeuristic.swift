import Foundation

/// Whether a name being written for the first time reads like a variety of
/// something the app already knows — decision B's word-ending heuristic.
///
/// German compounds end in their head noun: "Cocktailtomate" is a tomato,
/// "Rinderhackfleisch" is minced meat, "Zartbitterschokolade" is chocolate.
/// So the test is a *suffix* match against the known word or one of its
/// spellings, not the bare substring containment that would also propose
/// "Tomatenmark" for "Mark".
///
/// It is deliberately only ever a proposal, offered in the single moment a
/// new ingredient comes into being, and never applied silently — because the
/// same rule that catches the compounds also catches the false friends it
/// cannot tell apart from them ("Erdnussbutter" ends in "butter" and is not
/// a kind of butter). One casual question at the one moment the answer is
/// cheap; never a rule that regroups the shopping list behind the cook's back.
public enum VariantHeuristic {
    /// At least this much word has to sit in front of the head noun. Below
    /// it the "compound" is a plural or a typo: "Tomate" / "Tomaten".
    private static let minimumPrefix = 3

    /// The ingredient `name` would most plausibly be a variety of, or `nil`.
    ///
    /// The longest matching head noun wins, so "Kirschtomate" is offered as a
    /// tomato rather than as anything shorter that happens to end the same
    /// way. Ingredients that are already varieties are skipped: the relation
    /// is one level deep.
    public static func parent(for name: String, in catalog: IngredientCatalog) -> CatalogIngredient? {
        let candidate = IngredientCatalog.normalize(name)
        guard candidate.count > minimumPrefix else { return nil }
        // A name the catalog already knows is not a new ingredient, and this
        // question is only ever asked of new ones.
        guard catalog.ingredient(for: name) == nil else { return nil }

        var best: (ingredient: CatalogIngredient, length: Int)?
        for ingredient in catalog.ingredients where ingredient.parentName == nil {
            guard let length = headLength(of: candidate, for: ingredient) else { continue }
            if best == nil || length > best!.length {
                best = (ingredient, length)
            }
        }
        return best?.ingredient
    }

    /// How many characters of `candidate` the ingredient's own spellings
    /// account for at the end, or `nil` when none of them does.
    private static func headLength(of candidate: String, for ingredient: CatalogIngredient) -> Int? {
        var longest: Int?
        for spelling in ingredient.keys {
            guard spelling.count >= minimumPrefix,
                  candidate.hasSuffix(spelling),
                  candidate.count - spelling.count >= minimumPrefix
            else { continue }
            if longest == nil || spelling.count > longest! { longest = spelling.count }
        }
        return longest
    }
}
