import Foundation

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
    /// Which recipes asked for it, for when the list looks surprising.
    public var recipeTitles: [String]
    public var isChecked: Bool
    public var isManual: Bool

    public init(
        key: String,
        name: String,
        quantities: [Quantity] = [],
        recipeTitles: [String] = [],
        isChecked: Bool = false,
        isManual: Bool = false
    ) {
        self.key = key
        self.name = name
        self.quantities = quantities
        self.recipeTitles = recipeTitles
        self.isChecked = isChecked
        self.isManual = isManual
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
