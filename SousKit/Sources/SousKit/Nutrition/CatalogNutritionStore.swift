import Foundation
import SwiftData

/// Storage for the nutrition a cook entered themselves — a delta over the
/// bundled BLS table, which ships with the app and is never written to.
public protocol CatalogNutritionStore: Sendable {
    func all() async throws -> [CatalogNutrition]
    func save(_ nutrition: CatalogNutrition) async throws
    func delete(canonicalName: String) async throws
}

/// A ``CatalogNutritionStore`` backed by SwiftData.
@ModelActor
public actor SwiftDataCatalogNutritionStore: CatalogNutritionStore {
    public func all() async throws -> [CatalogNutrition] {
        var descriptor = FetchDescriptor<StoredCatalogNutrition>()
        descriptor.sortBy = [SortDescriptor(\.name)]
        return try modelContext.fetch(descriptor).map(\.domainValue)
    }

    public func save(_ nutrition: CatalogNutrition) async throws {
        if let existing = try stored(key: IngredientCatalog.normalize(nutrition.name)) {
            existing.apply(nutrition)
        } else {
            modelContext.insert(StoredCatalogNutrition(nutrition))
        }
        try modelContext.save()
    }

    public func delete(canonicalName: String) async throws {
        guard let existing = try stored(key: IngredientCatalog.normalize(canonicalName)) else { return }
        modelContext.delete(existing)
        try modelContext.save()
    }

    private func stored(key: String) throws -> StoredCatalogNutrition? {
        var descriptor = FetchDescriptor<StoredCatalogNutrition>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
