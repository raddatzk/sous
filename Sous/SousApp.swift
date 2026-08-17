import SwiftData
import SousKit
import SwiftUI

@main
struct SousApp: App {
    @State private var library: RecipeLibrary
    @State private var mealPlan: MealPlanLibrary

    init() {
        do {
            let container = try ModelContainer.sousContainer()
            let recipes = SwiftDataRecipeStore(modelContainer: container)
            _library = State(initialValue: RecipeLibrary(
                store: recipes,
                imageStore: SwiftDataRecipeImageStore(modelContainer: container)
            ))
            _mealPlan = State(initialValue: MealPlanLibrary(
                store: SwiftDataMealPlanStore(modelContainer: container),
                recipeStore: recipes
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
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Neues Rezept") { library.startNewRecipe() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
