import Foundation

/// The shopping list, as a list that exists.
///
/// Things get on it because someone put them there — from a recipe, from a
/// week's plan, or typed by hand. It does not follow the meal plan on its
/// own: a list that rewrites itself while shopping is worse than useless.
public protocol ShoppingListStore: Sendable {
    func items() async throws -> [ShoppingItem]
    /// Adds items, merging amounts into lines already on the list.
    func add(_ items: [ShoppingItem]) async throws
    func setChecked(_ checked: Bool, key: String) async throws
    func remove(key: String) async throws
    /// Removes everything ticked off — after the shopping is done.
    func clearChecked() async throws
}
