import SousKit
import SwiftUI

/// The three places the app is used from: the library, the week ahead, and
/// what to buy for it — with whatever is on the hob riding above all three.
struct RootView: View {
    @Environment(CookSession.self) private var session
    @Environment(RecipeSelection.self) private var selection
    @Environment(NutritionLibrary.self) private var nutrition
    @Environment(DataUpdateNotice.self) private var dataUpdate
    @Environment(OnboardingNotice.self) private var onboarding
    @Environment(RecipeLibrary.self) private var library
    @Environment(MealPlanLibrary.self) private var plan
    @Environment(ShoppingLibrary.self) private var shopping
    @Environment(LibraryCommands.self) private var commands
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    #endif

    /// Which of the three is showing — held above the views so that an App
    /// Intent ("Öffne die Einkaufsliste") or a Spotlight hit can steer it.
    @Environment(SousNavigation.self) private var navigation
    /// Whether the collected "was ist verwaist" sheet is up.
    @State private var isClarifyingOrphans = false

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

    /// The mappings a data update took the ground out from under, read live
    /// so the band shortens as they are answered and goes away entirely once
    /// they are.
    ///
    /// Empty unless *this* launch found them: the notice belongs to the
    /// moment the data changed. Afterwards the questions stay exactly where
    /// they were already visible — in the recipes that use them — rather than
    /// becoming a permanent band at the top of the app.
    private var orphaned: [NutritionCoverage.OpenIngredient] {
        dataUpdate.isShowing ? nutrition.orphanedIngredients : []
    }

    /// What decision D allows the app to say after a data update, and the
    /// only thing: which mappings lost their row. Changed numbers are never
    /// mentioned — they flowed into the sums silently, which is the decision.
    private var orphanBand: some View {
        HStack(spacing: 12) {
            Label(
                orphaned.count == 1
                    ? "1 Zuordnung ist nach der Datenaktualisierung verwaist"
                    : "\(orphaned.count) Zuordnungen sind nach der Datenaktualisierung verwaist",
                systemImage: "exclamationmark.arrow.triangle.2.circlepath"
            )
            .font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
            Button("Zuordnen") { isClarifyingOrphans = true }
                .buttonStyle(.borderedProminent)
            Button("Später") { dataUpdate.isDismissed = true }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.sousSurface)
    }

    var body: some View {
        @Bindable var session = session
        @Bindable var onboarding = onboarding

        VStack(spacing: 0) {
            // The Mac keeps the band above the window's content. On iOS it
            // rides the tab bar instead — see `sections` — where it neither
            // shortens every tab nor sits loose under the status bar.
            #if os(macOS)
            if showsBanner {
                ContinueCookingBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            #endif
            if !orphaned.isEmpty {
                orphanBand
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            sections
        }
        .animation(.easeInOut(duration: 0.2), value: showsBanner)
        .animation(.easeInOut(duration: 0.2), value: orphaned.count)
        // The libraries every screen writes to report here, above the
        // sections, because the write and the screen that would show its
        // failure are rarely the same: a recipe page puts a dish on the
        // shopping list, a picker adds it to the plan. On the Mac only one
        // section is mounted at a time, and on the phone a tab not yet
        // visited has no view at all — an alert bound inside the section
        // would be silent exactly when the write happened.
        .sousErrorAlert(library)
        .sousErrorAlert(plan)
        .sousErrorAlert(shopping)
        .sousErrorAlert(nutrition)
        // The welcome, on the first launch of an app with nothing in it —
        // and above everything, because it is about the whole app rather
        // than the section that happens to be showing.
        //
        // `onDismiss` rather than a callback: it fires for the swipe as well
        // as for "Fertig", and both mean the same thing. It is also the
        // moment the welcome's own buttons can be honoured — a file dialog
        // opened out of a sheet that is still dismissing never appears.
        .sheet(isPresented: $onboarding.isShowing, onDismiss: finishOnboarding) {
            OnboardingView()
        }
        .sheet(isPresented: $isClarifyingOrphans) {
            IngredientClarificationSheet(open: orphaned) {
                // Nothing to recompute: unlike the recipe page, this sheet
                // shows no figures of its own, and the list it does show is
                // read live off the vocabulary that every answer has just
                // rewritten. It shortens by itself.
            }
        }
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

    /// Marks the welcome as seen and does whatever its last tap asked for.
    ///
    /// Both follow-ups are presented by the recipe list, so the section is
    /// set first: on the phone the importer belongs to a tab that is not
    /// mounted while the shopping list is showing, and a dialog with nobody
    /// to present it is a button that did nothing.
    private func finishOnboarding() {
        onboarding.finish()
        switch onboarding.followUp {
        case .importing:
            navigation.section = .recipes
            commands.isImporting = true
        case .newRecipe:
            navigation.section = .recipes
            library.startNewRecipe()
        case nil:
            break
        }
        onboarding.followUp = nil
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
                switch navigation.section {
                // Search is the phone's fourth tab; here it can only arrive
                // by state synced from elsewhere, and the recipes list with
                // the sidebar's search field is what it means.
                case .recipes, .search: RecipeListView()
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
            switch selection.target {
            case .recipe(let recipe):
                RecipeDetailView(recipe: recipe, plannedEntryID: selection.plannedEntryID)
            // The one thing in this column that is not a recipe. It cannot be
            // planned, bought or cooked from here — all three need a version
            // of the dish, and this page is where one is picked.
            case .group(let group, let mode):
                VariantGroupView(group: group, initialMode: mode)
            case nil:
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
        // Below this the list column and a recipe page stop being readable
        // side by side — and without a stated minimum the window can be
        // dragged down to a title bar.
        .frame(minWidth: 760, minHeight: 520)
        // And no way to collapse the sidebar. In a mail client the sidebar is
        // a place you can put away once you are reading; here it is the only
        // way into anything — collapse it and the window is a recipe with no
        // route to another one. The width can still be dragged, down to the
        // minimum the column asks for.
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            // One button per section, the way Mail carries its categories:
            // the one you are in is a filled capsule with its name, the other
            // two are quiet buttons showing only their symbol. Pressing one
            // widens it into its name while the one you left shrinks back to
            // its symbol.
            //
            // Three items rather than one group: a group is drawn as a single
            // capsule, which put the calendar and the trolley in one pill as
            // though they belonged together. Written out one by one because
            // `ForEach` is not toolbar content — there is no way to loop here.
            // One item holding all three, so the gaps between them are ours
            // to set. As separate items they sat flush against each other,
            // with no say in the spacing.
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    sectionButton(.recipes)
                    sectionButton(.mealPlan)
                    sectionButton(.shopping)
                }
            }
        }
    }

    /// One section's button: symbol and name, always both.
    ///
    /// Mail's shape — the section you are in wide with its name, the others
    /// narrow with only their symbol — was tried and given up. Two of the
    /// three transitions animated and the third landed in a single frame,
    /// and no amount of moving the animation about changed it: the toolbar
    /// rebuilds that item rather than animating it, which is not something
    /// SwiftUI can reach.
    ///
    /// So nothing changes shape. Every button keeps its width whatever is
    /// selected, and only the fill moves — a thing that cannot tear, because
    /// there is no layout in it. It also answers the objection that started
    /// this: a book, a calendar and a trolley are a guessing game, and now
    /// all three names are readable all the time.
    @ViewBuilder
    private func sectionButton(_ item: SousSection) -> some View {
        let isActive = item == navigation.section

        Button {
            navigation.section = item
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.symbol)
                    // One width for three symbols of three shapes, so they
                    // line up with each other.
                    .frame(width: 16)
                Text(item.title)
            }
        }
        .buttonStyle(SectionButtonStyle(isActive: isActive))
        .animation(.smooth(duration: 0.2), value: isActive)
    }

    #else
    @ViewBuilder
    private var sections: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.section) {
            ForEach(SousSection.mainSections) { section in
                Tab(section.title, systemImage: section.symbol, value: section) {
                    switch section {
                    // The recipes tab reads; searching lives in the search
                    // tab and has a view of its own. Keeping `searchable`
                    // off this instance is what lets its collapsed title sit
                    // centered like every other native bar — a nav-bar
                    // search field pushes it into the leading edge.
                    case .recipes: RecipeListView(showsSearch: false)
                    case .mealPlan: MealPlanView()
                    case .shopping: ShoppingListView()
                    case .search: RecipeSearchView()
                    }
                }
            }
            // The system search circle beside the tab bar — where a tabbed
            // app's search lives on iOS 26, instead of a magnifier crammed
            // into the recipes bar. What stands behind it is a search, not
            // the library again: see ``RecipeSearchView``.
            Tab(value: SousSection.search, role: .search) {
                RecipeSearchView()
            }
        }
        // The floating bar along the top of an iPad, the bar along the foot
        // of a phone — but no sidebar. `.sidebarAdaptable` puts a button at
        // the left of the bar offering to open one, and the sidebar it opens
        // holds the same three entries and nothing else: an offer with
        // nothing behind it.
        .tabViewStyle(.tabBarOnly)
        // The way back to the hob, docked to the tab bar the way Musik
        // docks its player: it floats with the bar and takes no height from
        // the tabs, instead of the hand-made capsule that used to sit above
        // everything.
        // `isEnabled:`, not an `if` inside the builder: the glass capsule
        // is drawn by the tab bar for the accessory itself, so a builder
        // that produces nothing still leaves an empty capsule floating
        // above the tabs of an idle app.
        .tabViewBottomAccessory(isEnabled: showsBanner) {
            ContinueCookingBanner()
        }
    }
    #endif
}

#if os(macOS)
/// The section buttons' look, as one style rather than two.
///
/// `borderedProminent` insists on a white label whatever it is tinted with,
/// which on the pale grey of an inactive section left a white book on a white
/// field. Two different button styles would fix the colour and lose the
/// animation, since SwiftUI would then be swapping one view for another rather
/// than widening one — so the style takes the state instead and the view stays
/// put.
private struct SectionButtonStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(isActive ? .semibold : .regular))
            .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            // Only the section you are in carries a fill. macOS already draws
            // a capsule around the whole group, and a grey capsule inside a
            // white one inside the window was three layers saying one thing.
            .background(
                isActive ? AnyShapeStyle(Color.sousAccent) : AnyShapeStyle(.clear),
                in: .capsule
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
#endif

/// Which of the three places the app is standing in.
///
/// App state rather than view state, for the same reason the selection is:
/// an App Intent has no view to ask, and "Öffne die Einkaufsliste" has to
/// land somewhere that outlives whichever tab was open.
@MainActor
@Observable
final class SousNavigation {
    var section: SousSection = .recipes
    /// A recipe the shopping list should scroll to as it comes up.
    ///
    /// Cleared by the list once it has acted on it, so that coming back to
    /// the tab later does not jump somewhere the cook did not ask for.
    var shoppingRecipeID: UUID?

    /// Shows the shopping list, standing at `recipeID`.
    ///
    /// Where a recipe already on the list is read, the question is no longer
    /// "shall I buy this" but "how much of it" — and the portion dial that
    /// answers it lives on the list, under that recipe's own heading.
    func showShoppingList(for recipeID: UUID) {
        shoppingRecipeID = recipeID
        section = .shopping
    }
}

/// The three places the app is used from, named once so the tab bar and the
/// Mac's switch cannot drift apart on wording or order.
enum SousSection: String, CaseIterable, Identifiable {
    case recipes
    case mealPlan
    case shopping
    /// The search tab: the system search circle beside the tab bar
    /// (`Tab(role: .search)`), the way every tabbed Apple app carries its
    /// search since iOS 26.
    ///
    /// The phone and the iPad both have it, since both carry the tab bar —
    /// on the iPad the circle sits at the end of the floating bar along the
    /// top and opens its field there. Only the Mac never shows this section:
    /// it searches in the sidebar's own field, and a section arriving there
    /// by synced state means the recipe list.
    case search

    var id: String { rawValue }

    /// The sections that are destinations of their own — what the Mac's
    /// sidebar and the phone's main tabs list. Search is not among them:
    /// it is a mode over the recipes, not a fourth place.
    static let mainSections: [SousSection] = [.recipes, .mealPlan, .shopping]

    var title: String {
        switch self {
        case .recipes: "Rezepte"
        case .mealPlan: "Essensplan"
        case .shopping: "Einkaufsliste"
        case .search: "Suchen"
        }
    }

    var symbol: String {
        switch self {
        case .recipes: "book.closed"
        case .mealPlan: "calendar"
        case .shopping: "cart"
        case .search: "magnifyingglass"
        }
    }
}
