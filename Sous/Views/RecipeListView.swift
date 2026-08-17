import SousKit
import SwiftUI

struct RecipeListView: View {
    @Environment(RecipeLibrary.self) private var library
    @State private var selectedRecipeID: Recipe.ID?

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
            .searchable(text: $library.searchText, prompt: "Titel, Zutat, Kategorie")
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
        if library.recipes.isEmpty, !library.isLoading {
            if library.searchText.isEmpty, library.filter == .all, library.selectedCategory == nil {
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
        VStack(spacing: 8) {
            Picker("Filter", selection: $library.filter) {
                ForEach(RecipeLibrary.Filter.allCases, id: \.self) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            if !library.categories.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(library.categories, id: \.self) { category in
                            CategoryChip(
                                title: category,
                                isSelected: library.selectedCategory == category
                            ) {
                                library.selectedCategory =
                                    library.selectedCategory == category ? nil : category
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    @ToolbarContentBuilder
    private var listToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Neues Rezept", systemImage: "plus") { library.startNewRecipe() }
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

private struct RecipeRow: View {
    let recipe: Recipe

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let imageID = recipe.imageIDs.first {
                RecipeImageView(imageID: imageID, thumbnail: true)
                    .frame(width: 52, height: 52)
                    .clipShape(.rect(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
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
        .padding(.vertical, 2)
    }

    private var subtitle: String? {
        var parts = recipe.categories
        if let minutes = totalMinutes {
            parts.append("\(minutes) Min.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var totalMinutes: Int? {
        let seconds = (recipe.prepTimeSeconds ?? 0) + (recipe.cookTimeSeconds ?? 0)
        return seconds > 0 ? seconds / 60 : nil
    }
}

private struct CategoryChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: .capsule)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    }
}
