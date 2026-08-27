import AppIntents
import CoreSpotlight
import SwiftData
import SousKit
import SwiftUI

@main
struct SousApp: App {
    /// The cooking window's id, shared with whoever opens it.
    static let cookWindow = "cook"
    @Environment(\.scenePhase) private var scenePhase
    @State private var library: RecipeLibrary
    @State private var mealPlan: MealPlanLibrary
    @State private var shopping: ShoppingLibrary
    @State private var catalog: IngredientCatalogLibrary
    @State private var nutrition: NutritionLibrary
    @State private var dinnerPlanner: DinnerPlannerLibrary
    /// Which section is showing — app state, so an App Intent can steer it.
    @State private var navigation = SousNavigation()
    /// Held by the app for the Spotlight index, which wants every recipe
    /// and not whatever the list is currently filtered to.
    private let recipeStore: SwiftDataRecipeStore
    /// Timers outlive the screen they were started from, so they are held by
    /// the app rather than by cook mode.
    @State private var timers = CookTimerCenter()
    /// And so does the cooking itself: what is on the hob is app state, not
    /// something the screen showing it owns.
    @State private var session = CookSession()
    /// Which recipe the Mac's detail column is showing — outlives the section
    /// on the left, so it does not belong to any one of them.
    @State private var selection = RecipeSelection()
    /// What the menu bar can ask of the library — which lives here rather
    /// than in the recipe list, because a command in the scene cannot see a
    /// view's state.
    @State private var commands = LibraryCommands()
    /// Whether the shipped data changed under the cook's vocabulary, and
    /// something was orphaned by it.
    @State private var dataUpdate = DataUpdateNotice()
    /// Held so the once-per-launch migrations can reach the store without
    /// opening a second container.
    private let migration: SwiftDataBundledDataMigration
    private let vocabularyMigration: SwiftDataVocabularyMigration
    private let orphanReconciliation: SwiftDataOrphanReconciliation
    /// What data this device last ran against. Device state, not user
    /// content — see `BundledDataMarker`.
    private let marker = BundledDataMarker()

    init() {
        do {
            let container = try ModelContainer.sousContainer()
            migration = SwiftDataBundledDataMigration(modelContainer: container)
            vocabularyMigration = SwiftDataVocabularyMigration(modelContainer: container)
            orphanReconciliation = SwiftDataOrphanReconciliation(modelContainer: container)
            let recipes = SwiftDataRecipeStore(modelContainer: container)
            let nutritionStore = SwiftDataRecipeNutritionStore(modelContainer: container)
            let enrichmentStore = SwiftDataRecipeEnrichmentStore(modelContainer: container)
            let catalogLibrary = IngredientCatalogLibrary(
                store: SwiftDataVocabularyStore(modelContainer: container),
                // Teaching the app a spelling, or confirming what a word
                // means, can change what a recipe's nutrition adds up to —
                // and that is cached per recipe text, which never notices.
                nutritionCache: nutritionStore
            )
            _catalog = State(initialValue: catalogLibrary)
            _library = State(initialValue: RecipeLibrary(
                store: recipes,
                imageStore: SwiftDataRecipeImageStore(modelContainer: container),
                enrichmentStore: enrichmentStore,
                amountReviewStore: SwiftDataRecipeAmountReviewStore(modelContainer: container),
                nutritionStore: nutritionStore,
                ingredientReviewStore: SwiftDataRecipeIngredientReviewStore(modelContainer: container),
                catalogLibrary: catalogLibrary
            ))
            let plan = MealPlanLibrary(
                store: SwiftDataMealPlanStore(modelContainer: container),
                recipeStore: recipes
            )
            _mealPlan = State(initialValue: plan)
            let shoppingLibrary = ShoppingLibrary(
                store: SwiftDataShoppingListStore(modelContainer: container),
                recipeStore: recipes,
                catalogLibrary: catalogLibrary
            )
            _shopping = State(initialValue: shoppingLibrary)
            let nutritionLibrary = NutritionLibrary(
                store: nutritionStore,
                recipeStore: recipes,
                catalogLibrary: catalogLibrary
            )
            _nutrition = State(initialValue: nutritionLibrary)
            _dinnerPlanner = State(initialValue: DinnerPlannerLibrary(
                recipeStore: recipes,
                mealPlan: plan,
                nutrition: nutritionLibrary,
                enrichment: enrichmentStore
            ))
            recipeStore = recipes

            // The same instances the views hold, handed to the App Intents:
            // Siri writing to a second store while the app shows the first
            // would be two apps in one process.
            AppDependencyManager.shared.add(dependency: recipes)
            AppDependencyManager.shared.add(dependency: shoppingLibrary)
            AppDependencyManager.shared.add(dependency: plan)
        } catch {
            // A recipe app without its database has nothing to show, and
            // hiding that behind an empty list would be worse than stopping.
            fatalError("Could not open the recipe store: \(error)")
        }
        // These carry their defaults, so `self` is whole here — the session
        // and selection go to the intents as the same objects the UI holds.
        // Bound to locals first: `add` takes its dependency lazily, and a
        // lazy read of `self` is not something an initializer may hand out.
        let cookSession = session
        let recipeSelection = selection
        let sousNavigation = navigation
        AppDependencyManager.shared.add(dependency: cookSession)
        AppDependencyManager.shared.add(dependency: recipeSelection)
        AppDependencyManager.shared.add(dependency: sousNavigation)
    }

    /// Stamps the cook's name-keyed rows with their SBLS code, then folds
    /// them into the vocabulary — in that order, because the fold carries the
    /// stamps across and a row stamped afterwards would be stamped in a table
    /// nobody reads any more.
    ///
    /// Both say nothing when there is nothing to do, which is every launch
    /// after the first. A failure is not worth stopping for: the legacy rows
    /// are only deleted once their content has been written.
    private func migrateBundledData() async {
        _ = try? await migration.run()
        _ = try? await vocabularyMigration.run()
        await reconcileBundledData()
    }

    /// Phase 6's reconciliation, and only when there is something to
    /// reconcile: the marker says which data this device last ran against,
    /// and an unchanged bundle means no mapping can have been orphaned since
    /// the last launch.
    ///
    /// Everything else concept §7 asks for needs no run at all. Changed
    /// values reach the cook because a basis stores a code and reads its
    /// numbers through the shipped table on every read — silently, per
    /// decision D. A vanished code already reads as orphaned. What the pass
    /// adds is the list, so the cook is told rather than left to find out one
    /// recipe at a time.
    ///
    /// The marker is written only after the pass returns, so a crash in
    /// between costs a repeated run rather than a skipped one — and the pass
    /// is idempotent, which is what makes that the cheap failure.
    private func reconcileBundledData() async {
        let stamp = BundledDataMarker.current()
        guard marker.hasChanged(from: stamp) else { return }
        guard let report = try? await orphanReconciliation.run() else { return }
        // New data can also mean new relations — a variety gaining its
        // parent — and the denormalized search index only learns those on
        // a save. Same trigger, same idempotence.
        await library.reindexSearch()
        marker.record(stamp)
        dataUpdate.didFindOrphans = !report.orphanedNames.isEmpty
    }

    /// Every live recipe into the system index, so the collection answers
    /// from Spotlight without the app open.
    private func indexRecipesForSpotlight() async {
        guard let recipes = try? await recipeStore.recipes(matching: RecipeQuery()) else { return }
        try? await CSSearchableIndex.default().indexAppEntities(recipes.map(RecipeEntity.init))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(mealPlan)
                .environment(shopping)
                .environment(catalog)
                .environment(nutrition)
                .environment(dinnerPlanner)
                .environment(timers)
                .environment(session)
                .environment(selection)
                .environment(commands)
                .environment(dataUpdate)
                .environment(navigation)
                // Timers stopped from the lock screen have to disappear from
                // the step too, so AlarmKit's own list is the one that counts.
                .task {
                    // Before the catalogs are read: the cook's own rows have
                    // to carry their SBLS code, or the first thing that looks
                    // one up joins by name and caches the answer.
                    await migrateBundledData()
                    // Before anything asks what an ingredient is: the
                    // catalog screens are not the only readers of it, and a
                    // recipe resolved against the bundled list alone would
                    // have its wrong total cached.
                    await catalog.ensureLoaded()
                    await nutrition.ensureLoaded()
                    timers.forgetStale()
                    session.forgetStale()
                    #if os(iOS)
                    await timers.watchAlarms()
                    #endif
                    // Siri's vocabulary and the system search, refreshed per
                    // launch: the phrases need the current want-to-cook
                    // marks, Spotlight the current titles. Per-save updates
                    // can come later; a day-old index finds yesterday's
                    // recipe, which is far better than none.
                    SousAppShortcuts.updateAppShortcutParameters()
                    await indexRecipesForSpotlight()
                }
                // The launch task above runs once — and on iOS a launch
                // can be days ago while the app lived in memory. Without
                // this, the 12-hour grace never fires again and last
                // night's roast greets this morning's breakfast after all,
                // "Weiter kochen" band and all.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    timers.forgetStale()
                    session.forgetStale()
                }
                // A page shared from Safari arrives as sous://import?url=…
                .onOpenURL { url in
                    guard url.scheme == "sous", url.host() == "import",
                          let shared = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                              .queryItems?.first(where: { $0.name == "url" })?.value,
                          let target = URL(string: shared)
                    else { return }
                    Task { await library.importFromWeb(target) }
                }
        }
        .defaultSize(width: 1180, height: 800)
        #if os(macOS)
        .windowResizability(.contentMinSize)
        #endif
        .commands {
            CommandGroup(after: .newItem) {
                Button("Neues Rezept") { library.startNewRecipe() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            // Where a Mac looks for these. The iPad keeps the toolbar's copy
            // as well — see the note there.
            CommandGroup(replacing: .importExport) {
                Button("Rezepte importieren…") { commands.isImporting = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Alle Rezepte exportieren…") {
                    Task {
                        guard let data = await library.exportedLibrary() else { return }
                        commands.export = RecipeExport(
                            data: data,
                            name: "Rezepte",
                            contentType: RecipeExport.library
                        )
                    }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            // Managing the library rather than a recipe. Its own menu because
            // none of the standard groups is about this, and on both platforms
            // because the iPad has a menu bar too since iPadOS 26.
            CommandMenu("Bibliothek") {
                // The app's primary action, reachable without the mouse: the
                // recipe the window is showing goes on the hob. ⌘⏎ rather
                // than a letter, the way "do the thing" reads elsewhere.
                Button("Rezept kochen") {
                    if case .recipe(let recipe) = selection.target, !recipe.isDeleted {
                        // `start` presents cook mode itself, same as the
                        // page's own button.
                        session.start(recipe, servings: recipe.servings)
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled({
                    guard case .recipe(let recipe) = selection.target else { return true }
                    return recipe.isDeleted || recipe.steps.isEmpty
                }())
                Divider()
                Button("Zutaten verwalten…") { commands.panel = .catalog }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Kategorien verwalten…") { commands.panel = .categories }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Divider()
                Button("Papierkorb…") { commands.panel = .trash }
            }
        }

        #if os(macOS)
        // Cooking gets a window of its own rather than a sheet over the
        // library. A sheet is modal, and cooking is the opposite of modal:
        // it runs for an hour beside everything else, and the cook wants the
        // recipe on the second screen or next to the shopping list. The
        // session already lives in the app rather than in a view, so a second
        // window needs nothing but the same environment.
        Window("Kochen", id: Self.cookWindow) {
            CookModeView()
                // Below this the steps column and the ingredient column
                // stop being readable side by side — and without a stated
                // minimum the window can be dragged down to a title bar.
                .frame(minWidth: 560, minHeight: 420)
                .environment(library)
                .environment(mealPlan)
                .environment(shopping)
                .environment(catalog)
                .environment(nutrition)
                .environment(timers)
                .environment(session)
                .environment(selection)
                // Cook mode names the appearance itself; the locale it needs
                // from here, since it no longer sits inside `RootView`.
                .environment(\.locale, .sous)
                // Closing the window with the red button has to reach the
                // session too, or the band would keep offering a way back
                // into a window that is already open.
                .onDisappear { session.isPresented = false }
        }
        .defaultSize(width: 940, height: 720)
        .windowResizability(.contentMinSize)

        // Cmd-, is where a Mac user looks; the sheet in the "Mehr" menu is
        // for the phone, and both write the same defaults.
        Settings {
            SettingsForm()
                .sousAppearance()
                .frame(width: 420)
        }
        #endif
    }
}
