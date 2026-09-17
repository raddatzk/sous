import Foundation

/// The two denormalized fields a stored recipe carries beside its content —
/// what it can be searched by, and what it can be filtered by.
///
/// Free of any persistence framework, because there are now two stores that
/// write them: the SwiftData one the local half of the app keeps using, and
/// the Core Data one the shared CloudKit database requires. Two copies of
/// this derivation would mean the same library answering the same search
/// differently depending on which store happened to hold it, and the
/// divergence would show up as a recipe that cannot be found rather than as
/// a failure anyone could read.
public enum RecipeIndex {
    /// The ingredients a recipe can be filtered by — each line's own key and,
    /// for a variety, every ancestor's as well.
    ///
    /// All of them, because a recipe calling for Cocktailtomaten *is* a
    /// recipe with tomatoes in it, and one calling for braune Champignons is
    /// a recipe with mushrooms in it two steps up. Filtering by "Pilz" and
    /// not finding it would be the swallowing the variety relation exists to
    /// prevent, in the other direction: the shopping list keeps varieties
    /// apart, the library keeps them together. It used to take one hop,
    /// which was exactly one hop short for the chain the shipped data
    /// already held.
    public static func ingredientKeys(for recipe: Recipe, catalog: IngredientCatalog) -> [String] {
        var seen = Set<String>()
        var keys: [String] = []
        for ingredient in recipe.ingredients {
            let name = ShoppingItem.displayName(for: ingredient.name)
            let own = ShoppingItem.key(for: ingredient.name, catalog: catalog)
            var resolved = catalog.ingredient(for: name)
            var headKey: String?
            if resolved == nil, let head = headWord(of: name) {
                // "1 kleiner Hokkaido" — the catalog knows the head noun,
                // not the phrase. The same reach the step matcher has.
                resolved = catalog.ingredient(for: head)
                headKey = resolved.map(\.key)
            }
            let lineage = resolved.map { catalog.ancestors(of: $0.name).map(\.key) } ?? []
            for key in [own, headKey].compactMap({ $0 }) + lineage {
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                keys.append(key)
            }
        }
        return keys
    }

    public static func searchText(
        for recipe: Recipe,
        variantGroupTitle: String? = nil,
        catalog: IngredientCatalog = .bundled
    ) -> String {
        var parts = [recipe.title]
        if let variantGroupTitle, !variantGroupTitle.isEmpty {
            parts.append(variantGroupTitle)
        }
        parts.append(contentsOf: recipe.categories)
        parts.append(contentsOf: recipe.ingredients.map(\.name))
        // The canonical keys as well, parents included — typing "Kürbis"
        // into the search field must find the recipe whose list only ever
        // says "Hokkaido", the same reach the ingredient filter has always
        // had through `ingredientKeys`.
        parts.append(contentsOf: ingredientKeys(for: recipe, catalog: catalog))
        return parts.joined(separator: " ").lowercased()
    }
}

extension RecipeIndex {
    /// The head noun a multi-word name answers to in running text — "rote
    /// Zwiebel" is called "Zwiebel", "Dose Kokosmilch" is called
    /// "Kokosmilch", "Limette, Saft davon" is called "Limette".
    ///
    /// German noun phrases end in their head — except where a list writes
    /// the qualifier after it ("Paprika rot", "Weißwein trocken"), which is
    /// why the last *capitalized* word wins, nouns being the words German
    /// capitalizes. What follows a comma or an opening parenthesis
    /// qualifies rather than names, a spaced slash offers an alternative
    /// (an unspaced one is a plural marker: "Zehe/n Knoblauch"), and a
    /// purpose clause ("Fett für die Form") stops the phrase early.
    /// `nil` where there is no separate head to speak of: single-word
    /// names, and heads too short to stand for anything on their own.
    static func headWord(of name: String) -> String? {
        var base = Substring(name)
        if let cut = base.range(of: " / ") {
            base = base[..<cut.lowerBound]
        }
        if let cut = base.firstIndex(where: { $0 == "," || $0 == "(" }) {
            base = base[..<cut]
        }
        var words = base.split(separator: " ")
        // "für/zum/zur/nach" open a purpose clause; "Type/Typ" opens a
        // grading — "Weizenmehl Type 405" is called "Weizenmehl", not
        // "Type". Both end the part of the name that names.
        let qualifierWords: Set<String> = ["für", "zum", "zur", "nach", "type", "typ"]
        if let cut = words.firstIndex(where: { qualifierWords.contains($0.lowercased()) }) {
            words = Array(words[..<cut])
        }
        guard let head = (words.last(where: { $0.first?.isUppercase == true }) ?? words.last).map(String.init),
              head.count >= 3,
              IngredientCatalog.normalize(head) != IngredientCatalog.normalize(name)
        else { return nil }
        return head
    }
}
