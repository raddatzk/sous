import Foundation
import SwiftData

/// One recipe on the shopping list, at the scale it was added — the mutable
/// half of the document. Joined from demands by `id`, never by relationship.
@Model
public final class StoredShoppingPlanEntry {
    #Index<StoredShoppingPlanEntry>([\.id])

    public var id: UUID = UUID()
    public var recipeID: UUID?
    /// The title as it read when added; renames do not reach the list.
    public var title: String = ""
    /// The portion count the demands were captured at. Never changes.
    public var servingsCaptured: Int = 1
    /// The portion count the cook wants now.
    public var servingsCurrent: Int = 1
    /// Position among the recipe sections of the by-recipe view.
    public var sortOrder: Int = 0
    public var addedAt: Date = Date.nowInSyncPrecision
    public var updatedAt: Date = Date.nowInSyncPrecision

    public init(_ entry: ShoppingPlanEntry) {
        id = entry.id
        recipeID = entry.recipeID
        title = entry.title
        servingsCaptured = entry.servingsCaptured
        servingsCurrent = entry.servingsCurrent
        addedAt = entry.addedAt
    }

    public var domainValue: ShoppingPlanEntry {
        ShoppingPlanEntry(
            id: id,
            recipeID: recipeID,
            title: title,
            servingsCaptured: servingsCaptured,
            servingsCurrent: servingsCurrent,
            addedAt: addedAt
        )
    }
}
