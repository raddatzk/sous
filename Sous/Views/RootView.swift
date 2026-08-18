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
        // One split view for the whole window, so every section has the same
        // shape: what to work through on the left, the recipe being read on
        // the right.
        //
        // And nothing above it. A split view that is not the window's root
        // gets neither a proper sidebar width nor a toolbar of its own — it
        // came out about half as wide as it should be, and the toolbar's
        // buttons had nowhere to sit and collapsed into an overflow chevron.
        NavigationSplitView {
            Group {
                switch section {
                case .recipes: RecipeListView()
                case .mealPlan: MealPlanView()
                case .shopping: ShoppingListView()
                }
            }
            // Wider than it first looked: at 320 the meal plan's day rows had
            // the weekday, the date and the menu that adds a meal all fighting
            // for the same line, and the view switch above them sat shoulder
            // to shoulder with "Heute". The recipe rows want the room too.
            .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 520)
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
        // No window title at all. It would say the app's name beside a
        // section switch that already says where you are, or repeat a recipe
        // the list and the page have both named — either way a word in the
        // title bar that nothing needed.
        .toolbar(removing: .title)
        .toolbar {
            // Beside the traffic lights and the sidebar button, where macOS 26
            // draws it as the floating capsule the iPad has along its top.
            ToolbarItem(placement: .navigation) {
                Picker("Bereich", selection: $section) {
                    ForEach(SousSection.allCases) { section in
                        // The name, not the symbol. A segmented picker built
                        // from `Label`s shows the icon alone on macOS, and a
                        // book, a calendar and a trolley are a guessing game
                        // where three words are not.
                        Text(section.title)
                            .tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
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
