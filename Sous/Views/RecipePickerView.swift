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
    /// Why a recipe cannot be picked, for the pickers where some cannot.
    ///
    /// Shown beside the row rather than hidden from the list: a recipe the
    /// cook is looking for and cannot find is a worse answer than one that
    /// says what stands in the way.
    var unavailable: ((Recipe) -> String?)?
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
                    VStack(alignment: .leading, spacing: 2) {
                        RecipeRow(recipe: recipe)
                        if let reason = unavailable?(recipe) {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(unavailable?(recipe) != nil)
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
