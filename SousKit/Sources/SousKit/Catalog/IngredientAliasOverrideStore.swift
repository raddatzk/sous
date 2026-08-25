import Foundation
import SwiftData

/// Storage for the extra spellings the cook taught existing ingredients.
public protocol IngredientAliasOverrideStore: Sendable {
    /// Every added alias, grouped by the key of the ingredient it belongs to.
    func overridesByKey() async throws -> [String: [String]]
    func addAlias(_ alias: String, toKey key: String) async throws
    func removeAlias(_ alias: String, fromKey key: String) async throws
}

/// An ``IngredientAliasOverrideStore`` backed by SwiftData.
@ModelActor
public actor SwiftDataIngredientAliasOverrideStore: IngredientAliasOverrideStore {
    public func overridesByKey() async throws -> [String: [String]] {
        var descriptor = FetchDescriptor<StoredIngredientAliasOverride>()
        descriptor.sortBy = [SortDescriptor(\.createdAt)]
        return try modelContext.fetch(descriptor).reduce(into: [:]) { result, row in
            result[row.canonicalKey, default: []].append(row.alias)
        }
    }

    public func addAlias(_ alias: String, toKey key: String) async throws {
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !alias.isEmpty else { return }
        // The same spelling twice would only widen the alias list without
        // changing what it resolves to.
        guard try stored(alias: alias, key: key) == nil else { return }
        modelContext.insert(StoredIngredientAliasOverride(canonicalKey: key, alias: alias))
        try modelContext.save()
    }

    public func removeAlias(_ alias: String, fromKey key: String) async throws {
        guard let existing = try stored(alias: alias, key: key) else { return }
        modelContext.delete(existing)
        try modelContext.save()
    }

    /// Matched on the normalized form, so "Schmelzkäse" does not end up
    /// stored twice next to "schmelzkäse".
    private func stored(alias: String, key: String) throws -> StoredIngredientAliasOverride? {
        let normalized = IngredientCatalog.normalize(alias)
        var descriptor = FetchDescriptor<StoredIngredientAliasOverride>(
            predicate: #Predicate { $0.canonicalKey == key }
        )
        descriptor.sortBy = [SortDescriptor(\.createdAt)]
        return try modelContext.fetch(descriptor)
            .first { IngredientCatalog.normalize($0.alias) == normalized }
    }
}
