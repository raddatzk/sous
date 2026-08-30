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
    /// `nil` in tests that have no reason to care about the nutrition cache
    /// — only `erase(_:)` ever touches it, to clean up after a deleted
    /// recipe the way it already does for the enrichment and review caches.
    private let nutritionStore: (any RecipeNutritionStore)?
    /// `nil` where nothing cares whether a recipe's ingredients have been
    /// checked against the catalog — `needsIngredientReview` then always
    /// reads as "not reviewed" rather than tracking a dismissal.
    private let ingredientReviewStore: (any RecipeIngredientReviewStore)?
    /// `nil` falls back to the bundled catalog — matches how
    /// `ShoppingLibrary` and `NutritionLibrary` treat the same dependency.
    private let catalogLibrary: IngredientCatalogLibrary?

    public private(set) var recipes: [Recipe] = []
    /// The variant groups that are currently groups at all, by id.
    ///
    /// A group with one member left is not in here: it draws as the ordinary
    /// recipe it now looks like. Its row is kept in the store all the same,
    /// so restoring the sibling from the trash puts the pair back together.
    public private(set) var variantGroups: [UUID: VariantGroup] = [:]
    /// How many members each group has that are not in the trash — which is
    /// not what the list is showing. A filter may have passed one variant of
    /// five, and the row above it should be able to say so.
    public private(set) var variantMemberCounts: [UUID: Int] = [:]
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
        amountReviewStore: any RecipeAmountReviewStore,
        nutritionStore: (any RecipeNutritionStore)? = nil,
        ingredientReviewStore: (any RecipeIngredientReviewStore)? = nil,
        catalogLibrary: IngredientCatalogLibrary? = nil
    ) {
        self.store = store
        self.imageStore = imageStore
        self.enrichmentStore = enrichmentStore
        self.amountReviewStore = amountReviewStore
        self.nutritionStore = nutritionStore
        self.ingredientReviewStore = ingredientReviewStore
        self.catalogLibrary = catalogLibrary
    }

    private var catalog: IngredientCatalog {
        catalogLibrary?.catalog ?? .bundled
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
            // Without the meal filters: the store can only answer those from
            // what a recipe states, and most state nothing. They are applied
            // afterwards, here, where the planner's cached guess can stand in
            // — see ``narrowedToSlots(_:filters:)``.
            filters: activeFilters.filter { $0.kind != .slot && $0.kind != .effort },
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
            recipes = narrowedToEffort(
                try await narrowedToSlots(
                    store.recipes(matching: query),
                    filters: activeFilters
                ),
                filters: activeFilters
            )
            categories = try await store.categories()
            // Two is what makes a group. Below that there is nothing to
            // stand beside, and an indented list of one is a rule the reader
            // has to learn for no gain.
            let groups = try await store.variantGroups().filter { $0.liveMembers >= 2 }
            variantGroups = Dictionary(uniqueKeysWithValues: groups.map { ($0.group.id, $0.group) })
            variantMemberCounts = Dictionary(
                uniqueKeysWithValues: groups.map { ($0.group.id, $0.liveMembers) }
            )
        } catch {
            report(error)
        }
    }

    /// The list as it is drawn: recipes at the top level, with the members of
    /// a group gathered under it.
    ///
    /// Derived on every read rather than held, because it is a view of
    /// `recipes` and would otherwise be a second thing to keep in step. The
    /// nesting is presentation — the store knows nothing about it, and a
    /// filtered list shows a group with only the members that came back.
    public var entries: [VariantGrouping.Entry] {
        VariantGrouping.entries(for: recipes, groups: variantGroups)
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

    /// Searches the whole library, independent of the current filter.
    ///
    /// Used by the picker that inserts a link to another recipe, and by the
    /// search tab — which asks its questions here rather than through
    /// ``searchText`` precisely so that they leave the list alone: that one
    /// belongs to the reader in the recipes tab, standing where they left it.
    public func findRecipes(
        matching text: String,
        filters: [RecipeFilter] = []
    ) async -> [Recipe] {
        do {
            let found = try await store.recipes(
                matching: RecipeQuery(
                    searchText: text.isEmpty ? nil : text,
                    filters: filters.filter { $0.kind != .slot && $0.kind != .effort }
                )
            )
            return narrowedToEffort(
                await narrowedToSlots(found, filters: filters), filters: filters
            )
        } catch {
            report(error)
            return []
        }
    }

    /// Keeps only the recipes that suit every meal named in `filters`.
    ///
    /// Two sources, in the order the planner already reads them: what the
    /// recipe itself says, and — where it says "Automatisch" — the guess
    /// cached against its current text. Nothing is classified here: a filter
    /// that ran the model over a library would be a search that thinks for a
    /// minute, so a recipe nobody has judged yet is simply not claimed to
    /// suit anything.
    private func narrowedToSlots(
        _ recipes: [Recipe],
        filters: [RecipeFilter]
    ) async -> [Recipe] {
        let wanted = Set(filters.compactMap(\.slot))
        guard !wanted.isEmpty else { return recipes }

        var kept: [Recipe] = []
        for recipe in recipes {
            guard let slots = await knownSlots(of: recipe) else { continue }
            if wanted.isSubset(of: slots) { kept.append(recipe) }
        }
        return kept
    }

    /// Keeps the recipes whose effort matches every rung asked for.
    ///
    /// Like the slot narrowing above and for the same reason: the value is
    /// mostly not written on the recipe but read off its structure, so the
    /// store cannot answer it. A recipe with too little structure to judge
    /// drops out rather than being counted as easy — an unread dish is not a
    /// simple one, and a filter that guessed otherwise would fill "Einfach"
    /// with everything nobody has written properly.
    ///
    /// Linked recipes resolve against the recipes in hand rather than the
    /// store. A filter that went back to the store per link would turn one
    /// question into a hundred; the effect is only that a sub-recipe outside
    /// the current result counts as a step rather than as its own work.
    private func narrowedToEffort(
        _ recipes: [Recipe], filters: [RecipeFilter]
    ) -> [Recipe] {
        let wanted = Set(filters.compactMap(\.effort))
        guard !wanted.isEmpty else { return recipes }

        let athand = Dictionary(recipes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return recipes.filter { recipe in
            guard let level = recipe.effortOverride
                ?? recipe.effort(resolve: { athand[$0] })?.level
            else { return false }
            return wanted.contains(level)
        }
    }

    /// The meals a recipe is known to suit, or `nil` where nobody has said
    /// and nothing was guessed. `nil` rather than an empty set, because the
    /// two are different answers: "suits nothing" is a judgment, "unknown"
    /// is the absence of one.
    private func knownSlots(of recipe: Recipe) async -> Set<MealSlot>? {
        if let stated = recipe.suitableSlots { return stated }
        let hash = MealSuitabilityClassifier.inputHash(for: recipe)
        return try? await enrichmentStore.suitabilityGuess(for: recipe.id, inputHash: hash)
    }

    /// Rebuilds the store's denormalized search index against the current
    /// catalog — run when the shipped data changes, so "Kürbis" keeps
    /// finding the recipe that says "Hokkaido" even though that relation
    /// arrived after the recipe was last saved.
    public func reindexSearch() async {
        do {
            try await store.reindexSearch(catalog: .bundled)
            await reload()
        } catch {
            report(error)
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
        let resolved = StepAmountResolver.resolve(recipe, toServings: recipe.servings, additionalMentions: mentions)
        // The ones the cook has already said no to are gone from here on:
        // this is the one door the banner, the list marker and the sheet all
        // come through, so a settled question cannot slip back in through
        // one of them.
        let declined = (try? await amountReviewStore.declinedKeys(for: recipe.id)) ?? []
        let resolution = resolved.excluding(declined: declined)
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
    ///
    /// `declining` are the questions turned down for good rather than just
    /// for this text: they survive later edits elsewhere in the recipe, which
    /// the content hash on its own cannot. Passing none is the "Nicht jetzt"
    /// answer, and leaves the ones already turned down where they are.
    public func markAmountsReviewed(_ recipe: Recipe, declining: Set<String> = []) async {
        try? await amountReviewStore.markReviewed(recipe, declining: await remembered(declining, for: recipe))
    }

    /// The questions already turned down for good, for a caller that resolves
    /// a recipe itself rather than going through ``amountSuggestions(for:)``
    /// — the editor, which works on an unsaved draft.
    public func declinedAmountKeys(for recipeID: UUID) async -> Set<String> {
        (try? await amountReviewStore.declinedKeys(for: recipeID)) ?? []
    }

    /// What to write as `recipe`'s declined set: the new answers, plus the
    /// old ones the recipe still asks.
    ///
    /// Old keys are dropped rather than kept forever. A key names a sentence,
    /// and a sentence that has been rewritten away is not a question anybody
    /// can answer again — keeping it would grow the row by every edit the
    /// recipe ever saw, for nothing.
    private func remembered(_ declining: Set<String>, for recipe: Recipe) async -> Set<String> {
        let previous = (try? await amountReviewStore.declinedKeys(for: recipe.id)) ?? []
        guard !previous.isEmpty else { return declining }
        let mentions = await aiMentions(for: recipe)
        let asked = Set(
            StepAmountResolver.resolve(recipe, toServings: recipe.servings, additionalMentions: mentions)
                .allSuggestions.map(\.declineKey)
        )
        return declining.union(previous.intersection(asked))
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
        declining: Set<String> = [],
        resolution: StepAmountResolver.Resolution,
        to recipe: Recipe
    ) async -> Recipe {
        let updated = resolution.applying(accepted, corrections: corrections, to: recipe)
        await save(updated)
        // Against the updated recipe: accepting a suggestion rewrites the
        // sentence it was about, so the keys still worth keeping are the ones
        // the *new* text asks.
        try? await amountReviewStore.markReviewed(updated, declining: await remembered(declining, for: updated))
        return updated
    }

    // MARK: - Ingredient review

    /// The ingredients in `recipe` the catalog does not know — the same
    /// question `RecipeEditorView`'s "Noch unbekannt" row asks while typing,
    /// asked again here so a recipe that skipped the editor (a bulk import)
    /// or was written before an ingredient existed in the catalog still gets
    /// noticed.
    public func unknownIngredients(in recipe: Recipe) -> [String] {
        catalog.unknownIngredients(in: recipe.ingredientsText)
    }

    /// Whether `recipe` has unrecognized ingredients nobody has answered yet
    /// for its current text — the recipe list's marker and the detail view's
    /// banner both ask this.
    public func needsIngredientReview(_ recipe: Recipe) async -> Bool {
        guard !unknownIngredients(in: recipe).isEmpty else { return false }
        let reviewed = try? await ingredientReviewStore?.reviewedHash(for: recipe.id)
        return reviewed != RecipeContentHash.hash(for: recipe)
    }

    /// Marks `recipe` reviewed against its current text — called whether the
    /// cook added every unknown ingredient to the catalog or left the sheet
    /// without changing anything; either way, nothing about this exact text
    /// should be asked about again.
    public func markIngredientsReviewed(_ recipe: Recipe) async {
        try? await ingredientReviewStore?.markReviewed(recipe)
    }

    // MARK: - Variant groups

    /// A group's members that are not in the trash, in creation order —
    /// everything it has, not what the current filter left standing.
    public func variantMembers(of groupID: UUID) async -> [Recipe] {
        do {
            return try await store.variantGroupMembers(id: groupID)
        } catch {
            report(error)
            return []
        }
    }

    public func variantGroup(id: UUID) async -> VariantGroup? {
        do {
            return try await store.variantGroup(id: id)
        } catch {
            report(error)
            return nil
        }
    }

    /// Puts a second version of `recipe` beside it, creating the group the
    /// two of them then belong to if there is not one yet.
    ///
    /// The group is born here rather than through a command of its own: a
    /// group is what having two versions of a dish *is*, not an
    /// administrative act somebody performs first. `groupTitle` is only
    /// consulted while creating one — the second variant joins the group
    /// that already has a name.
    ///
    /// Returns the new variant, whose pictures are its own to add: see
    /// ``Recipe/variantCopy(title:in:id:now:)`` for what a copy carries.
    @discardableResult
    public func addVariant(
        of recipe: Recipe,
        title: String,
        groupTitle: String
    ) async -> Recipe? {
        do {
            let groupID: UUID
            if let existing = recipe.variantGroupID,
               try await store.variantGroup(id: existing) != nil {
                groupID = existing
            } else {
                let group = try await store.saveVariantGroup(VariantGroup(title: groupTitle))
                groupID = group.id
                // The original joins its own group, which is the whole of
                // what "symmetric" means here: it is a member like the new
                // one, not a base the new one hangs off.
                var original = recipe
                original.variantGroupID = groupID
                try await store.save(original)
            }

            let variant = recipe.variantCopy(title: title, in: groupID)
            try await store.save(variant)
            await reload()
            // Saved separately from the copy above, because the enrichment
            // pass keys off the text and the copy's text is the original's.
            scheduleEnrichment(for: variant)
            return variant
        } catch {
            report(error)
            return nil
        }
    }

    /// Puts two recipes that were written separately into one group.
    ///
    /// The other half of the feature, and the one that has something to work
    /// with today: a collection that has been grown by hand is full of pairs
    /// like "Ajvar-Suppe" and "Ajvar-Suppe vegan" which are versions of one
    /// dish and know nothing about each other. Nothing is copied here — both
    /// recipes stay exactly as they are, which is what makes this safe enough
    /// to offer on recipes somebody has been cooking for years.
    ///
    /// Neither may already belong to a group. Merging two groups would have
    /// to throw one of the two titles away, and a name disappearing is not
    /// something to do as a side effect of picking a recipe from a list.
    @discardableResult
    public func groupAsVariants(_ first: Recipe, _ second: Recipe) async -> VariantGroup? {
        guard first.id != second.id else { return nil }
        do {
            for recipe in [first, second] where try await !isUngrouped(recipe) {
                // Said out loud rather than swallowed. The picker greys these
                // out, but a group whose second member is in the trash has
                // stopped drawing as one and still owns its members.
                errorMessage = refusal(for: recipe, group: await variantGroup(of: recipe))
                return nil
            }
            let group = try await store.saveVariantGroup(
                VariantGroup(title: VariantGroup.suggestedTitle(for: [first, second]))
            )
            for recipe in [first, second] {
                var member = recipe
                member.variantGroupID = group.id
                try await store.save(member)
            }
            await reload()
            return group
        } catch {
            report(error)
            return nil
        }
    }

    /// Takes an existing recipe into a group that is already there.
    @discardableResult
    public func addToVariantGroup(_ groupID: UUID, recipe: Recipe) async -> Bool {
        do {
            guard try await store.variantGroup(id: groupID) != nil else { return false }
            guard try await isUngrouped(recipe) else {
                errorMessage = refusal(for: recipe, group: await variantGroup(of: recipe))
                return false
            }
            var member = recipe
            member.variantGroupID = groupID
            try await store.save(member)
            await reload()
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Takes one recipe back out, leaving its siblings grouped.
    public func removeFromVariantGroup(_ recipe: Recipe) async {
        do {
            try await store.removeFromVariantGroup(recipeID: recipe.id)
            await reload()
        } catch {
            report(error)
        }
    }

    /// Why a recipe cannot be taken into a group, in the words the picker
    /// and the alert both use.
    public func refusal(for recipe: Recipe, group: VariantGroup?) -> String {
        guard let group else { return "„\(recipe.title)“ gehört schon zu einer anderen Gruppe." }
        return "„\(recipe.title)“ gehört schon zur Gruppe „\(group.title)“. Löse sie erst auf."
    }

    /// Whether a recipe is free to join a group.
    ///
    /// Asked of the store rather than of `variantGroups`, which holds only
    /// the groups currently drawing as groups: a recipe whose sibling is in
    /// the trash still belongs somewhere, and taking it into a second group
    /// would leave the first with a member it cannot get back.
    private func isUngrouped(_ recipe: Recipe) async throws -> Bool {
        guard let id = recipe.variantGroupID else { return true }
        return try await store.variantGroup(id: id) == nil
    }

    /// The group a recipe belongs to, whether or not it currently draws as
    /// one — for telling a picker why a recipe cannot be taken.
    public func variantGroup(of recipe: Recipe) async -> VariantGroup? {
        guard let id = recipe.variantGroupID else { return nil }
        return await variantGroup(id: id)
    }

    public func renameVariantGroup(_ group: VariantGroup, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != group.title else { return }
        do {
            var updated = group
            updated.title = trimmed
            try await store.saveVariantGroup(updated)
            await reload()
        } catch {
            report(error)
        }
    }

    /// Takes a group apart, leaving its members behind as the ordinary
    /// recipes they always were.
    public func dissolveVariantGroup(_ groupID: UUID) async {
        do {
            try await store.dissolveVariantGroup(id: groupID)
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
            try? await nutritionStore?.delete(recipeID: recipe.id)
            try? await ingredientReviewStore?.delete(recipeID: recipe.id)
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
        // Before the recipe, because saving a member looks the group's title
        // up to fold it into the search index. Every member of a group
        // carries the same description of it, so this writes the same row as
        // many times as the group has members — which is what makes an
        // archive a bag of recipe files rather than an ordered format.
        if let group = item.variantGroup {
            try await store.saveVariantGroup(group)
        }
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
            return try MelaExport.recipe(
                recipe,
                images: await images(of: recipe),
                variantGroup: await exportedGroup(of: recipe)
            )
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

            var groups: [UUID: VariantGroup] = [:]
            for (group, _) in try await store.variantGroups() {
                groups[group.id] = group
            }

            var items: [(recipe: Recipe, images: [Data], variantGroup: VariantGroup?)] = []
            for recipe in recipes {
                let group = recipe.variantGroupID.flatMap { groups[$0] }
                items.append((recipe, await images(of: recipe), group))
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

    /// The group a single exported recipe belongs to, so the file can name
    /// it. Every group, not only the ones currently drawing as one: a member
    /// whose sibling is in the trash still belongs where it belongs.
    private func exportedGroup(of recipe: Recipe) async -> VariantGroup? {
        guard let id = recipe.variantGroupID else { return nil }
        return try? await store.variantGroup(id: id)
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
