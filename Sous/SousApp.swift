import SwiftData
import SousKit
import SwiftUI

@main
struct SousApp: App {
    @State private var library: RecipeLibrary

    init() {
        do {
            let container = try ModelContainer.sousContainer()
            _library = State(initialValue: RecipeLibrary(
                store: SwiftDataRecipeStore(modelContainer: container),
                imageStore: SwiftDataRecipeImageStore(modelContainer: container)
            ))
        } catch {
            // A recipe app without its database has nothing to show, and
            // hiding that behind an empty list would be worse than stopping.
            fatalError("Could not open the recipe store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RecipeListView()
                .environment(library)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Neues Rezept") { library.startNewRecipe() }
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
