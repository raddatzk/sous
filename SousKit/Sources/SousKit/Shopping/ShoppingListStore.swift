import Foundation

/// What the shopping list keeps between rebuilds.
///
/// The list itself is derived from the plan and rebuilt whenever the plan
/// changes; only two things have to survive that: what has been ticked off,
/// and what was added by hand.
public protocol ShoppingListStore: Sendable {
    func checkedKeys() async throws -> Set<String>
    func setChecked(_ checked: Bool, key: String) async throws
    func manualItems() async throws -> [ShoppingItem]
    func addManualItem(name: String, quantity: Quantity?) async throws
    func removeManualItem(key: String) async throws
    /// Clears ticks and removes ticked-off manual items — after the shopping
    /// is done.
    func clearChecked() async throws
}
