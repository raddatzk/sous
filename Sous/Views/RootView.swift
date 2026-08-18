import SousKit
import SwiftUI

/// The three places the app is used from: the library, the week ahead, and
/// what to buy for it.
struct RootView: View {
    var body: some View {
        TabView {
            Tab("Rezepte", systemImage: "book.closed") {
                RecipeListView()
            }
            Tab("Essensplan", systemImage: "calendar") {
                MealPlanView()
            }
            Tab("Einkaufsliste", systemImage: "cart") {
                ShoppingListView()
            }
        }
        // On the Mac and iPad this becomes a sidebar; on the phone it stays a
        // tab bar at the bottom.
        .tabViewStyle(.sidebarAdaptable)
        // Light or dark for the whole app, cook mode included, rather than
        // one screen deciding for itself.
        .sousAppearance()
        // Every string in the app is German, so dates and numbers have to be
        // German too — otherwise weekdays read "Monday" next to "Portionen".
        // This goes away once the app is properly localized.
        .environment(\.locale, .sous)
    }
}
