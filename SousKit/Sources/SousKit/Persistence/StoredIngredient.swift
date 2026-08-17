import Foundation
import SwiftData

/// The persisted form of one ingredient line.
///
/// Order carries meaning in a recipe, and SwiftData does not guarantee the
/// order of a relationship, so it is stored explicitly.
@Model
public final class StoredIngredient {
    public var id: UUID = UUID()
    public var sortOrder: Int = 0
    public var name: String = ""
    /// Split into amount and symbol rather than stored as a composite, so
    /// both stay queryable.
    public var amount: Double?
    public var unitSymbol: String?
    public var preparation: String?
    public var group: String?
    public var state: String = IngredientState.unspecified.rawValue
    public var resolvedGrams: Double?
    public var linkedRecipeID: UUID?
    public var scalesWithServings: Bool = true

    public var recipe: StoredRecipe?

    public init(_ ingredient: RecipeIngredient, sortOrder: Int) {
        id = ingredient.id
        self.sortOrder = sortOrder
        name = ingredient.name
        amount = ingredient.quantity?.amount
        unitSymbol = ingredient.quantity?.unit.symbol
        preparation = ingredient.preparation
        group = ingredient.group
        state = ingredient.state.rawValue
        resolvedGrams = ingredient.resolvedGrams
        linkedRecipeID = ingredient.linkedRecipeID
        scalesWithServings = ingredient.scalesWithServings
    }

    public var domainValue: RecipeIngredient {
        RecipeIngredient(
            id: id,
            name: name,
            quantity: quantity,
            preparation: preparation,
            group: group,
            state: IngredientState(rawValue: state) ?? .unspecified,
            resolvedGrams: resolvedGrams,
            linkedRecipeID: linkedRecipeID,
            scalesWithServings: scalesWithServings
        )
    }

    private var quantity: Quantity? {
        guard let amount, let unitSymbol else { return nil }
        return Quantity(amount, IngredientUnit(symbol: unitSymbol))
    }
}
