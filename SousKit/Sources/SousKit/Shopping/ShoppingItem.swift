import Foundation

/// What one recipe contributed to a line, in the shape the list stored
/// before it became a document. Kept only to read old stores — new
/// contributions are ``ShoppingDemand`` rows.
public struct ShoppingSource: Hashable, Sendable, Codable {
    public var recipeTitle: String
    public var quantities: [Quantity]

    public init(recipeTitle: String, quantities: [Quantity] = []) {
        self.recipeTitle = recipeTitle
        self.quantities = quantities
    }
}

/// One checkable line on the shopping list.
///
/// An ingredient usually has one item — but never only one forever: demand
/// that arrives after the cook checked something off lands on a fresh, open
/// item under the same ingredient, because the check-off is the cook's work
/// and is not reset. Display groups the items of an ingredient back into one
/// place on the list.
public struct ShoppingItem: Identifiable, Hashable, Sendable {
    public let itemID: UUID
    public var id: UUID { itemID }

    /// The normalized ingredient name the item bundles under — or, for a
    /// line the app could not interpret, the normalized raw text itself.
    public var key: String
    public var name: String
    /// The aisle it is found in, when the catalog knows the ingredient.
    /// `nil` is what makes a raw-text item "unassigned".
    public var category: IngredientCategory?
    /// Every captured contribution, one row per recipe line. Summing happens
    /// at display, never in here.
    public var demands: [ShoppingDemand]
    /// What was added straight to the list, belonging to no recipe.
    public var manualQuantities: [Quantity]
    public var isChecked: Bool
    /// Appeared after the same ingredient was already checked off — shown so
    /// the list honestly tells what changed since then.
    public var isLateAddition: Bool
    /// Swept off the list after shopping. The row stays as the document's
    /// memory; the views leave it out.
    public var isCleared: Bool

    public init(
        itemID: UUID = UUID(),
        key: String,
        name: String,
        category: IngredientCategory? = nil,
        demands: [ShoppingDemand] = [],
        manualQuantities: [Quantity] = [],
        isChecked: Bool = false,
        isLateAddition: Bool = false,
        isCleared: Bool = false
    ) {
        self.itemID = itemID
        self.key = key
        self.name = name
        self.category = category
        self.demands = demands
        self.manualQuantities = manualQuantities
        self.isChecked = isChecked
        self.isLateAddition = isLateAddition
        self.isCleared = isCleared
    }

    /// Everything still wanted of it, bundled unit by unit for display.
    /// Lapsed demand stays out — it is annotation, not appetite.
    public var quantities: [Quantity] {
        demands
            .filter { !$0.isLapsed }
            .compactMap(\.effectiveQuantity)
            .reduce(into: [Quantity]()) { $0 = $0.adding($1) }
            .adding(manualQuantities)
    }

    /// What is no longer wanted of a checked item — scaled-down remains and
    /// demand whose recipe left the plan. Rendered struck through.
    public var lapsedQuantities: [Quantity] {
        demands.reduce(into: [Quantity]()) { result, demand in
            if demand.isLapsed, let quantity = demand.effectiveQuantity {
                result = result.adding(quantity)
            } else if let lapsed = demand.lapsedQuantity {
                result = result.adding(lapsed)
            }
        }
    }

    /// Came from no recipe at all.
    public var isManual: Bool { demands.isEmpty }

    /// Where it reads as coming from, each origin named once.
    public var originTitles: [String] {
        var seen = Set<String>()
        return demands.compactMap { demand in
            guard !demand.originTitle.isEmpty, seen.insert(demand.originTitle).inserted else { return nil }
            return demand.originTitle
        }
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
