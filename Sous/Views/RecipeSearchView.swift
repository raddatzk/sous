import SousKit
import SwiftUI

/// The search tab: a place of its own rather than a second copy of the
/// library.
///
/// A tab owns its content, so the phone's search — which lives in the tab bar
/// since iOS 26 (`Tab(role: .search)`) — is always a second view. It used to
/// be the recipe list all over again, and that is what made opening the
/// search read as the list jumping to the top: it was a different list,
/// standing at its own beginning. This shows what search is for instead. The
/// categories to walk into before anything is typed, the hits once something
/// is — and the library in the recipes tab stays exactly where its reader
/// left it.
struct RecipeSearchView: View {
    @Environment(RecipeLibrary.self) private var library
    @Environment(IngredientCatalogLibrary.self) private var catalog

    /// The field's own text and chips, deliberately not the library's.
    /// `library.searchText` filters the list the recipes tab is showing, so
    /// typing here would rearrange a list nobody is looking at — and leave it
    /// somewhere else when they come back to it.
    @State private var text = ""
    @State private var filters: [RecipeFilter] = []

    @State private var results: [Recipe] = []
    /// Whether a query is on its way, so that the moment between a keystroke
    /// and its answer does not read as "nothing found".
    @State private var isSearching = false
    /// What there is to walk into before anything is typed.
    @State private var categories: [(name: String, count: Int)] = []
    /// The recipe pushed on top, kept as a path so that coming back is a
    /// thing this view can notice — a recipe renamed on that page has to be
    /// renamed in the hits behind it too.
    @State private var path: [Recipe] = []
    /// Ties a tapped row to the page it becomes, for the zoom.
    @Namespace private var zoomNamespace

    /// Whether anything has actually been asked. A field with only whitespace
    /// in it is not a question.
    private var isAsking: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || !filters.isEmpty
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                // Above whatever is below it, always: picking one filter is
                // how you find out you want a second one, and a surface that
                // vanishes on the first tap makes the second unreachable.
                offers
                content
            }
                .navigationTitle("Suchen")
                .navigationDestination(for: Recipe.self) { page(for: $0) }
                .searchable(
                    text: $text,
                    tokens: $filters,
                    prompt: "Titel, Zutat, Kategorie"
                ) { filter in
                    Label(filter.title, systemImage: filter.symbolName)
                }
                .searchSuggestions { suggestions }
        }
        // Read afresh every time the tab is opened — `task` runs on appear,
        // and a tab appears again on every switch back to it. A category the
        // cook gave a recipe in the meantime is therefore here, and counting
        // them is one pass over a library, not a thing worth caching.
        .task { categories = await library.categoryCounts() }
        .task(id: Question(text: text, filters: filters)) { await search() }
        .onChange(of: path) { _, path in
            // Back from a recipe: it may have been renamed, retitled or
            // deleted on that page, and the row behind it would still say
            // what it said before.
            if path.isEmpty { Task { await search() } }
        }
    }

    /// What the tab shows below the offers: the hits once something was
    /// asked, and otherwise an empty page with the ways in above it.
    @ViewBuilder
    private var content: some View {
        if isAsking {
            if results.isEmpty, !isSearching {
                nothingFound
            } else {
                hits
            }
        } else {
            ContentUnavailableView {
                Label("Suchen", systemImage: "magnifyingglass")
            } description: {
                Text("Tippe einen Titel oder eine Zutat — oder nimm eine Mahlzeit oder Kategorie von oben.")
            }
        }
    }

    /// Why a search can come back empty, said where it is actually asked.
    @ViewBuilder
    private var nothingFound: some View {
        if filters.contains(where: { $0.kind == .slot }) {
            ContentUnavailableView {
                Label("Keine Treffer", systemImage: "magnifyingglass")
            } description: {
                // The one filter here that can be silently thin, so it says
                // so rather than leaving an empty list to be puzzled over.
                Text("Nach Mahlzeit finden sich nur Rezepte, bei denen sie im Rezept steht oder schon geschätzt wurde.")
            }
        } else {
            ContentUnavailableView.search
        }
    }

    private var hits: some View {
        List(results) { recipe in
            NavigationLink(value: recipe) {
                RecipeRow(recipe: recipe)
            }
            // The page grows out of the row that was tapped, the same way it
            // does in the library.
            #if os(iOS)
            .matchedTransitionSource(id: recipe.id, in: zoomNamespace)
            #endif
        }
    }

    /// The page a hit opens.
    ///
    /// The zoom is the phone's — the Mac searches in its sidebar and never
    /// builds this view, and the transition does not exist there.
    @ViewBuilder
    private func page(for recipe: Recipe) -> some View {
        RecipeDetailView(recipe: recipe)
            #if os(iOS)
            .navigationTransition(.zoom(sourceID: recipe.id, in: zoomNamespace))
            #endif
    }

    /// The ways in, as chips that stay put: the three meals first, then
    /// every category the library has.
    ///
    /// They stay whether or not anything is already picked, and they toggle
    /// — that is what makes "Pasta" and "Abend" a thing you can ask together,
    /// and what makes a wrong tap undoable without going through the field.
    /// The typed text still narrows further; nothing here clears it.
    @ViewBuilder
    private var offers: some View {
        VStack(alignment: .leading, spacing: 8) {
            chipRow {
                ForEach(MealSlot.allCases, id: \.self) { slot in
                    chip(.slot(slot))
                }
            }
            if !categories.isEmpty {
                chipRow {
                    ForEach(categories, id: \.name) { category in
                        chip(.category(category.name), count: category.count)
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .background(alignment: .bottom) { Divider() }
    }

    /// One line of chips that scrolls sideways rather than wrapping: two
    /// rows of these sit above everything else on the page, and a wrapping
    /// cloud of twenty categories would push the hits off the screen.
    private func chipRow(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                content()
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    /// One filter, held or offered. The count is what the category is worth
    /// — dropped once it is picked, where the hits below say it better.
    private func chip(_ filter: RecipeFilter, count: Int? = nil) -> some View {
        let isOn = filters.contains(filter)
        return Button {
            if let index = filters.firstIndex(of: filter) {
                filters.remove(at: index)
            } else {
                filters.append(filter)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: filter.symbolName)
                Text(filter.title)
                if let count, !isOn {
                    Text("\(count)")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.subheadline)
            .sousToggleChip(isOn: isOn)
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.2), value: isOn)
    }

    /// What the typed text could be turned into, offered while typing.
    ///
    /// Says why something matched when its own name does not contain what was
    /// typed — otherwise "Gurke" appears for "sal" with no way to tell why.
    @ViewBuilder
    private var suggestions: some View {
        ForEach(
            RecipeFilter.suggestions(
                for: text,
                catalog: catalog.catalog,
                categories: library.categories,
                applied: filters,
                limit: 8
            )
        ) { filter in
            Button {
                filters.append(filter)
                text = ""
            } label: {
                HStack(spacing: 6) {
                    Label(filter.title, systemImage: filter.symbolName)
                    if let matched = filter.matchedAs {
                        Text(matched)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// What was asked, as one value — so that `task(id:)` starts over on a
    /// keystroke and cancels the question that is no longer being asked.
    private struct Question: Equatable {
        let text: String
        let filters: [RecipeFilter]
    }

    private func search() async {
        guard isAsking else {
            results = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        // A keystroke is not a question. Typing is faster than the store can
        // answer, and every letter would otherwise cost a query — the sleep
        // is cancelled by the next one before it ever reaches the store.
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        results = await library.findRecipes(matching: text, filters: filters)
    }
}
