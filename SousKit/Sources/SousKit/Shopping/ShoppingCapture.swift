import Foundation

/// One demand as the builder captured it, still carrying the ingredient
/// identity the store needs to find or create the item it lands on.
public struct CapturedShoppingDemand: Hashable, Sendable {
    /// The item join: ``ShoppingItem/key(for:catalog:)`` of the line's name.
    public var key: String
    /// The name the item shows if it has to be created — the catalog's
    /// spelling when the ingredient is known, the written one otherwise.
    public var displayName: String
    public var category: IngredientCategory?
    public var demand: ShoppingDemand

    public init(key: String, displayName: String, category: IngredientCategory?, demand: ShoppingDemand) {
        self.key = key
        self.displayName = displayName
        self.category = category
        self.demand = demand
    }
}

/// Everything one add operation captured: the plan entries for the recipes
/// put on the list, and their demands in list order. The store turns this
/// into items under the reconciliation rules — the builder stays pure.
public struct ShoppingCapture: Hashable, Sendable {
    public var planEntries: [ShoppingPlanEntry]
    public var demands: [CapturedShoppingDemand]

    public init(planEntries: [ShoppingPlanEntry] = [], demands: [CapturedShoppingDemand] = []) {
        self.planEntries = planEntries
        self.demands = demands
    }
}
