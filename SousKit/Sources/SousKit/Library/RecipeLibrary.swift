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

    /// How far a running import has got. `nil` when none is running.
    public private(set) var importProgress: RecipeImportProgress?
    /// The same for an export, which on a full library is the slower of the
    /// two — every picture is read back at full size.
    public private(set) var exportProgress: RecipeImportProgress?

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
    ///
    /// Eight rather than a handful: the row scrolls sideways anyway, and a
    /// close match falling off the end is worse than a long row.
    public func filterSuggestions(catalog: IngredientCatalog) -> [RecipeFilter] {
        RecipeFilter.suggestions(
            for: searchText,
            catalog: catalog,
            categories: categories,
            applied: activeFilters,
            limit: 8
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

    /// Records that a recipe was cooked through to its last step.
    ///
    /// Cooking consumes the "want to cook" mark: it was a note to try this,
    /// and it has now been tried. Planning deliberately does not — a plan can
    /// be rearranged, and a wish the cook never got round to should stay on
    /// the list.
    public func markCooked(_ recipe: Recipe) async {
        // Cook mode may have been open for an hour. What matters is the
        // recipe as it stands now, not the copy it was opened with.
        guard var current = await self.recipe(id: recipe.id), current.wantToCook else { return }
        current.wantToCook = false
        await save(current)
    }

    public func toggleWantToCook(_ recipe: Recipe) async {
        var updated = recipe
        updated.wantToCook.toggle()
        await save(updated)
    }

    // MARK: - Categories

    /// Categories with how many recipes use each.
    public func categoryCounts() async -> [(name: String, count: Int)] {
        do {
            return try await store.categoryCounts()
        } catch {
            report(error)
            return []
        }
    }

    public func renameCategory(_ name: String, to newName: String) async {
        do {
            try await store.renameCategory(name, to: newName)
            await reload()
        } catch {
            report(error)
        }
    }

    public func deleteCategory(_ name: String) async {
        do {
            try await store.deleteCategory(name)
            // A category being filtered on has just stopped existing.
            activeFilters.removeAll { $0.kind == .category && $0.key == name.lowercased() }
            await reload()
        } catch {
            report(error)
        }
    }

    // MARK: - Trash

    /// Recipes that were deleted and are still recoverable, most recently
    /// deleted first.
    public func deletedRecipes() async -> [Recipe] {
        do {
            return try await store.recipes(matching: RecipeQuery(includeDeleted: true))
                .filter(\.isDeleted)
                .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        } catch {
            report(error)
            return []
        }
    }

    /// Puts a deleted recipe back into the collection.
    public func restore(_ recipe: Recipe) async {
        do {
            try await store.restore(id: recipe.id)
            await reload()
        } catch {
            report(error)
        }
    }

    /// Removes a recipe for good, pictures included.
    public func erase(_ recipe: Recipe) async {
        do {
            try await imageStore.deleteImages(ofRecipe: recipe.id, notIn: [])
            try await store.erase(id: recipe.id)
        } catch {
            report(error)
        }
    }

    /// Empties the trash. Returns how many recipes it held.
    @discardableResult
    public func emptyTrash() async -> Int {
        let deleted = await deletedRecipes()
        for recipe in deleted {
            await erase(recipe)
        }
        return deleted.count
    }

    // MARK: - Import

    /// Reads a recipe file and stores everything in it.
    ///
    /// Recipes are saved one at a time rather than as a batch: a library of a
    /// few hundred with their photos takes long enough that the user should
    /// see it filling up, and a single recipe the file got wrong should not
    /// roll back the ones that were fine.
    public func importRecipes(from data: Data, named name: String) async -> RecipeImportSummary {
        importProgress = RecipeImportProgress(done: 0, total: 0)
        defer { importProgress = nil }

        let batch: RecipeImportBatch
        do {
            // Decoding an archive with its photos is seconds of work, and it
            // has no business happening on the main actor.
            batch = try await Task.detached { try RecipeImport.read(data, named: name) }.value
        } catch {
            errorMessage = error.localizedDescription
            return RecipeImportSummary(
                imported: 0,
                problems: [RecipeImportProblem(name: name, reason: error.localizedDescription)]
            )
        }

        var problems = batch.problems
        var imported = 0
        importProgress = RecipeImportProgress(done: 0, total: batch.recipes.count)

        for item in batch.recipes {
            do {
                try await save(imported: item)
                imported += 1
            } catch {
                problems.append(
                    RecipeImportProblem(
                        name: item.recipe.title,
                        reason: error.localizedDescription
                    )
                )
            }
            importProgress = RecipeImportProgress(done: imported, total: batch.recipes.count)
        }

        await reload()
        return RecipeImportSummary(imported: imported, problems: problems)
    }

    /// Saves one imported recipe together with its pictures.
    ///
    /// The recipe is written first without images, because a picture is
    /// stored against a recipe id; the ids that come back are then written
    /// onto the recipe. Re-importing the same file overwrites both, since the
    /// recipe keeps the id derived from its origin.
    private func save(imported item: ImportedRecipe) async throws {
        var recipe = item.recipe
        recipe.imageIDs = []
        try await store.save(recipe)

        var ids: [UUID] = []
        for image in item.images {
            // A picture that will not decode is not worth failing over —
            // the recipe is the part that matters.
            if let id = try? await imageStore.add(image, to: recipe.id) {
                ids.append(id)
            }
        }
        if !ids.isEmpty {
            recipe.imageIDs = ids
            try await store.save(recipe)
        }
        try await imageStore.deleteImages(ofRecipe: recipe.id, notIn: ids)
    }

    // MARK: - Export

    /// One recipe as a `.melarecipe` file, pictures included.
    public func exportedRecipe(_ recipe: Recipe) async -> Data? {
        do {
            return try MelaExport.recipe(recipe, images: await images(of: recipe))
        } catch {
            report(error)
            return nil
        }
    }

    /// The whole collection as a `.melarecipes` archive.
    ///
    /// Everything, not what the filter happens to show: an export is a copy
    /// of the library, and a copy that quietly left out half of it would be
    /// worse than none.
    public func exportedLibrary() async -> Data? {
        exportProgress = RecipeImportProgress(done: 0, total: 0)
        defer { exportProgress = nil }

        do {
            let recipes = try await store.recipes(matching: .all)
            exportProgress = RecipeImportProgress(done: 0, total: recipes.count)

            var items: [(recipe: Recipe, images: [Data])] = []
            for recipe in recipes {
                items.append((recipe, await images(of: recipe)))
                exportProgress = RecipeImportProgress(done: items.count, total: recipes.count)
            }
            // Writing the archive is pure computation over data already in
            // hand, and has no business on the main actor.
            return try await Task.detached { try MelaExport.library(items) }.value
        } catch {
            report(error)
            return nil
        }
    }

    /// Full-size pictures in the order the recipe lists them.
    private func images(of recipe: Recipe) async -> [Data] {
        var images: [Data] = []
        for id in recipe.imageIDs {
            if let data = try? await imageStore.image(id: id) {
                images.append(data)
            }
        }
        return images
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
