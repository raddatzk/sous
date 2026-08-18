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
    /// An experiment: the tab bar the iPad has, on the Mac.
    ///
    /// `.tabBarOnly` is what makes it thinkable — the earlier attempt used
    /// `.sidebarAdaptable`, which turned the tab view into a sidebar and left
    /// the window with a sidebar inside a sidebar. This offers no sidebar at
    /// all.
    ///
    /// What it costs is that each section carries its own split view, so the
    /// split view is inside a tab rather than at the window's root — which is
    /// exactly what once gave a half-width sidebar and a toolbar that
    /// collapsed into an overflow chevron. Whether `.tabBarOnly` avoids that
    /// is the thing being tried.
    @ViewBuilder
    private var sections: some View {
        TabView(selection: $section) {
            ForEach(SousSection.allCases) { section in
                Tab(section.title, systemImage: section.symbol, value: section) {
                    NavigationSplitView {
                        sectionColumn(section)
                            .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 520)
                    } detail: {
                        detail
                    }
                }
            }
        }
        .tabViewStyle(.tabBarOnly)
        // No window title: the tab bar already says where you are, and the
        // recipe is named by the list and the page both.
        .toolbar(removing: .title)
    }

    @ViewBuilder
    private func sectionColumn(_ section: SousSection) -> some View {
        switch section {
        case .recipes: RecipeListView()
        case .mealPlan: MealPlanView()
        case .shopping: ShoppingListView()
        }
    }

    @ViewBuilder
    private var detail: some View {
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
        // The floating bar along the top of an iPad, the bar along the foot
        // of a phone — but no sidebar. `.sidebarAdaptable` puts a button at
        // the left of the bar offering to open one, and the sidebar it opens
        // holds the same three entries and nothing else: an offer with
        // nothing behind it.
        .tabViewStyle(.tabBarOnly)
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
