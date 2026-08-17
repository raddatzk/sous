import Foundation

/// What one recipe contributes to a line on the list.
///
/// Kept per recipe rather than folded into one number, so the list can be
/// read either way: "500 g Tomaten" for shopping, or "Curry: 300 g" when
/// checking whether everything for a dish is there.
public struct ShoppingSource: Hashable, Sendable, Codable {
    public var recipeTitle: String
    public var quantities: [Quantity]

    public init(recipeTitle: String, quantities: [Quantity] = []) {
        self.recipeTitle = recipeTitle
        self.quantities = quantities
    }
}

/// One line on the shopping list.
public struct ShoppingItem: Identifiable, Hashable, Sendable {
    /// Stable across rebuilds of the list, so ticking something off survives
    /// a change to the plan.
    public let key: String
    public var id: String { key }

    public var name: String
    /// One amount per measurement dimension: grams and millilitres of the
    /// same thing do not add up, and neither do "2 Stück" and "1 Prise".
    public var quantities: [Quantity]
    /// Which recipes asked for it, and how much each of them wants.
    public var sources: [ShoppingSource]
    public var isChecked: Bool

    /// Typed by hand rather than taken from a recipe.
    public var isManual: Bool { sources.isEmpty }

    public var recipeTitles: [String] { sources.map(\.recipeTitle) }

    public init(
        key: String,
        name: String,
        quantities: [Quantity] = [],
        sources: [ShoppingSource] = [],
        isChecked: Bool = false
    ) {
        self.key = key
        self.name = name
        self.quantities = quantities
        self.sources = sources
        self.isChecked = isChecked
    }

    /// The key an ingredient name reduces to: lowercased, without markdown
    /// link syntax, so "[Naan](sous://…)" and "Naan" are the same thing.
    public static func key(for name: String) -> String {
        var cleaned = name
        if let match = name.firstMatch(of: /\[([^\]]+)\]\([^)]*\)/) {
            cleaned = String(match.1)
        }
        return cleaned
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// The name without link syntax, for display.
    public static func displayName(for name: String) -> String {
        guard let match = name.firstMatch(of: /\[([^\]]+)\]\([^)]*\)/) else { return name }
        return String(match.1)
    }
}
