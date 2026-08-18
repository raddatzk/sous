import SousKit
import SwiftUI

/// Picks another recipe to link to.
struct RecipePickerView: View {
    @Environment(RecipeLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    /// Shown as the title, since the picker both links and plans.
    var title = "Rezept verlinken"
    /// The recipe being edited, so it cannot link to itself.
    let excluding: Recipe.ID
    let onPick: (Recipe) -> Void

    @State private var searchText = ""
    @State private var results: [Recipe] = []

    var body: some View {
        NavigationStack {
            List(results) { recipe in
                VStack(alignment: .leading, spacing: 2) {
                    Text(recipe.title)
                        .font(SousStyle.recipeName)
                    if !recipe.categories.isEmpty {
                        Text(recipe.categories.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .onTapGesture {
                    onPick(recipe)
                    dismiss()
                }
            }
            .navigationTitle(title)
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
        #elseif os(iOS)
        .presentationDetents([.medium])
        #endif
    }

    private func reload() async {
        results = await library.findRecipes(matching: searchText)
            .filter { $0.id != excluding }
    }
}
