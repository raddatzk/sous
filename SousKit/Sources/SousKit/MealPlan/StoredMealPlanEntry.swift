import Foundation
import SwiftData

/// The persisted form of a plan entry.
@Model
public final class StoredMealPlanEntry {
    #Index<StoredMealPlanEntry>([\.day])

    public var id: UUID = UUID()
    public var day: Date?
    public var slotRaw: String = MealSlot.dinner.rawValue
    public var recipeID: UUID = UUID()
    public var servings: Int?
    public var sortOrder: Int = 0
    public var createdAt: Date = Date.nowInSyncPrecision
    public var updatedAt: Date = Date.nowInSyncPrecision
    public var deletedAt: Date?

    public init(_ entry: MealPlanEntry) {
        id = entry.id
        apply(entry)
    }

    public func apply(_ entry: MealPlanEntry) {
        day = entry.day
        slotRaw = entry.slot.rawValue
        recipeID = entry.recipeID
        servings = entry.servings
        sortOrder = entry.sortOrder
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
        deletedAt = entry.deletedAt
    }

    public var domainValue: MealPlanEntry {
        MealPlanEntry(
            id: id,
            day: day,
            slot: MealSlot(rawValue: slotRaw) ?? .dinner,
            recipeID: recipeID,
            servings: servings,
            sortOrder: sortOrder,
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }
}
