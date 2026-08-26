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
    /// Removes the row itself, tombstone and all.
    ///
    /// Emptying the trash is the only thing that does this. Once recipes
    /// sync, a deletion has to stay visible to the other devices, so this
    /// will become "keep the tombstone, drop the contents" rather than
    /// disappearing a row another device still expects to hear about.
    func erase(id: UUID) async throws
    func categories() async throws -> [String]
    /// Rebuilds every row's denormalized `searchText` and `ingredientKeys`
    /// from its stored content.
    ///
    /// Both are written at save time and then never revisited, so they go
    /// stale the moment the *reading* of unchanged text changes — a new
    /// unit word, a variety gaining a parent in the shipped catalog. Run
    /// when the bundled data changes hands, the same trigger the orphan
    /// reconciliation answers to.
    func reindexSearch(catalog: IngredientCatalog) async throws
    /// Categories with how many recipes use each — for managing them.
    func categoryCounts() async throws -> [(name: String, count: Int)]
    /// Renames a category across every recipe. Renaming onto an existing
    /// name merges the two.
    func renameCategory(_ name: String, to newName: String) async throws
    /// Removes a category from every recipe that carries it.
    func deleteCategory(_ name: String) async throws

    // MARK: - Variant groups

    /// Every variant group, with how many of its members are not in the
    /// trash.
    ///
    /// The count comes along because it decides whether a group is a group
    /// at all: one left standing draws as an ordinary recipe. It cannot be
    /// read off the list — a filter may have passed a single member of five,
    /// and that hit still deserves its group's row as context around it.
    func variantGroups() async throws -> [(group: VariantGroup, liveMembers: Int)]
    func variantGroup(id: UUID) async throws -> VariantGroup?
    /// A group's members that are not in the trash, in the order they were
    /// created — which is the only order a symmetric group has.
    func variantGroupMembers(id: UUID) async throws -> [Recipe]
    /// Inserts or overwrites. Renaming a group rewrites its members'
    /// denormalized `searchText`, which is why this is a store call rather
    /// than a plain save.
    @discardableResult
    func saveVariantGroup(_ group: VariantGroup) async throws -> VariantGroup
    /// Takes one recipe out of its group, leaving the others in it.
    ///
    /// The counterpart to joining, and the reason joining is not a one-way
    /// door. A group left with nothing to compare goes with it.
    func removeFromVariantGroup(recipeID: UUID) async throws
    /// Takes the group apart: every member's `variantGroupID` is cleared and
    /// the group's own row goes.
    ///
    /// No tombstone. A group is not something the trash holds, and a member
    /// left pointing at a row that is gone reads as ungrouped — the failure
    /// heals itself rather than needing to sync.
    func dissolveVariantGroup(id: UUID) async throws
}
