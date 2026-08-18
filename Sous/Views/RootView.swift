import SousKit
import SwiftUI

/// The three places the app is used from: the library, the week ahead, and
/// what to buy for it — with whatever is on the hob riding above all three.
struct RootView: View {
    @Environment(CookSession.self) private var session
    @Environment(RecipeSelection.self) private var selection
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    #endif

    /// Which of the three the Mac is showing. The phone and iPad keep a tab
    /// view, which holds this itself.
    @State private var section: SousSection = .recipes

    /// Whether the way back to the hob is offered.
    ///
    /// Above everything rather than inside one section: the cook who left to
    /// check the shopping list has to find the way back from there, not only
    /// from the recipe list.
    ///
    /// On the Mac it shows whenever something is cooking, even while the
    /// cooking window is open — that window is a separate one and can be
    /// behind this one, so the band doubles as the way to bring it forward.
    /// It also means nothing depends on noticing that the window was closed:
    /// a band that is always there cannot leave the cook shut out of a
    /// session with no way back into it. The phone has no such problem, since
    /// cooking covers the screen there.
    private var showsBanner: Bool {
        #if os(macOS)
        !session.isEmpty
        #else
        !session.isEmpty && !session.isPresented
        #endif
    }

    var body: some View {
        @Bindable var session = session

        VStack(spacing: 0) {
            if showsBanner {
                ContinueCookingBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            sections
        }
        .animation(.easeInOut(duration: 0.2), value: showsBanner)
        // Cooking is presented from the root, so it survives leaving the
        // recipe it was started from. On the Mac it is a window of its own
        // instead — see `SousApp`.
        #if os(iOS)
        .fullScreenCover(isPresented: $session.isPresented) {
            CookModeView()
        }
        #else
        .onChange(of: session.isPresented) { _, isPresented in
            if isPresented {
                openWindow(id: SousApp.cookWindow)
            } else {
                dismissWindow(id: SousApp.cookWindow)
            }
        }
        #endif
        // Light or dark for the whole app, cook mode included, rather than
        // one screen deciding for itself.
        .sousAppearance()
        // Every string in the app is German, so dates and numbers have to be
        // German too — otherwise weekdays read "Monday" next to "Portionen".
        // This goes away once the app is properly localized.
        .environment(\.locale, .sous)
    }

    #if os(macOS)
    /// A switch above the content rather than a column beside it.
    ///
    /// A sidebar earns its width by holding something that grows — Mela's
    /// holds categories and smart lists. Here it would hold three fixed
    /// entries, and the recipe list brings its own split view, so the window
    /// ended up with a sidebar inside a sidebar. Three fixed entries are a
    /// mode, not a place to navigate to, and a segmented control says that.
    ///
    /// Categories are not missed: they are filters here, combined with
    /// ingredients and free text in the search field, which is something a
    /// list you pick one row from cannot do.
    @ViewBuilder
    private var sections: some View {
        VStack(spacing: 0) {
            // Above the split view rather than inside its first column: the
            // switch is for the window, not for the list.
            Picker("Bereich", selection: $section) {
                ForEach(SousSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // One split view for the whole window, so every section has the
            // same shape: what to work through on the left, the recipe being
            // read on the right.
            NavigationSplitView {
                switch section {
                case .recipes: RecipeListView()
                case .mealPlan: MealPlanView()
                case .shopping: ShoppingListView()
                }
            } detail: {
                if let recipe = selection.recipe {
                    RecipeDetailView(recipe: recipe)
                } else {
                    ContentUnavailableView(
                        "Kein Rezept ausgewählt",
                        systemImage: "fork.knife",
                        description: Text("Wähle links ein Rezept aus.")
                    )
                }
            }
        }
    }
    #else
    @ViewBuilder
    private var sections: some View {
        TabView {
            ForEach(SousSection.allCases) { section in
                Tab(section.title, systemImage: section.symbol) {
                    switch section {
                    case .recipes: RecipeListView()
                    case .mealPlan: MealPlanView()
                    case .shopping: ShoppingListView()
                    }
                }
            }
        }
        // On the iPad this becomes the floating bar along the top, which can
        // be opened into a sidebar; on the phone it stays a tab bar at the
        // bottom.
        .tabViewStyle(.sidebarAdaptable)
    }
    #endif
}

/// The three places the app is used from, named once so the tab bar and the
/// Mac's switch cannot drift apart on wording or order.
enum SousSection: String, CaseIterable, Identifiable {
    case recipes
    case mealPlan
    case shopping

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recipes: "Rezepte"
        case .mealPlan: "Essensplan"
        case .shopping: "Einkaufsliste"
        }
    }

    var symbol: String {
        switch self {
        case .recipes: "book.closed"
        case .mealPlan: "calendar"
        case .shopping: "cart"
        }
    }
}
