import Foundation

/// Whether the amount refers to the ingredient raw or cooked. This matters for
/// nutrition lookup — 100 g of raw and cooked pasta are very different things.
public enum IngredientState: String, Codable, Hashable, Sendable {
    case unspecified
    case raw
    case cooked
}

/// One line of a recipe's ingredient list.
///
/// The fields are kept separate on purpose: quantity, unit, name, and
/// preparation each need to be addressed on their own for scaling, nutrition
/// matching, and shopping lists. Merging them into one string is the thing
/// that cannot be undone later.
public struct RecipeIngredient: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// The ingredient itself, without amount or preparation: "Zwiebel".
    public var name: String
    /// `nil` means an unquantified amount ("Salz nach Geschmack").
    public var quantity: Quantity?
    /// How it is prepared: "fein gehackt".
    public var preparation: String?
    /// Optional heading this line belongs to: "Für den Teig".
    public var group: String?
    public var state: IngredientState
    /// Grams resolved against a nutrition database. Populated in phase 2,
    /// never entered by hand.
    public var resolvedGrams: Double?
    /// Set when this ingredient is itself another recipe in the library.
    public var linkedRecipeID: UUID?
    /// Seasoning and frying oil do not scale linearly with servings.
    public var scalesWithServings: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        quantity: Quantity? = nil,
        preparation: String? = nil,
        group: String? = nil,
        state: IngredientState = .unspecified,
        resolvedGrams: Double? = nil,
        linkedRecipeID: UUID? = nil,
        scalesWithServings: Bool = true
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.preparation = preparation
        self.group = group
        self.state = state
        self.resolvedGrams = resolvedGrams
        self.linkedRecipeID = linkedRecipeID
        self.scalesWithServings = scalesWithServings
    }
}
