import Foundation
import SwiftData

/// Storage for the ingredients the cook added themselves.
public protocol IngredientCatalogStore: Sendable {
    func ingredients() async throws -> [CatalogIngredient]
    func save(_ ingredient: CatalogIngredient) async throws
    /// Removes an entry by its key. Bundled entries are unaffected — they do
    /// not live here.
    func delete(key: String) async throws
}

/// An ``IngredientCatalogStore`` backed by SwiftData.
@ModelActor
public actor SwiftDataIngredientCatalogStore: IngredientCatalogStore {
    public func ingredients() async throws -> [CatalogIngredient] {
        var descriptor = FetchDescriptor<StoredCatalogIngredient>()
        descriptor.sortBy = [SortDescriptor(\.name)]
        return try modelContext.fetch(descriptor).map(\.domainValue)
    }

    public func save(_ ingredient: CatalogIngredient) async throws {
        if let existing = try stored(key: ingredient.key) {
            existing.apply(ingredient)
        } else {
            modelContext.insert(StoredCatalogIngredient(ingredient))
        }
        try modelContext.save()
    }

    public func delete(key: String) async throws {
        guard let existing = try stored(key: key) else { return }
        modelContext.delete(existing)
        try modelContext.save()
    }

    private func stored(key: String) throws -> StoredCatalogIngredient? {
        var descriptor = FetchDescriptor<StoredCatalogIngredient>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
