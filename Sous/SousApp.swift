import SwiftData
import SousKit
import SwiftUI

@main
struct SousApp: App {
    /// The cooking window's id, shared with whoever opens it.
    static let cookWindow = "cook"
    @State private var library: RecipeLibrary
    @State private var mealPlan: MealPlanLibrary
    @State private var shopping: ShoppingLibrary
    @State private var catalog: IngredientCatalogLibrary
    @State private var nutrition: NutritionLibrary
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
    /// Held so the once-per-launch re-key can reach the store without opening
    /// a second container.
    private let migration: SwiftDataBundledDataMigration

    init() {
        do {
            let container = try ModelContainer.sousContainer()
            migration = SwiftDataBundledDataMigration(modelContainer: container)
            let recipes = SwiftDataRecipeStore(modelContainer: container)
            let nutritionStore = SwiftDataRecipeNutritionStore(modelContainer: container)
            let catalogLibrary = IngredientCatalogLibrary(
                store: SwiftDataIngredientCatalogStore(modelContainer: container),
                aliasStore: SwiftDataIngredientAliasOverrideStore(modelContainer: container),
                // Teaching the app a spelling can change what a recipe's
                // nutrition adds up to, which is cached per recipe text.
                nutritionCache: nutritionStore
            )
            _catalog = State(initialValue: catalogLibrary)
            _library = State(initialValue: RecipeLibrary(
                store: recipes,
                imageStore: SwiftDataRecipeImageStore(modelContainer: container),
                enrichmentStore: SwiftDataRecipeEnrichmentStore(modelContainer: container),
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
            _shopping = State(initialValue: ShoppingLibrary(
                store: SwiftDataShoppingListStore(modelContainer: container),
                recipeStore: recipes,
                catalogLibrary: catalogLibrary,
                pantryStore: SwiftDataPantryFlagStore(modelContainer: container)
            ))
            _nutrition = State(initialValue: NutritionLibrary(
                store: nutritionStore,
                recipeStore: recipes,
                catalogLibrary: catalogLibrary,
                nutritionStore: SwiftDataCatalogNutritionStore(modelContainer: container)
            ))
        } catch {
            // A recipe app without its database has nothing to show, and
            // hiding that behind an empty list would be worse than stopping.
            fatalError("Could not open the recipe store: \(error)")
        }
    }

    /// Stamps the cook's name-keyed rows with their SBLS code once, and says
    /// nothing when there is nothing to do — which is every launch after the
    /// first. A failure here is not worth stopping for: every row keeps
    /// joining by name, which is exactly the compatibility path.
    private func migrateBundledData() async {
        _ = try? await migration.run()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(mealPlan)
                .environment(shopping)
                .environment(catalog)
                .environment(nutrition)
                .environment(timers)
                .environment(session)
                .environment(selection)
                .environment(commands)
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
        .commands {
            CommandGroup(after: .newItem) {
                Button("Neues Rezept") { library.startNewRecipe() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            // Where a Mac looks for these. The iPad keeps the toolbar's copy
            // as well — see the note there.
            CommandGroup(replacing: .importExport) {
                Button("Rezepte importieren…") { commands.isImporting = true }
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
            }
            // Managing the library rather than a recipe. Its own menu because
            // none of the standard groups is about this, and on both platforms
            // because the iPad has a menu bar too since iPadOS 26.
            CommandMenu("Bibliothek") {
                Button("Zutaten verwalten…") { commands.panel = .catalog }
                Button("Kategorien verwalten…") { commands.panel = .categories }
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
