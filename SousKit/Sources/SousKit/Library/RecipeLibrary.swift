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

    public private(set) var recipes: [Recipe] = []
    public private(set) var categories: [String] = []
    public private(set) var isLoading = false
    public var errorMessage: String?

    /// A recipe being created or edited, presented as a sheet when set.
    public var editing: Recipe?

    public var searchText = "" { didSet { scheduleReload(if: oldValue != searchText) } }
    public var filter: Filter = .all { didSet { scheduleReload(if: oldValue != filter) } }
    public var selectedCategory: String? { didSet { scheduleReload(if: oldValue != selectedCategory) } }

    private var reloadTask: Task<Void, Never>?

    public init(store: any RecipeStore) {
        self.store = store
    }

    public var query: RecipeQuery {
        RecipeQuery(
            searchText: searchText.isEmpty ? nil : searchText,
            category: selectedCategory,
            onlyFavorites: filter == .favorites,
            onlyWantToCook: filter == .wantToCook
        )
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

    public func save(_ recipe: Recipe) async {
        do {
            try await store.save(recipe)
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
