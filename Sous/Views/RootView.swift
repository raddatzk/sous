import SousKit
import SwiftUI

/// The three places the app is used from: the library, the week ahead, and
/// what to buy for it — with whatever is on the hob riding above all three.
struct RootView: View {
    @Environment(CookSession.self) private var session

    var body: some View {
        @Bindable var session = session

        VStack(spacing: 0) {
            // Above the tabs rather than inside one of them: the cook who
            // left to check the shopping list has to find the way back from
            // there, not only from the recipe list.
            if !session.isEmpty && !session.isPresented {
                ContinueCookingBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            tabs
        }
        .animation(.easeInOut(duration: 0.2), value: session.isEmpty)
        .animation(.easeInOut(duration: 0.2), value: session.isPresented)
        // Cooking is presented from the root, so it survives leaving the
        // recipe it was started from.
        .fullScreenCoverIfAvailable(isPresented: $session.isPresented) {
            CookModeView()
        }
        // Light or dark for the whole app, cook mode included, rather than
        // one screen deciding for itself.
        .sousAppearance()
        // Every string in the app is German, so dates and numbers have to be
        // German too — otherwise weekdays read "Monday" next to "Portionen".
        // This goes away once the app is properly localized.
        .environment(\.locale, .sous)
    }

    @ViewBuilder
    private var tabs: some View {
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
    }
}
