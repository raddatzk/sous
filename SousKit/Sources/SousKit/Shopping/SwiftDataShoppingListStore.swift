import Foundation
import SwiftData

/// A ``ShoppingListStore`` backed by SwiftData.
@ModelActor
public actor SwiftDataShoppingListStore: ShoppingListStore {
    public func checkedKeys() async throws -> Set<String> {
        let descriptor = FetchDescriptor<StoredShoppingEntry>(predicate: #Predicate { $0.isChecked })
        return Set(try modelContext.fetch(descriptor).map(\.key))
    }

    public func setChecked(_ checked: Bool, key: String) async throws {
        if let existing = try entry(key: key) {
            existing.isChecked = checked
            existing.updatedAt = .nowInSyncPrecision
            // A tick on a generated line is all we stored about it; without
            // the tick there is nothing left worth keeping.
            if !checked, !existing.isManual {
                modelContext.delete(existing)
            }
        } else if checked {
            modelContext.insert(StoredShoppingEntry(key: key, name: key, isChecked: true))
        }
        try modelContext.save()
    }

    public func manualItems() async throws -> [ShoppingItem] {
        var descriptor = FetchDescriptor<StoredShoppingEntry>(predicate: #Predicate { $0.isManual })
        descriptor.sortBy = [SortDescriptor(\.updatedAt)]
        return try modelContext.fetch(descriptor).map(\.domainValue)
    }

    public func addManualItem(name: String, quantity: Quantity?) async throws {
        let key = ShoppingItem.key(for: name)
        guard !key.isEmpty else { return }

        if let existing = try entry(key: key) {
            existing.isManual = true
            existing.name = name
            existing.amount = quantity?.amount
            existing.unitSymbol = quantity?.unit.symbol
            existing.updatedAt = .nowInSyncPrecision
        } else {
            modelContext.insert(StoredShoppingEntry(
                key: key,
                name: name,
                amount: quantity?.amount,
                unitSymbol: quantity?.unit.symbol,
                isManual: true
            ))
        }
        try modelContext.save()
    }

    public func removeManualItem(key: String) async throws {
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

    private func entry(key: String) throws -> StoredShoppingEntry? {
        var descriptor = FetchDescriptor<StoredShoppingEntry>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
