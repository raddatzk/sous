import SousKit
import SwiftUI

/// Picks another recipe to link to.
struct RecipePickerView: View {
    @Environment(RecipeLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    /// The recipe being edited, so it cannot link to itself.
    let excluding: Recipe.ID
    let onPick: (Recipe) -> Void

    @State private var searchText = ""
    @State private var results: [Recipe] = []

    var body: some View {
        NavigationStack {
            List(results) { recipe in
                Button {
                    onPick(recipe)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recipe.title)
                        if !recipe.categories.isEmpty {
                            Text(recipe.categories.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Rezept verlinken")
            .searchable(text: $searchText, prompt: "Rezept suchen")
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView(
                        "Kein Rezept gefunden",
                        systemImage: "magnifyingglass"
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        .task { await reload() }
        .task(id: searchText) { await reload() }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
    }

    private func reload() async {
        results = await library.findRecipes(matching: searchText)
            .filter { $0.id != excluding }
    }
}
