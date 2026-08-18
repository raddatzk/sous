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
                // A button rather than a tap gesture: the pointer changes
                // over it, the keyboard reaches it, and the Mac gets the
                // click it expects.
                Button {
                    onPick(recipe)
                    dismiss()
                } label: {
                    RecipeRow(recipe: recipe)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
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
        .sousSheetSizing(.form)
    }

    private func reload() async {
        results = await library.findRecipes(matching: searchText)
            .filter { $0.id != excluding }
    }
}
