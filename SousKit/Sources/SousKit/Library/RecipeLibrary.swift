import Foundation
import Observation

/// The view-facing state of the recipe collection.
///
/// Holds the current filter, reloads when it changes, and forwards writes to
/// the store. Views never touch the store directly, so swapping persistence
/// or adding sync later stays invisible to them.
@MainActor
@Observable
public final class RecipeLibrary {
    public enum Filter: Hashable, CaseIterable, Sendable {
        case all
        case favorites
        case wantToCook

        public var title: String {
            switch self {
            case .all: "Alle"
            case .favorites: "Favoriten"
            case .wantToCook: "Will ich kochen"
            }
        }
    }

    private let store: any RecipeStore
    private let imageStore: any RecipeImageStore

    public private(set) var recipes: [Recipe] = []
    public private(set) var categories: [String] = []
    public private(set) var isLoading = false
    public var errorMessage: String?

    /// A recipe being created or edited, presented as a sheet when set.
    public var editing: Recipe?

    public var searchText = "" { didSet { scheduleReload(if: oldValue != searchText) } }
    public var filter: Filter = .all { didSet { scheduleReload(if: oldValue != filter) } }
    /// Ingredients and categories recognized in what was typed, applied as
    /// filters rather than as words.
    public private(set) var activeFilters: [RecipeFilter] = []

    private var reloadTask: Task<Void, Never>?

    public init(store: any RecipeStore, imageStore: any RecipeImageStore) {
        self.store = store
        self.imageStore = imageStore
    }

    // MARK: - Images

    public func thumbnail(id: UUID) async -> Data? {
        try? await imageStore.thumbnail(id: id)
    }

    public func image(id: UUID) async -> Data? {
        try? await imageStore.image(id: id)
    }

    public func deleteImage(id: UUID) async {
        do {
            try await imageStore.delete(id: id)
        } catch {
            report(error)
        }
    }

    /// Stores a picked photo and returns its id, or `nil` if it could not be
    /// read as an image.
    public func addImage(_ data: Data, to recipeID: UUID) async -> UUID? {
        do {
            return try await imageStore.add(data, to: recipeID)
        } catch {
            report(error)
            return nil
        }
    }

    public var query: RecipeQuery {
        RecipeQuery(
            searchText: searchText.isEmpty ? nil : searchText,
            filters: activeFilters,
            onlyFavorites: filter == .favorites,
            onlyWantToCook: filter == .wantToCook
        )
    }

    /// Filters the typed text could become, given what the app knows.
    public func filterSuggestions(catalog: IngredientCatalog) -> [RecipeFilter] {
        RecipeFilter.suggestions(
            for: searchText,
            catalog: catalog,
            categories: categories,
            applied: activeFilters
        )
    }

    /// Turns the typed text into a filter and clears the field, the way a
    /// chip replaces what was typed.
    public func apply(_ filter: RecipeFilter) async {
        guard !activeFilters.contains(filter) else { return }
        activeFilters.append(filter)
        searchText = ""
        await reload()
    }

    public func remove(_ filter: RecipeFilter) async {
        activeFilters.removeAll { $0 == filter }
        await reload()
    }

    public func clearFilters() async {
        activeFilters = []
        searchText = ""
        await reload()
    }

    public func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            recipes = try await store.recipes(matching: query)
            categories = try await store.categories()
        } catch {
            report(error)
        }
    }

    /// Loads a single recipe regardless of the current filter — a link may
    /// point at something the list is not showing.
    public func recipe(id: UUID) async -> Recipe? {
        do {
            return try await store.recipe(id: id)
        } catch {
            report(error)
            return nil
        }
    }

    /// Searches the whole library, independent of the current filter. Used by
    /// the picker that inserts a link to another recipe.
    public func findRecipes(matching text: String) async -> [Recipe] {
        do {
            return try await store.recipes(
                matching: RecipeQuery(searchText: text.isEmpty ? nil : text)
            )
        } catch {
            report(error)
            return []
        }
    }

    public func save(_ recipe: Recipe) async {
        do {
            try await store.save(recipe)
            // Pictures dropped in the editor lose their blob here, rather
            // than lingering as orphans nothing references.
            try await imageStore.deleteImages(ofRecipe: recipe.id, notIn: recipe.imageIDs)
            await reload()
        } catch {
            report(error)
        }
    }

    public func delete(_ recipe: Recipe) async {
        do {
            try await store.delete(id: recipe.id)
            await reload()
        } catch {
            report(error)
        }
    }

    public func toggleFavorite(_ recipe: Recipe) async {
        var updated = recipe
        updated.isFavorite.toggle()
        await save(updated)
    }

    public func toggleWantToCook(_ recipe: Recipe) async {
        var updated = recipe
        updated.wantToCook.toggle()
        await save(updated)
    }

    public func startNewRecipe() {
        editing = Recipe(title: "")
    }

    private func scheduleReload(if changed: Bool) {
        guard changed else { return }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            // Typing in the search field should not fire a query per keystroke.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    private func report(_ error: any Error) {
        errorMessage = error.localizedDescription
    }
}
