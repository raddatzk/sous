import SwiftData
import SousKit
import SwiftUI

@main
struct SousApp: App {
    @State private var library: RecipeLibrary
    @State private var mealPlan: MealPlanLibrary
    @State private var shopping: ShoppingLibrary
    @State private var catalog: IngredientCatalogLibrary

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
        .commands {
            CommandGroup(after: .newItem) {
                Button("Neues Rezept") { library.startNewRecipe() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
