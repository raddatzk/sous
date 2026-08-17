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
    public var category: String?
    public var onlyFavorites: Bool
    public var onlyWantToCook: Bool
    /// Tombstoned recipes are excluded unless asked for.
    public var includeDeleted: Bool
    /// Sub-recipes are hidden from the library, since they are reached
    /// through the recipe that uses them. Searching includes them, because
    /// someone looking for "Tortellini" by name should find it.
    public var includeComponents: Bool
    public var sort: Sort

    public init(
        searchText: String? = nil,
        category: String? = nil,
        onlyFavorites: Bool = false,
        onlyWantToCook: Bool = false,
        includeDeleted: Bool = false,
        includeComponents: Bool = false,
        sort: Sort = .titleAscending
    ) {
        self.searchText = searchText
        self.category = category
        self.onlyFavorites = onlyFavorites
        self.onlyWantToCook = onlyWantToCook
        self.includeDeleted = includeDeleted
        self.includeComponents = includeComponents
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
}
