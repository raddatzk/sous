import Foundation

/// What to fetch from a ``RecipeStore``.
///
/// A query object rather than a method per filter, so that adding a filter
/// does not widen the protocol every time.
public struct RecipeQuery: Sendable, Hashable {
    public enum Sort: Sendable, Hashable {
        case titleAscending
        case recentlyUpdated
    }

    /// Matched against title, categories and ingredient names.
    public var searchText: String?
    /// Recognized filters, all of which must apply.
    public var filters: [RecipeFilter]
    public var onlyFavorites: Bool
    public var onlyWantToCook: Bool
    /// Tombstoned recipes are excluded unless asked for.
    public var includeDeleted: Bool
    public var sort: Sort

    public init(
        searchText: String? = nil,
        filters: [RecipeFilter] = [],
        onlyFavorites: Bool = false,
        onlyWantToCook: Bool = false,
        includeDeleted: Bool = false,
        sort: Sort = .titleAscending
    ) {
        self.searchText = searchText
        self.filters = filters
        self.onlyFavorites = onlyFavorites
        self.onlyWantToCook = onlyWantToCook
        self.includeDeleted = includeDeleted
        self.sort = sort
    }

    public static let all = RecipeQuery()
}

/// Storage for recipes.
///
/// The protocol trades only in domain values, which keeps the persistence
/// framework — and later the sync layer — replaceable without touching
/// anything above it.
public protocol RecipeStore: Sendable {
    func recipes(matching query: RecipeQuery) async throws -> [Recipe]
    func recipe(id: UUID) async throws -> Recipe?
    /// Inserts or overwrites, returning the recipe as stored — its
    /// `updatedAt` is set by the store, never by the caller.
    @discardableResult
    func save(_ recipe: Recipe) async throws -> Recipe
    /// Tombstones the recipe. The content is kept so the deletion can sync
    /// and be undone.
    func delete(id: UUID) async throws
    func restore(id: UUID) async throws
    func categories() async throws -> [String]
    /// Categories with how many recipes use each — for managing them.
    func categoryCounts() async throws -> [(name: String, count: Int)]
    /// Renames a category across every recipe. Renaming onto an existing
    /// name merges the two.
    func renameCategory(_ name: String, to newName: String) async throws
    /// Removes a category from every recipe that carries it.
    func deleteCategory(_ name: String) async throws
}
