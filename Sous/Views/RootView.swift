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

    /// One section's button, wide with its name or narrow with its symbol.
    ///
    /// One button whose label changes, not two buttons swapped for each
    /// other. The first attempt branched on the active section and gave each
    /// branch its own style, so SwiftUI replaced one view with another — and
    /// a view that is replaced cannot grow. At sixty frames a second the
    /// change happened inside a single frame.
    ///
    /// The tint carries the difference instead: the accent while this is the
    /// section you are in, the app's neutral field colour otherwise.
    @ViewBuilder
    private func sectionButton(_ item: SousSection) -> some View {
        let isActive = item == section

        Button {
            section = item
        } label: {
            HStack(spacing: 6) {
                // A fixed width so the narrow buttons match each other. A
                // book, a calendar and a trolley are not the same shape, and
                // left to themselves they made three capsules of three widths
                // where Mail has three of one.
                Image(systemName: item.symbol)
                    .frame(width: 16)
                if isActive {
                    Text(item.title)
                        .fixedSize()
                }
            }
            // Centred in a width that does not depend on the word: the row
            // keeps its length whichever section is open, so the buttons
            // beside this one stop sliding sideways, and the symbol sits in
            // the middle of what it shares the capsule with rather than being
            // pushed about by the length of a name.
            //
            // A number rather than the widest name measured. The measured
            // version laid out all three names and hid two, and SwiftUI faded
            // the hidden ones in during a switch — three words on top of each
            // other for a fifth of a second.
            .frame(width: isActive ? 132 : 16)
        }
        .buttonStyle(SectionButtonStyle(isActive: isActive))
        // The animation belongs to the button rather than to the press that
        // changed the section. Wrapped in `withAnimation` at the call site it
        // rode on the transaction, and the toolbar swallowed that on at least
        // one pair — Essensplan to Einkaufsliste changed inside a single frame
        // while the others took thirteen. Tied to `isActive`, each button
        // animates its own width and fill whoever moved them.
        .animation(.smooth(duration: 0.3), value: isActive)
        // While a button is narrow, this is the only thing that says which
        // section it is.
        .help(item.title)
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
