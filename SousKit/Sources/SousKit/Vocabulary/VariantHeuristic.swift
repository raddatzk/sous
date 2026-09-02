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
    /// way. Only asked of a name the catalog does not know yet — the one
    /// casual moment of decision B. For a known ingredient the picker asks
    /// ``candidates(for:in:)`` instead.
    public static func parent(for name: String, in catalog: IngredientCatalog) -> CatalogIngredient? {
        guard catalog.ingredient(for: name) == nil else { return nil }
        return candidates(for: name, in: catalog).first
    }

    /// Every ingredient `name` reads like a variety of, best first.
    ///
    /// What the parent picker leads with: the head-noun matches for the word
    /// as written, longest match first, before the cook has typed anything
    /// into the search. Varieties are candidates too — a chain may be any
    /// depth now (catalog target, decision A), and "Brauner Champignon"
    /// belongs under Champignon, not beside it under Pilz. The word itself
    /// is never its own candidate; whether a candidate would close a loop is
    /// the picker's question, since only it knows which ingredient is asking.
    public static func candidates(for name: String, in catalog: IngredientCatalog) -> [CatalogIngredient] {
        let candidate = IngredientCatalog.normalize(name)
        guard candidate.count > minimumPrefix else { return [] }
        return catalog.ingredients
            .compactMap { ingredient -> (CatalogIngredient, Int)? in
                guard ingredient.key != candidate,
                      let length = headLength(of: candidate, for: ingredient)
                else { return nil }
                return (ingredient, length)
            }
            .sorted { first, second in
                first.1 == second.1 ? first.0.name < second.0.name : first.1 > second.1
            }
            .map(\.0)
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
