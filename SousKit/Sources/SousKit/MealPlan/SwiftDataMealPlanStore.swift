import Foundation
import SwiftData

/// A ``MealPlanStore`` backed by SwiftData.
@ModelActor
public actor SwiftDataMealPlanStore: MealPlanStore {
    public func entries(for days: [Date]) async throws -> [MealPlanEntry] {
        guard let first = days.min(), let last = days.max() else { return [] }

        // A pool entry has no day, and the coalesced dates put it outside
        // any window rather than making the query lie about it.
        let before = Date.distantPast
        let after = Date.distantFuture
        var descriptor = FetchDescriptor<StoredMealPlanEntry>(
            predicate: #Predicate {
                $0.deletedAt == nil
                    && ($0.day ?? before) >= first
                    && ($0.day ?? after) <= last
            }
        )
        descriptor.sortBy = [
            SortDescriptor(\.day), SortDescriptor(\.slotRaw), SortDescriptor(\.sortOrder),
        ]
        return try modelContext.fetch(descriptor).map(\.domainValue)
    }

    public func poolEntries() async throws -> [MealPlanEntry] {
        var descriptor = FetchDescriptor<StoredMealPlanEntry>(
            predicate: #Predicate { $0.deletedAt == nil && $0.day == nil }
        )
        descriptor.sortBy = [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)]
        return try modelContext.fetch(descriptor).map(\.domainValue)
    }

    @discardableResult
    public func save(_ entry: MealPlanEntry) async throws -> MealPlanEntry {
        var updated = entry
        updated.updatedAt = .nowInSyncPrecision

        if let existing = try stored(id: entry.id) {
            existing.apply(updated)
        } else {
            modelContext.insert(StoredMealPlanEntry(updated))
        }
        try modelContext.save()
        return updated
    }

    public func delete(id: UUID) async throws {
        guard let existing = try stored(id: id) else { return }
        let now = Date.nowInSyncPrecision
        existing.deletedAt = now
        existing.updatedAt = now
        try modelContext.save()
    }

    private func stored(id: UUID) throws -> StoredMealPlanEntry? {
        var descriptor = FetchDescriptor<StoredMealPlanEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
