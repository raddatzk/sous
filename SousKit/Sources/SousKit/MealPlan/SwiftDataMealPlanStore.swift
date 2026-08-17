import Foundation
import SwiftData

/// A ``MealPlanStore`` backed by SwiftData.
@ModelActor
public actor SwiftDataMealPlanStore: MealPlanStore {
    public func entries(for days: [Date]) async throws -> [MealPlanEntry] {
        guard let first = days.min(), let last = days.max() else { return [] }

        var descriptor = FetchDescriptor<StoredMealPlanEntry>(
            predicate: #Predicate { $0.deletedAt == nil && $0.day >= first && $0.day <= last }
        )
        descriptor.sortBy = [
            SortDescriptor(\.day), SortDescriptor(\.slotRaw), SortDescriptor(\.sortOrder),
        ]
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
