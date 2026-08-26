import Foundation
import SwiftData

/// An ingredient the cook added to the catalog themselves.
///
/// **Legacy.** Folded into ``StoredIngredientVocabulary`` by
/// ``SwiftDataVocabularyMigration`` and deleted there. It stays in the
/// schema because a store written before phase 4 still holds these rows,
/// and the migration has to be able to read them.
///
/// Stored separately from the bundled list rather than as a copy of it: the
/// bundled catalog ships with the app and is replaced on every update, while
/// these belong to the user and must survive that.
@Model
public final class StoredCatalogIngredient {
    #Index<StoredCatalogIngredient>([\.key])

    /// The normalized name, matching ``CatalogIngredient/key``.
    public var key: String = ""
    public var name: String = ""
    public var aliases: [String] = []
    public var categoryRaw: String = IngredientCategory.other.rawValue
    public var createdAt: Date = Date.nowInSyncPrecision
    public var updatedAt: Date = Date.nowInSyncPrecision

    public init(_ ingredient: CatalogIngredient) {
        key = ingredient.key
        apply(ingredient)
    }

    public func apply(_ ingredient: CatalogIngredient) {
        name = ingredient.name
        aliases = ingredient.aliases
        categoryRaw = ingredient.category.rawValue
        updatedAt = .nowInSyncPrecision
    }

    public var domainValue: CatalogIngredient {
        CatalogIngredient(
            name: name,
            aliases: aliases,
            category: IngredientCategory(rawValue: categoryRaw) ?? .other
        )
    }
}
