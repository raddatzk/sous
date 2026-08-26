import Foundation
import SwiftData

/// The persisted form of a ``VariantGroup``.
///
/// A row of its own rather than a title repeated on every member. The title
/// is denormalized into each member's `searchText` so that searching stays
/// one indexed comparison — but that copy is an index, rebuilt from here the
/// way `ingredientKeys` is rebuilt from the ingredient text. Were it the
/// storage instead, two devices renaming the group would leave the members
/// disagreeing about what the dish is called, with nothing able to decide
/// between them.
///
/// Every field has a default, which is what makes the migration a light one.
@Model
public final class StoredVariantGroup {
    public var id: UUID = UUID()
    public var title: String = ""
    public var createdAt: Date = Date.nowInSyncPrecision
    public var updatedAt: Date = Date.nowInSyncPrecision

    public init(_ group: VariantGroup) {
        id = group.id
        apply(group)
    }

    public func apply(_ group: VariantGroup) {
        title = group.title
        createdAt = group.createdAt
        updatedAt = group.updatedAt
    }

    public var domainValue: VariantGroup {
        VariantGroup(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt)
    }
}
