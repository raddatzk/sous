import SousKit
import SwiftUI

struct RecipeListView: View {
    @Environment(RecipeLibrary.self) private var library
    @State private var selectedRecipeID: Recipe.ID?
    @State private var isShowingCatalog = false
    @State private var isShowingCategories = false
    @State private var isShowingTrash = false
    /// Only the phone offers this: the Mac has the Settings scene behind
    /// Cmd-, and would otherwise reach the same form twice.
    @State private var isShowingSettings = false
    @State private var isImporting = false
    @State private var export: RecipeExport?

    var body: some View {
        @Bindable var library = library

        #if os(macOS)
        NavigationSplitView {
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
        } detail: {
            if let recipe = selectedRecipe {
                RecipeDetailView(recipe: recipe)
            } else {
                ContentUnavailableView(
                    "Kein Rezept ausgewählt",
                    systemImage: "fork.knife",
                    description: Text("Wähle links ein Rezept aus.")
                )
            }
        }
        .task { await library.reload() }
        .recipeImporter(isPresented: $isImporting)
        .recipeExporter($export)
        .sheet(isPresented: $isShowingCatalog) {
            IngredientCatalogView()
        }
        .sheet(isPresented: $isShowingCategories) {
            CategoryManagerView()
        }
        .sheet(isPresented: $isShowingTrash) {
            TrashView()
        }
        .sheet(item: $library.editing) { recipe in
            RecipeEditorView(recipe: recipe) { edited in
                await library.save(edited)
                selectedRecipeID = edited.id
            }
        }
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
        #else
        NavigationStack {
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
        }
        .recipeImporter(isPresented: $isImporting)
        .recipeExporter($export)
        .sheet(isPresented: $isShowingCatalog) {
            IngredientCatalogView()
        }
        .sheet(isPresented: $isShowingCategories) {
            CategoryManagerView()
        }
        .sheet(isPresented: $isShowingTrash) {
            TrashView()
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .sheet(item: $library.editing) { recipe in
            RecipeEditorView(recipe: recipe) { edited in
                await library.save(edited)
                selectedRecipeID = edited.id
            }
        }
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
        #endif
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
                Divider()
                Button("Rezepte importieren", systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
                Button("Alle Rezepte exportieren", systemImage: "square.and.arrow.up") {
                    Task {
                        if let data = await library.exportedLibrary() {
                            export = RecipeExport(
                                data: data,
                                name: "Rezepte",
                                contentType: RecipeExport.library
                            )
                        }
                    }
                }
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
