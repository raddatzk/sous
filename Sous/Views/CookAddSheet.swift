import SousKit
import SwiftUI

/// Putting another pot on: which recipe, and for how many.
///
/// The list is the one from the library, rows and all — a recipe is picked
/// the same way here as anywhere else in the app. Only the serving count is
/// asked for on top, because a recipe joining halfway through a session has
/// none the cook has already chosen, and correcting it afterwards would mean
/// leaving the kitchen again.
struct CookAddSheet: View {
    @Environment(RecipeLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    /// What is already on the hob. Offering it again would either do nothing
    /// or quietly reset the pot that is already cooking.
    let excluding: Set<Recipe.ID>
    /// Recipes the pots already on the hob refer to. Offered above the
    /// library, because somebody adding a second pot while a curry cooks is
    /// far likelier to want its naan than anything else they own — and
    /// because they may be here precisely after waving that offer away in
    /// cook mode.
    var suggesting: [Recipe] = []
    let onAdd: (Recipe, Int) -> Void

    @State private var searchText = ""
    @State private var results: [Recipe] = []
    /// The recipe whose servings are being set, if that sheet is open.
    @State private var picked: Recipe?

    /// The suggestions worth showing: not already cooking, and not repeated
    /// where two pots refer to the same recipe.
    private var offered: [Recipe] {
        var seen = Set<Recipe.ID>()
        return suggesting.filter {
            !excluding.contains($0.id) && seen.insert($0.id).inserted
        }
    }

    /// One pickable recipe.
    ///
    /// A button rather than a tap gesture: the pointer changes over it, the
    /// keyboard reaches it, and the Mac gets the click it expects.
    private func row(_ recipe: Recipe) -> some View {
        Button {
            picked = recipe
        } label: {
            RecipeRow(recipe: recipe)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        NavigationStack {
            List {
                // Only while nobody is searching: a cook who typed a name is
                // looking for that one, and a section above the answer would
                // be in the way of it.
                if searchText.isEmpty, !offered.isEmpty {
                    Section {
                        ForEach(offered) { recipe in
                            row(recipe)
                        }
                    } header: {
                        Text("Gehört zu dem, was schon kocht").sousGroupHeader()
                    }
                }
                Section {
                    ForEach(results) { recipe in
                        row(recipe)
                    }
                }
            }
            .navigationTitle("Rezept dazunehmen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $searchText, prompt: "Titel, Zutat, Kategorie")
            .overlay { emptyState }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
            }
        }
        // Over the list rather than pushed onto it: the question is one
        // number, and answering it should not feel like a second screen.
        .sheet(item: $picked) { recipe in
            ServingsStep(recipe: recipe) { servings in
                onAdd(recipe, servings)
                picked = nil
                dismiss()
            }
        }
        .task { await reload() }
        .task(id: searchText) { await reload() }
        .sousSheetSizing(.page)
    }

    /// Nothing left to offer reads differently from nothing found: the first
    /// is a kitchen that is full, the second a search that missed.
    @ViewBuilder
    private var emptyState: some View {
        if results.isEmpty {
            if searchText.isEmpty && !excluding.isEmpty {
                ContentUnavailableView(
                    "Alles schon auf dem Herd",
                    systemImage: "frying.pan",
                    description: Text("Es gibt kein weiteres Rezept, das noch dazukommen könnte.")
                )
            } else {
                ContentUnavailableView(
                    "Kein Rezept gefunden",
                    systemImage: "magnifyingglass"
                )
            }
        }
    }

    private func reload() async {
        results = await library.findRecipes(matching: searchText)
            .filter { !excluding.contains($0.id) }
    }

    /// How many portions this pot is for, asked before it goes on.
    private struct ServingsStep: View {
        @Environment(\.dismiss) private var dismiss

        let recipe: Recipe
        let onAdd: (Int) -> Void

        @State private var servings: Int

        init(recipe: Recipe, onAdd: @escaping (Int) -> Void) {
            self.recipe = recipe
            self.onAdd = onAdd
            _servings = State(initialValue: recipe.servings)
        }

        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        Stepper(value: $servings, in: Recipe.servingsRange) {
                            Label(Servings.text(servings), systemImage: "person.2")
                        }
                    } footer: {
                        if servings != recipe.servings {
                            Text("Das Rezept ist für \(Servings.text(recipe.servings)) geschrieben; die Mengen werden umgerechnet.")
                        }
                    }
                }
                .formStyle(.grouped)
                .navigationTitle(recipe.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Abbrechen") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Dazunehmen") { onAdd(servings) }
                    }
                }
            }
            // Only a stepper and a title; a full-height sheet for that
            // would hide the list the cook just chose from.
            .sousSheetSizing(.question)
        }
    }
}
