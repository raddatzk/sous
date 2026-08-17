import Foundation

/// What one recipe contributes to a line on the list.
public struct ShoppingSource: Hashable, Sendable, Codable {
    public var recipeTitle: String
    public var quantities: [Quantity]

    public init(recipeTitle: String, quantities: [Quantity] = []) {
        self.recipeTitle = recipeTitle
        self.quantities = quantities
    }
}

/// One line on the shopping list.
///
/// Only the contributions are stored — per recipe, and whatever was typed in
/// by hand. The total is derived from them, so the two readings of the list
/// cannot drift apart: adding something by hand to a line that already came
/// from a recipe used to raise the total without appearing under any dish.
public struct ShoppingItem: Identifiable, Hashable, Sendable {
    /// Stable across rebuilds of the list, so ticking something off survives
    /// a change to the plan.
    public let key: String
    public var id: String { key }

    public var name: String
    /// The aisle it is found in, when the catalog knows the ingredient.
    public var category: IngredientCategory?
    /// Which recipes asked for it, and how much each of them wants.
    public var sources: [ShoppingSource]
    /// What was added straight to the list, belonging to no recipe.
    public var manualQuantities: [Quantity]
    public var isChecked: Bool

    /// Everything wanted of it, however it got onto the list.
    public var quantities: [Quantity] {
        sources
            .reduce(into: [Quantity]()) { $0 = $0.adding($1.quantities) }
            .adding(manualQuantities)
    }

    /// Came from no recipe at all.
    public var isManual: Bool { sources.isEmpty }

    public var recipeTitles: [String] { sources.map(\.recipeTitle) }

    public init(
        key: String,
        name: String,
        category: IngredientCategory? = nil,
        sources: [ShoppingSource] = [],
        manualQuantities: [Quantity] = [],
        isChecked: Bool = false
    ) {
        self.key = key
        self.name = name
        self.category = category
        self.sources = sources
        self.manualQuantities = manualQuantities
        self.isChecked = isChecked
    }

    /// The key an ingredient name reduces to: stripped of markdown link
    /// syntax and resolved through the catalog, so "Tomaten", "tomate" and
    /// "Cocktailtomaten" are one line on the list.
    public static func key(for name: String, catalog: IngredientCatalog = .bundled) -> String {
        IngredientCatalog.normalize(catalog.canonicalName(for: displayName(for: name)))
    }

    /// The name without link syntax, for display.
    public static func displayName(for name: String) -> String {
        guard let match = name.firstMatch(of: /\[([^\]]+)\]\([^)]*\)/) else { return name }
        return String(match.1)
    }
}
