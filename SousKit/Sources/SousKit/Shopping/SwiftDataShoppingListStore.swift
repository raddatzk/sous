import Foundation
import SwiftData

/// A ``ShoppingListStore`` backed by SwiftData.
@ModelActor
public actor SwiftDataShoppingListStore: ShoppingListStore {
    public func items() async throws -> [ShoppingItem] {
        var descriptor = FetchDescriptor<StoredShoppingEntry>()
        descriptor.sortBy = [SortDescriptor(\.sortOrder)]
        return try modelContext.fetch(descriptor).map(\.domainValue)
    }

    public func add(_ items: [ShoppingItem]) async throws {
        var position = try nextSortOrder()

        for item in items {
            guard !item.key.isEmpty else { continue }

            if let existing = try entry(key: item.key) {
                // Already on the list: fold the amounts together and note
                // which recipe else asked for it.
                var merged = existing.domainValue
                // Both kinds of contribution fold into their own place, and
                // the total follows from them.
                for source in item.sources {
                    if let index = merged.sources.firstIndex(where: { $0.recipeTitle == source.recipeTitle }) {
                        merged.sources[index].quantities = merged.sources[index].quantities
                            .adding(source.quantities)
                    } else {
                        merged.sources.append(source)
                    }
                }
                merged.manualQuantities = merged.manualQuantities.adding(item.manualQuantities)
                // Adding something again means it is wanted again.
                merged.isChecked = false
                existing.apply(merged)
            } else {
                let entry = StoredShoppingEntry(item)
                entry.sortOrder = position
                position += 1
                modelContext.insert(entry)
            }
        }
        try modelContext.save()
    }

    public func setChecked(_ checked: Bool, key: String) async throws {
        guard let existing = try entry(key: key) else { return }
        existing.isChecked = checked
        existing.updatedAt = .nowInSyncPrecision
        try modelContext.save()
    }

    public func remove(key: String) async throws {
        guard let existing = try entry(key: key) else { return }
        modelContext.delete(existing)
        try modelContext.save()
    }

    public func clearChecked() async throws {
        let descriptor = FetchDescriptor<StoredShoppingEntry>(predicate: #Predicate { $0.isChecked })
        for entry in try modelContext.fetch(descriptor) {
            modelContext.delete(entry)
        }
        try modelContext.save()
    }

    private func nextSortOrder() throws -> Int {
        var descriptor = FetchDescriptor<StoredShoppingEntry>()
        descriptor.sortBy = [SortDescriptor(\.sortOrder, order: .reverse)]
        descriptor.fetchLimit = 1
        return (try modelContext.fetch(descriptor).first?.sortOrder ?? -1) + 1
    }

    private func entry(key: String) throws -> StoredShoppingEntry? {
        var descriptor = FetchDescriptor<StoredShoppingEntry>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
