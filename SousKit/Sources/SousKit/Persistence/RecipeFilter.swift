import Foundation

/// A recognized filter: a known ingredient or an existing category, rather
/// than free text.
///
/// Typing "Tomate" into the search field could mean the word, the ingredient,
/// or a category someone named that. Turning it into a filter makes the
/// difference explicit and lets several of them stack up.
public struct RecipeFilter: Hashable, Identifiable, Sendable {
    public enum Kind: Hashable, Sendable {
        case ingredient
        case category
        /// A meal the dish suits — see ``MealSlot``. Unlike the other two,
        /// this is not written on the recipe in every case: most recipes say
        /// "Automatisch", and what fills that in is the guess the planner
        /// caches. Which is why a slot filter is answered by
        /// ``RecipeLibrary``, where that cache is, rather than by the store.
        case slot
        /// How much work the dish is. Like ``slot`` and unlike the other
        /// two, this is mostly not written on the recipe: it is read off the
        /// recipe's structure unless a cook overruled it, so the store
        /// cannot answer it and ``RecipeLibrary`` does.
        case effort
    }

    public let kind: Kind
    /// What is matched against: a catalog key, or the category as written.
    public let key: String
    /// What is shown on the chip.
    public let title: String
    /// The spelling that actually matched, when it was not the title —
    /// otherwise "Gurke" appears for "sal" with no way to tell why.
    public let matchedAs: String?

    public var id: String { "\(kind)-\(key)" }

    public init(kind: Kind, key: String, title: String, matchedAs: String? = nil) {
        self.kind = kind
        self.key = key
        self.title = title
        self.matchedAs = matchedAs
    }

    public static func ingredient(
        _ ingredient: CatalogIngredient,
        matchedAs: String? = nil
    ) -> RecipeFilter {
        RecipeFilter(
            kind: .ingredient,
            key: ingredient.key,
            title: ingredient.name,
            matchedAs: matchedAs
        )
    }

    public static func category(_ name: String) -> RecipeFilter {
        RecipeFilter(kind: .category, key: name.lowercased(), title: name)
    }

    public static func slot(_ slot: MealSlot) -> RecipeFilter {
        RecipeFilter(kind: .slot, key: slot.rawValue, title: slot.title)
    }

    public static func effort(_ level: RecipeEffort.Level) -> RecipeFilter {
        RecipeFilter(kind: .effort, key: level.rawValue, title: level.title)
    }

    /// The rung this filter stands for, where it stands for one.
    public var effort: RecipeEffort.Level? {
        kind == .effort ? RecipeEffort.Level(rawValue: key) : nil
    }

    /// The meal this filter stands for, where it stands for one.
    public var slot: MealSlot? {
        kind == .slot ? MealSlot(rawValue: key) : nil
    }

    /// What the chip wears — said here so that every field drawing these
    /// tokens agrees, rather than each spelling out the same conditional.
    public var symbolName: String {
        switch kind {
        case .ingredient: "carrot"
        case .category: "tag"
        case .slot: slot?.symbolName ?? "fork.knife"
        case .effort: effort?.symbolName ?? "gauge.with.dots.needle.50percent"
        }
    }

    /// What the typed text could be filtered by.
    ///
    /// Ingredients and categories are ranked together rather than one after
    /// the other: typing "Sal" should offer the category "Salate" beside the
    /// ingredient "Salat", not push it out with five ingredients first.
    ///
    /// Anything already applied is left out — there is no point offering a
    /// filter twice.
    public static func suggestions(
        for text: String,
        catalog: IngredientCatalog,
        categories: [String],
        applied: [RecipeFilter] = [],
        limit: Int = 5
    ) -> [RecipeFilter] {
        let query = IngredientCatalog.normalize(text)
        guard query.count >= 2 else { return [] }

        var candidates: [(filter: RecipeFilter, rank: Int)] = []

        for category in categories {
            guard let rank = rank(of: category, matching: query) else { continue }
            candidates.append((.category(category), rank))
        }

        // "Früh" offers the meal as readily as a category would: the three
        // are a closed set, so this costs a comparison each.
        for slot in MealSlot.allCases {
            guard let rank = rank(of: slot.title, matching: query) else { continue }
            candidates.append((.slot(slot), rank))
        }

        // Same reasoning as the meals: three rungs, one comparison each, and
        // typing "aufwendig" is the only way to reach them — effort is not a
        // word that appears in a recipe, so nothing else would ever offer it.
        for level in RecipeEffort.Level.allCases {
            guard let rank = rank(of: level.title, matching: query) else { continue }
            candidates.append((.effort(level), rank))
        }

        for ingredient in catalog.ingredients {
            // The closest spelling decides both whether it matches and how
            // well; the title matching counts as better than an alias.
            let ranked = ingredient.keys.enumerated().compactMap { index, key -> (Int, Int)? in
                guard let rank = rank(of: key, matching: query) else { return nil }
                return (index == 0 ? rank : rank + 1, index)
            }
            guard let best = ranked.min(by: { $0.0 < $1.0 }) else { continue }

            let matchedSpelling = best.1 == 0 ? nil : ([ingredient.name] + ingredient.aliases)[best.1]
            candidates.append((.ingredient(ingredient, matchedAs: matchedSpelling), best.0))
        }

        let appliedIDs = Set(applied.map(\.id))
        return candidates
            .filter { !appliedIDs.contains($0.filter.id) }
            .sorted { first, second in
                first.rank == second.rank
                    ? (first.filter.title.count == second.filter.title.count
                        ? first.filter.title < second.filter.title
                        : first.filter.title.count < second.filter.title.count)
                    : first.rank < second.rank
            }
            .prefix(limit)
            .map(\.filter)
    }

    /// Lower is closer: starting with what was typed beats containing it.
    private static func rank(of candidate: String, matching query: String) -> Int? {
        let normalized = IngredientCatalog.normalize(candidate)
        if normalized.hasPrefix(query) { return 0 }
        if normalized.contains(query) { return 2 }
        return nil
    }
}
