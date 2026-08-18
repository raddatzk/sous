import SousKit
import SwiftUI

struct RecipeListView: View {
    @Environment(RecipeLibrary.self) private var library
    @Environment(RecipeSelection.self) private var selection
    /// Held by the app rather than here, because the Mac starts both from
    /// the menu bar, which cannot see this view's state.
    @Environment(LibraryExchange.self) private var exchange

    @State private var selectedRecipeID: Recipe.ID?
    @State private var isShowingCatalog = false
    @State private var isShowingCategories = false
    @State private var isShowingTrash = false
    /// Only the phone offers this: the Mac has the Settings scene behind
    /// Cmd-, and would otherwise reach the same form twice.
    @State private var isShowingSettings = false

    var body: some View {
        @Bindable var library = library
        @Bindable var exchange = exchange

        root
            .recipeImporter(isPresented: $exchange.isImporting)
            .recipeExporter($exchange.export)
            .sheet(isPresented: $isShowingCatalog) {
                IngredientCatalogView()
            }
            .sheet(isPresented: $isShowingCategories) {
                CategoryManagerView()
            }
            .sheet(isPresented: $isShowingTrash) {
                TrashView()
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
        .navigationTitle("Rezepte")
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
        VStack(spacing: 10) {
            RecipeSearchField()

            Picker("Filter", selection: $library.filter) {
                ForEach(RecipeLibrary.Filter.allCases, id: \.self) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)

        }
    }

    @ToolbarContentBuilder
    private var listToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Neues Rezept", systemImage: "plus") { library.startNewRecipe() }
        }
        ToolbarItem(placement: .automatic) {
            Menu("Mehr", systemImage: "ellipsis.circle") {
                Button("Zutaten verwalten", systemImage: "carrot") {
                    isShowingCatalog = true
                }
                Button("Kategorien verwalten", systemImage: "tag") {
                    isShowingCategories = true
                }
                Button("Papierkorb", systemImage: "trash") {
                    isShowingTrash = true
                }
                #if os(iOS)
                // The Mac has the Settings scene behind Cmd-, and would
                // otherwise offer the same form twice.
                Divider()
                Button("Einstellungen", systemImage: "gearshape") {
                    isShowingSettings = true
                }
                #endif
                #if os(iOS)
                // The Mac has these in the Ablage menu, where it looks for
                // them; the phone has no menu bar and keeps them here.
                Divider()
                Button("Rezepte importieren", systemImage: "square.and.arrow.down") {
                    exchange.isImporting = true
                }
                Button("Alle Rezepte exportieren", systemImage: "square.and.arrow.up") {
                    Task {
                        if let data = await library.exportedLibrary() {
                            exchange.export = RecipeExport(
                                data: data,
                                name: "Rezepte",
                                contentType: RecipeExport.library
                            )
                        }
                    }
                }
                #endif
            }
        }
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
