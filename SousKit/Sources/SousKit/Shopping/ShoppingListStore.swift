import Foundation

/// The list and the plan it derives from, read together.
public struct ShoppingListSnapshot: Sendable {
    public var items: [ShoppingItem]
    public var planEntries: [ShoppingPlanEntry]

    public init(items: [ShoppingItem] = [], planEntries: [ShoppingPlanEntry] = []) {
        self.items = items
        self.planEntries = planEntries
    }
}

/// The shopping list, as a document that exists.
///
/// Things get on it because someone put them there — from a recipe, from a
/// week's plan, or typed by hand. It does not follow the meal plan on its
/// own: a list that rewrites itself while shopping is worse than useless.
/// One rule binds every mutation: checking off is the cook's work and is
/// never reset.
public protocol ShoppingListStore: Sendable {
    func snapshot() async throws -> ShoppingListSnapshot
    /// Adds a capture of planned recipes. New demand under an ingredient
    /// already checked off lands on a fresh open item instead of un-checking.
    func add(_ capture: ShoppingCapture) async throws
    /// Adds a line typed by hand, under the same never-un-check rule.
    func addManual(key: String, name: String, category: IngredientCategory?, quantities: [Quantity]) async throws
    func setChecked(_ checked: Bool, itemID: UUID) async throws
    func remove(itemID: UUID) async throws
    /// Turns a plan entry's portion dial. Open items adjust in place;
    /// checked ones get the difference appended or the lapse annotated.
    func setServings(_ servings: Int, planEntryID: UUID) async throws
    /// Takes a recipe off the plan. Open demand disappears; on checked
    /// items it is annotated as lapsed rather than deleted.
    func removePlanEntry(_ planEntryID: UUID) async throws
    /// Sweeps everything ticked off out of sight — after the shopping is
    /// done. Rows are kept, not deleted.
    func clearChecked() async throws
}
