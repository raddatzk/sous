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
    /// Timers outlive the screen they were started from, so they are held by
    /// the app rather than by cook mode.
    @State private var timers = CookTimerCenter()
    /// And so does the cooking itself: what is on the hob is app state, not
    /// something the screen showing it owns.
    @State private var session = CookSession()
    /// Which recipe the Mac's detail column is showing — outlives the section
    /// on the left, so it does not belong to any one of them.
    @State private var selection = RecipeSelection()
    /// Importing and exporting the library, which the Mac reaches from the
    /// menu bar and so cannot keep inside the recipe list.
    @State private var exchange = LibraryExchange()

    init() {
        do {
            let container = try ModelContainer.sousContainer()
            let recipes = SwiftDataRecipeStore(modelContainer: container)
            _library = State(initialValue: RecipeLibrary(
                store: recipes,
                imageStore: SwiftDataRecipeImageStore(modelContainer: container)
            ))
            let plan = MealPlanLibrary(
                store: SwiftDataMealPlanStore(modelContainer: container),
                recipeStore: recipes
            )
            _mealPlan = State(initialValue: plan)
            let catalogLibrary = IngredientCatalogLibrary(
                store: SwiftDataIngredientCatalogStore(modelContainer: container)
            )
            _catalog = State(initialValue: catalogLibrary)
            _shopping = State(initialValue: ShoppingLibrary(
                store: SwiftDataShoppingListStore(modelContainer: container),
                recipeStore: recipes,
                catalogLibrary: catalogLibrary
            ))
        } catch {
            // A recipe app without its database has nothing to show, and
            // hiding that behind an empty list would be worse than stopping.
            fatalError("Could not open the recipe store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(mealPlan)
                .environment(shopping)
                .environment(catalog)
                .environment(timers)
                .environment(session)
                .environment(selection)
                .environment(exchange)
                // Timers stopped from the lock screen have to disappear from
                // the step too, so AlarmKit's own list is the one that counts.
                .task {
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
            // Where a Mac looks for these. The same two entries stay in the
            // list's own menu on the phone, which has no menu bar to look in.
            CommandGroup(replacing: .importExport) {
                Button("Rezepte importieren…") { exchange.isImporting = true }
                Button("Alle Rezepte exportieren…") {
                    Task {
                        guard let data = await library.exportedLibrary() else { return }
                        exchange.export = RecipeExport(
                            data: data,
                            name: "Rezepte",
                            contentType: RecipeExport.library
                        )
                    }
                }
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
