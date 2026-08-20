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

    /// One AI enrichment finishing — see `lastEnrichment`.
    public struct EnrichmentEvent: Equatable, Sendable {
        public let recipeID: UUID
        let generation: Int
    }

    private let store: any RecipeStore
    private let imageStore: any RecipeImageStore
    private let enrichmentStore: any RecipeEnrichmentStore
    private let amountReviewStore: any RecipeAmountReviewStore

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

    /// The most recent recipe an AI enrichment finished for, so a view
    /// already open on that recipe can notice without polling — see
    /// `scheduleEnrichment(for:)`. Distinct on every completion, even a
    /// second one for the same recipe, which is why this carries a
    /// generation rather than being a plain `UUID?`: setting the exact
    /// same value twice would not trigger `.onChange` a second time.
    public private(set) var lastEnrichment: EnrichmentEvent?
    private var enrichmentGeneration = 0

    public var searchText = "" { didSet { scheduleReload(if: oldValue != searchText) } }
    public var filter: Filter = .all { didSet { scheduleReload(if: oldValue != filter) } }
    /// Ingredients and categories recognized in what was typed, applied as
    /// filters rather than as words.
    public private(set) var activeFilters: [RecipeFilter] = []

    private var reloadTask: Task<Void, Never>?

    public init(
        store: any RecipeStore,
        imageStore: any RecipeImageStore,
        enrichmentStore: any RecipeEnrichmentStore,
        amountReviewStore: any RecipeAmountReviewStore
    ) {
        self.store = store
        self.imageStore = imageStore
        self.enrichmentStore = enrichmentStore
        self.amountReviewStore = amountReviewStore
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

    /// Replaces the whole set at once.
    ///
    /// For the search field's tokens: the system hands back the list it has
    /// after the reader deleted one with the backspace key, rather than
    /// telling us which one went. Nothing is done unless it actually changed,
    /// so that a redraw does not cost a query.
    public func setFilters(_ filters: [RecipeFilter]) async {
        guard filters != activeFilters else { return }
        activeFilters = filters
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
            scheduleEnrichment(for: recipe)
        } catch {
            report(error)
        }
    }

    // MARK: - AI mentions

    /// What `AmountAIExtractor` found the last time it ran, if the recipe's
    /// ingredients and instructions haven't changed since — a plain cache
    /// read, never a model call, so a view can call this from `.task`
    /// without worrying about cost.
    public func aiMentions(for recipe: Recipe) async -> [UUID: [AmountMention]] {
        guard let claims = try? await enrichmentStore.claims(for: recipe) else { return [:] }
        return AmountAIExtractor.mentions(from: claims.map(\.asExtractedQuantity), steps: recipe.steps)
    }

    /// Calls the model regardless of what is cached, and replaces the
    /// cache with what it finds — the explicit "try again" a person can
    /// reach for, as opposed to the automatic pass `save(_:)` schedules.
    @discardableResult
    public func refreshAIMentions(for recipe: Recipe) async throws -> [UUID: [AmountMention]] {
        let claims = try await AmountAIExtractor.extractClaims(from: recipe)
        try? await enrichmentStore.save(claims.map(StoredAmountClaim.init), for: recipe)
        recordEnrichment(for: recipe.id)
        return AmountAIExtractor.mentions(from: claims, steps: recipe.steps)
    }

    /// Runs after a save, not as part of it: `save(_:)` returns exactly as
    /// fast as before, since a toggled favorite goes through here too and
    /// must not wait on a model call it does not need.
    ///
    /// Skips the call entirely when the cache already matches this
    /// recipe's text — the only reason `save(_:)` fires this often is that
    /// favoriting, marking "will ich kochen" and cooking-through all save
    /// too, and none of them touch the ingredients or instructions.
    private func scheduleEnrichment(for recipe: Recipe) {
        Task { [weak self, enrichmentStore] in
            if (try? await enrichmentStore.claims(for: recipe)) != nil { return }
            guard let claims = try? await AmountAIExtractor.extractClaims(from: recipe) else { return }
            try? await enrichmentStore.save(claims.map(StoredAmountClaim.init), for: recipe)
            self?.recordEnrichment(for: recipe.id)
        }
    }

    /// Stamps a fresh generation so `.onChange(of: library.lastEnrichment)`
    /// fires even for a second enrichment of the same recipe — an `EnrichmentEvent`
    /// equal to the last one would not trigger a change at all.
    private func recordEnrichment(for recipeID: UUID) {
        enrichmentGeneration += 1
        lastEnrichment = EnrichmentEvent(recipeID: recipeID, generation: enrichmentGeneration)
    }

    // MARK: - Amount review

    /// The suggestions the resolver could not write in on its own, paired
    /// with the resolution they came from — applying an accepted one needs
    /// that exact resolution back, since it carries where in the text each
    /// suggestion belongs.
    ///
    /// A plain read, cheap enough for a list row's `.task`: no model call,
    /// just the same regex/pot logic the detail and cook views already run
    /// on every open.
    public func amountSuggestions(for recipe: Recipe) async -> (resolution: StepAmountResolver.Resolution, suggestions: [AmountSuggestion]) {
        let mentions = await aiMentions(for: recipe)
        let resolution = StepAmountResolver.resolve(recipe, toServings: recipe.servings, additionalMentions: mentions)
        return (resolution, resolution.allSuggestions)
    }

    /// Whether `recipe` has suggestions nobody has answered yet for its
    /// current text — the recipe list's marker and the detail view's
    /// banner both ask this.
    public func needsAmountReview(_ recipe: Recipe) async -> Bool {
        let (_, suggestions) = await amountSuggestions(for: recipe)
        guard !suggestions.isEmpty else { return false }
        let reviewed = try? await amountReviewStore.reviewedHash(for: recipe.id)
        return reviewed != RecipeContentHash.hash(for: recipe)
    }

    /// Marks `recipe` reviewed against its current text — called whether
    /// the cook accepted some suggestions or dismissed the screen without
    /// changing anything at all; either way, nothing about this exact text
    /// should be asked about again.
    public func markAmountsReviewed(_ recipe: Recipe) async {
        try? await amountReviewStore.markReviewed(recipe)
    }

    /// Writes the accepted suggestions into `recipe`'s steps, saves it, and
    /// marks the result reviewed — the only path a suggestion ever takes
    /// from a guess to real text. `corrections` carries whatever the cook
    /// edited a suggestion's amount to before accepting it, keyed by
    /// suggestion id — see `StepAmountResolver.Resolution.applying(_:
    /// corrections:to:)`. Returns the updated recipe, since the caller's own
    /// copy is now stale the moment this returns.
    @discardableResult
    public func applyAmountSuggestions(
        _ accepted: Set<AmountSuggestion.ID>,
        corrections: [AmountSuggestion.ID: String] = [:],
        resolution: StepAmountResolver.Resolution,
        to recipe: Recipe
    ) async -> Recipe {
        let updated = resolution.applying(accepted, corrections: corrections, to: recipe)
        await save(updated)
        try? await amountReviewStore.markReviewed(updated)
        return updated
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

    // MARK: - From the web

    /// Reads a recipe off a page and opens it for checking.
    ///
    /// The recipe is not saved. What a page yields is a draft — the title is
    /// often the site's headline, the yield a guess, and the last two steps
    /// are sometimes an advertisement — so the editor gets it and the cook
    /// decides. Pictures are stored right away, because the editor works in
    /// image ids; anything the cook throws away goes with the draft.
    public func importFromWeb(_ url: URL) async {
        importProgress = RecipeImportProgress(done: 0, total: 0)
        defer { importProgress = nil }

        do {
            let found = try await RecipeWebImporter().draft(from: url)
            var draft = found.recipe
            for image in found.images {
                if let id = try? await imageStore.add(image, to: draft.id) {
                    draft.imageIDs.append(id)
                }
            }
            unsavedDraft = (draft.id, draft.imageIDs)
            editing = draft
        } catch {
            report(error)
        }
    }

    /// A draft from the web and the pictures fetched for it, until the
    /// editor is done with it.
    private var unsavedDraft: (id: UUID, imageIDs: [UUID])?

    /// Throws away what an abandoned draft brought with it.
    ///
    /// Called when the editor closes: if the recipe was saved, the store has
    /// it and the pictures belong to it. If it was not, they are blobs
    /// nothing references.
    public func discardUnsavedDraft() async {
        guard let draft = unsavedDraft else { return }
        unsavedDraft = nil
        guard await recipe(id: draft.id) == nil else { return }

        for id in draft.imageIDs {
            try? await imageStore.delete(id: id)
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
            try? await enrichmentStore.delete(recipeID: recipe.id)
            try? await amountReviewStore.delete(recipeID: recipe.id)
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
