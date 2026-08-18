import SousKit
import SwiftUI

struct RecipeListView: View {
    @Environment(RecipeLibrary.self) private var library
    @Environment(IngredientCatalogLibrary.self) private var catalog
    @Environment(RecipeSelection.self) private var selection
    /// Held by the app rather than here, because the menu bar issues the
    /// same commands and cannot see this view's state.
    @Environment(LibraryCommands.self) private var commands

    @State private var selectedRecipeID: Recipe.ID?
    /// Only the phone offers this: the Mac has the Settings scene behind
    /// Cmd-, and would otherwise reach the same form twice.
    @State private var isShowingSettings = false

    var body: some View {
        @Bindable var library = library
        @Bindable var commands = commands

        root
            .recipeImporter(isPresented: $commands.isImporting)
            .recipeExporter($commands.export)
            .sheet(item: $commands.panel) { panel in
                switch panel {
                case .catalog: IngredientCatalogView()
                case .categories: CategoryManagerView()
                case .trash: TrashView()
                }
            }
            #if os(iOS)
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
            }
            #endif
            .sheet(item: $library.editing) { recipe in
                RecipeEditorView(recipe: recipe) { edited in
                    await library.save(edited)
                    selectedRecipeID = edited.id
                }
            }
            // A draft the cook walked away from takes its pictures with it.
            .onChange(of: library.editing) { _, editing in
                if editing == nil { Task { await library.discardUnsavedDraft() } }
            }
            .alert(
                "Fehler",
                isPresented: Binding(
                    get: { library.errorMessage != nil },
                    set: { if !$0 { library.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { library.errorMessage = nil }
            } message: {
                Text(library.errorMessage ?? "")
            }
    }

    /// The Mac has one split view for the whole window, so this is only its
    /// first column; the phone brings its own stack and pushes into it.
    @ViewBuilder
    private var root: some View {
        #if os(macOS)
        list
        #else
        NavigationStack {
            list
                // Without this, tapping a row selected it and opened nothing:
                // a list with a selection but no destination goes nowhere.
                .navigationDestination(item: $selectedRecipeID) { id in
                    if let recipe = library.recipes.first(where: { $0.id == id }) {
                        RecipeDetailView(recipe: recipe)
                    }
                }
        }
        #endif
    }

    @ViewBuilder
    private var list: some View {
        @Bindable var library = library

        List(selection: $selectedRecipeID) {
            filterBar
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            ForEach(library.recipes) { recipe in
                RecipeRow(recipe: recipe)
                    .tag(recipe.id)
                    .contextMenu { contextActions(for: recipe) }
            }
        }
        // Without this the selected row is a solid slab of accent across the
        // whole width; a sidebar list draws its selection as a capsule.
        #if os(macOS)
        .listStyle(.sidebar)
        #endif
        .navigationTitle("Rezepte")
        // The system places it: the sidebar's own field on the Mac and iPad,
        // under the title on the phone. Ingredients and categories ride in it
        // as tokens, which is what the hand-built field was for.
        .searchable(
            text: $library.searchText,
            tokens: tokens,
            // Left to the system on purpose. `.sidebar` would be right on the
            // Mac and a guess on the phone, where this list is a stack and has
            // no sidebar to put it in.
            placement: .automatic,
            prompt: "Titel, Zutat, Kategorie"
        ) { filter in
            Label(
                filter.title,
                systemImage: filter.kind == .ingredient ? "carrot" : "tag"
            )
        }
        .searchSuggestions { filterSuggestions }
        .overlay { emptyState }
        .toolbar { listToolbar }
        .task { await library.reload() }
        // The selected row is what the detail column shows. Kept in sync
        // rather than held there, because the list wants an id for its
        // highlight and the column wants the recipe.
        .onChange(of: selectedRecipeID) { selection.recipe = selectedRecipe }
        .onChange(of: library.recipes) {
            if selectedRecipeID != nil { selection.recipe = selectedRecipe }
        }
    }

    private var selectedRecipe: Recipe? {
        library.recipes.first { $0.id == selectedRecipeID }
    }

    @ViewBuilder
    private var emptyState: some View {
        // An import in progress is about to fill the list; telling the user
        // there is nothing here while it counts up says the opposite.
        if library.recipes.isEmpty, !library.isLoading, library.importProgress == nil {
            if library.searchText.isEmpty, library.filter == .all, library.activeFilters.isEmpty {
                ContentUnavailableView {
                    Label("Noch keine Rezepte", systemImage: "book.closed")
                } description: {
                    Text("Lege dein erstes Rezept an.")
                } actions: {
                    Button("Rezept anlegen") { library.startNewRecipe() }
                }
            } else {
                ContentUnavailableView.search
            }
        }
    }

    @ViewBuilder
    private var filterBar: some View {
        @Bindable var library = library
        // Searching is the system's field now; this is the one thing it
        // cannot express — favourites and "will ich kochen" are not filters
        // that stack, they are three views of the same list.
        Picker("Filter", selection: $library.filter) {
            ForEach(RecipeLibrary.Filter.allCases, id: \.self) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        // macOS shows a segmented picker's label; iOS hides it. Without this
        // the word "Filter" sits in the sidebar beside the three choices.
        .labelsHidden()
        // Three choices stretched across an iPad is a rule with words on it.
        // The cap never bites on a phone, where the screen is narrower.
        .frame(maxWidth: 520, alignment: .leading)
    }

    /// The filters as the search field's tokens.
    ///
    /// Written back as a whole set rather than as add and remove, because
    /// that is what the field hands over: after a backspace it reports the
    /// list it has left, not which token went.
    private var tokens: Binding<[RecipeFilter]> {
        Binding(
            get: { library.activeFilters },
            set: { filters in Task { await library.setFilters(filters) } }
        )
    }

    /// What the typed text could be turned into, offered while typing.
    ///
    /// Says why something matched when its own name does not contain what was
    /// typed — otherwise "Gurke" appears for "sal" with no way to tell why.
    @ViewBuilder
    private var filterSuggestions: some View {
        ForEach(library.filterSuggestions(catalog: catalog.catalog)) { filter in
            Button {
                Task { await library.apply(filter) }
            } label: {
                HStack(spacing: 6) {
                    Label(
                        filter.title,
                        systemImage: filter.kind == .ingredient ? "carrot" : "tag"
                    )
                    if let matched = filter.matchedAs {
                        Text(matched)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var listToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Neues Rezept", systemImage: "plus") { library.startNewRecipe() }
        }
        // Everything in here is in the Mac's menu bar, which is always on
        // screen — so on the Mac the menu would be empty and is left out
        // entirely. The iPad keeps it: its menu bar waits behind a swipe from
        // the top edge or a keyboard being attached, and a command that only
        // lives there is hidden from anyone using the iPad with their fingers.
        #if os(iOS)
        ToolbarItem(placement: .automatic) {
            Menu("Mehr", systemImage: "ellipsis.circle") {
                Button("Zutaten verwalten", systemImage: "carrot") {
                    commands.panel = .catalog
                }
                Button("Kategorien verwalten", systemImage: "tag") {
                    commands.panel = .categories
                }
                Button("Papierkorb", systemImage: "trash") {
                    commands.panel = .trash
                }
                // No Settings entry on the Mac either — it has the Settings
                // scene behind Cmd-, — but this whole menu is gone there.
                Divider()
                Button("Einstellungen", systemImage: "gearshape") {
                    isShowingSettings = true
                }
                Divider()
                Button("Rezepte importieren", systemImage: "square.and.arrow.down") {
                    commands.isImporting = true
                }
                Button("Alle Rezepte exportieren", systemImage: "square.and.arrow.up") {
                    Task {
                        if let data = await library.exportedLibrary() {
                            commands.export = RecipeExport(
                                data: data,
                                name: "Rezepte",
                                contentType: RecipeExport.library
                            )
                        }
                    }
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private func contextActions(for recipe: Recipe) -> some View {
        Button("Bearbeiten", systemImage: "pencil") { library.editing = recipe }
        Button(
            recipe.isFavorite ? "Aus Favoriten entfernen" : "Zu Favoriten",
            systemImage: recipe.isFavorite ? "star.slash" : "star"
        ) {
            Task { await library.toggleFavorite(recipe) }
        }
        Button(
            recipe.wantToCook ? "Nicht mehr geplant" : "Will ich kochen",
            systemImage: "bookmark"
        ) {
            Task { await library.toggleWantToCook(recipe) }
        }
        Divider()
        Button("Löschen", systemImage: "trash", role: .destructive) {
            Task { await library.delete(recipe) }
        }
    }
}
