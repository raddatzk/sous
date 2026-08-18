import SousKit
import SwiftUI

struct RecipeListView: View {
    @Environment(RecipeLibrary.self) private var library
    @State private var selectedRecipeID: Recipe.ID?
    @State private var isShowingCatalog = false
    @State private var isShowingCategories = false
    @State private var isImporting = false

    var body: some View {
        @Bindable var library = library

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
        .sheet(isPresented: $isShowingCatalog) {
            IngredientCatalogView()
        }
        .sheet(isPresented: $isShowingCategories) {
            CategoryManagerView()
        }
        .sheet(item: $library.editing) { recipe in
            RecipeEditorView(recipe: recipe) { edited in
                await library.save(edited)
                selectedRecipeID = edited.id
            }
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
                Divider()
                Button("Aus Mela importieren", systemImage: "square.and.arrow.down") {
                    isImporting = true
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

/// One recipe as a card in the list: what it looks like, what it is called,
/// how long it takes, and what it is filed under.
///
/// The picture keeps its slot even when a recipe has none, so titles line up
/// down the list instead of stepping in and out. Time and categories share
/// one row of chips: they answer the same question — is this the right thing
/// to cook tonight — and separate lines for each would make every row tall
/// enough that only a handful fit on screen.
private struct RecipeRow: View {
    let recipe: Recipe

    /// Enough to say what a recipe is; more would push the rows apart.
    private static let visibleCategories = 3

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(recipe.title)
                        .font(SousStyle.recipeName)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    markers
                }
                attributes
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let imageID = recipe.imageIDs.first {
                RecipeImageView(imageID: imageID, thumbnail: true)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "fork.knife")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 68, height: 68)
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var markers: some View {
        if recipe.isFavorite {
            Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
                .imageScale(.small)
        }
        if recipe.wantToCook {
            Image(systemName: "bookmark.fill")
                .foregroundStyle(.tint)
                .imageScale(.small)
        }
    }

    /// The time first — it decides whether a recipe fits the evening — then
    /// what it is filed under.
    @ViewBuilder
    private var attributes: some View {
        let shown = recipe.categories.prefix(Self.visibleCategories)
        let hidden = recipe.categories.count - shown.count
        if totalMinutes != nil || !shown.isEmpty {
            FlowLayout(spacing: 5, lineSpacing: 5) {
                if let minutes = totalMinutes {
                    chip("\(minutes) Min.", systemImage: "clock", tinted: false)
                }
                ForEach(Array(shown), id: \.self) { category in
                    chip(category)
                }
                if hidden > 0 {
                    chip("+\(hidden)")
                }
            }
        }
    }

    private func chip(
        _ text: String,
        systemImage: String? = nil,
        tinted: Bool = true
    ) -> some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2)
            }
            Text(text)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            tinted ? AnyShapeStyle(.tint.opacity(0.13)) : AnyShapeStyle(.quaternary.opacity(0.6)),
            in: .capsule
        )
        .foregroundStyle(tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }

    private var totalMinutes: Int? {
        let seconds = (recipe.prepTimeSeconds ?? 0) + (recipe.cookTimeSeconds ?? 0)
        return seconds > 0 ? seconds / 60 : nil
    }
}
