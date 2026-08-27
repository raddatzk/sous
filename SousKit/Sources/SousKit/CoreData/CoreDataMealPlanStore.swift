import CoreData
import Foundation

/// The Core Data form of a plan entry — the counterpart to
/// ``StoredMealPlanEntry``.
@objc(CDMealPlanEntry)
final class CDMealPlanEntry: CDHouseholdMember {
    @NSManaged var id: UUID?
    @NSManaged var day: Date?
    @NSManaged var slotRaw: String
    @NSManaged var recipeID: UUID?
    @NSManaged var servings: NSNumber?
    @NSManaged var sortOrder: Int64
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
    @NSManaged var deletedAt: Date?

    func apply(_ entry: MealPlanEntry) {
        id = entry.id
        day = entry.day
        slotRaw = entry.slot.rawValue
        recipeID = entry.recipeID
        servings = entry.servings.map(NSNumber.init)
        sortOrder = Int64(entry.sortOrder)
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
        deletedAt = entry.deletedAt
    }

    /// `nil` for a row missing either id — an entry that names no recipe is
    /// not a plan for anything.
    var domainValue: MealPlanEntry? {
        guard let id, let recipeID else { return nil }
        return MealPlanEntry(
            id: id,
            day: day,
            slot: MealSlot(rawValue: slotRaw) ?? .dinner,
            recipeID: recipeID,
            servings: servings?.intValue,
            sortOrder: Int(sortOrder),
            createdAt: createdAt ?? .distantPast,
            updatedAt: updatedAt ?? .distantPast,
            deletedAt: deletedAt
        )
    }
}

/// A ``MealPlanStore`` backed by Core Data.
public final class CoreDataMealPlanStore: MealPlanStore, @unchecked Sendable {
    private let context: NSManagedObjectContext

    public init(container: NSPersistentContainer) {
        context = SousPersistentContainer.backgroundContext(for: container)
    }

    public func entries(for days: [Date]) async throws -> [MealPlanEntry] {
        guard let first = days.min(), let last = days.max() else { return [] }

        return try await context.perform {
            let request = CDMealPlanEntry.fetchRequest()
            // `day != nil` says plainly what the SwiftData version had to
            // express by coalescing a missing day to a date outside every
            // window: the pool is not part of any range.
            request.predicate = NSPredicate(
                format: "deletedAt == nil AND day != nil AND day >= %@ AND day <= %@",
                first as NSDate, last as NSDate
            )
            request.sortDescriptors = [
                NSSortDescriptor(key: "day", ascending: true),
                NSSortDescriptor(key: "slotRaw", ascending: true),
                NSSortDescriptor(key: "sortOrder", ascending: true),
            ]
            return try self.context.fetch(request).compactMap(\.domainValue)
        }
    }

    public func poolEntries() async throws -> [MealPlanEntry] {
        try await context.perform {
            let request = CDMealPlanEntry.fetchRequest()
            request.predicate = NSPredicate(format: "deletedAt == nil AND day == nil")
            request.sortDescriptors = [
                NSSortDescriptor(key: "sortOrder", ascending: true),
                NSSortDescriptor(key: "createdAt", ascending: true),
            ]
            return try self.context.fetch(request).compactMap(\.domainValue)
        }
    }

    @discardableResult
    public func save(_ entry: MealPlanEntry) async throws -> MealPlanEntry {
        var updated = entry
        updated.updatedAt = .nowInSyncPrecision

        try await context.perform {
            let row = try self.stored(id: entry.id) ?? CDMealPlanEntry(context: self.context)
            row.apply(updated)
            try self.context.save()
        }
        return updated
    }

    public func delete(id: UUID) async throws {
        try await context.perform {
            guard let existing = try self.stored(id: id) else { return }
            let now = Date.nowInSyncPrecision
            existing.deletedAt = now
            existing.updatedAt = now
            try self.context.save()
        }
    }

    /// Writes an entry as it stands, timestamps and all. See
    /// `CoreDataRecipeStore.adopt(_:)`.
    public func adopt(_ entry: MealPlanEntry) async throws {
        try await context.perform {
            let row = try self.stored(id: entry.id) ?? CDMealPlanEntry(context: self.context)
            row.apply(entry)
            try self.context.save()
        }
    }

    private func stored(id: UUID) throws -> CDMealPlanEntry? {
        let request = CDMealPlanEntry.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }
}

extension CDMealPlanEntry {
    static func fetchRequest() -> NSFetchRequest<CDMealPlanEntry> {
        NSFetchRequest<CDMealPlanEntry>(entityName: SousManagedObjectModel.mealPlanEntryEntityName)
    }
}
