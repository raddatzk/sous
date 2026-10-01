import SousKit
import SwiftUI

/// What the app asks about a name its catalog does not know.
///
/// The sheet opens on a catalog search that already holds the name. The
/// earlier version opened on a menu that asked first whether the name was
/// new, a variety or a spelling, and that asked for knowledge the cook does
/// not have. Nobody knows the catalog's entries by heart, and "Alias" or
/// "Sorte" mean little until there is something to compare the name with.
/// Here the comparison comes first. "dünne Kokosmilch" shows Kokosmilch and
/// Kokosmilch fettarm, and the question becomes concrete: is it the same
/// thing, or a kind of it? The explanation appears in the dialog that asks
/// the question, because a tooltip only exists where there is a pointer.
///
/// Creating the name as new is always offered, below the matches. A match
/// may be a false friend ("Erdnussbutter" finds Butter). Offered only when
/// nothing matched, the entry would be forced into whatever came closest.
struct UnknownIngredientSheet: View {
    @Environment(IngredientCatalogLibrary.self) private var catalog
    @Environment(\.dismiss) private var dismiss

    /// The unknown name as it was written in the recipe.
    let name: String

    @State private var searchText: String
    /// The match that was tapped. It stays set while the dialog asks how the
    /// name relates to it.
    @State private var chosen: CatalogIngredient?
    /// Set once the cook chose to create the name as new. The same sheet then
    /// shows the form, so the sheet does not close and reopen with a new face.
    @State private var isCreating = false
    /// Set once an answer is being written. A second tap during the write
    /// should not write again.
    @State private var isWriting = false
    /// Set once the cook chose to give a local answer by hand — own values,
    /// own weights, a product (INGREDIENTS-DATA §3 B).
    @State private var isAnswering = false

    init(name: String) {
        self.name = name
        _searchText = State(initialValue: name)
    }

    var body: some View {
        if isAnswering {
            LocalAnswerForm(name: name, existing: catalog.localAnswer(for: name))
        } else if isCreating {
            // The form cannot ask "Als Sorte von X führen?" here. Those
            // candidates were just on screen, and the cook turned them down.
            IngredientFormView(
                ingredient: CatalogIngredient(name: name, category: .other),
                proposesVariety: false
            )
        } else {
            search
        }
    }

    private var search: some View {
        NavigationStack {
            List {
                Section {
                    if results.isEmpty {
                        if !trimmedQuery.isEmpty {
                            Text("Nichts gefunden. Dann ist die Zutat wohl neu.")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(results) { row($0) }
                    }
                } header: {
                    Text("Im Katalog").sousGroupHeader()
                } footer: {
                    if !results.isEmpty {
                        Text("Tippe auf einen Treffer, wenn „\(name)“ dasselbe ist oder eine Sorte davon.")
                    }
                }
                Section {
                    Button("Lokale Angabe …", systemImage: "house") {
                        isAnswering = true
                    }
                } footer: {
                    Text("Eigene Werte von der Packung, eigene Gewichte oder ein Produkt – nur für diesen Haushalt.")
                }
                Section {
                    Button("„\(name)“ neu anlegen", systemImage: "plus.circle") {
                        isCreating = true
                    }
                } footer: {
                    if !results.isEmpty {
                        Text("Wenn keiner der Treffer passt.")
                    }
                }
            }
            .navigationTitle("„\(name)“")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $searchText, prompt: "Im Katalog suchen")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .sousSheetSizing(.form)
    }

    /// A button rather than a tap gesture: the pointer changes over it, the
    /// keyboard reaches it, and the Mac gets the click it expects.
    private func row(_ match: CatalogIngredient) -> some View {
        Button {
            chosen = match
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(match.name)
                Text(lineage(of: match))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Attached to the row so that on iPhone and iPad the question
        // points at the match it is about.
        .confirmationDialog(
            "Was ist „\(name)“?",
            isPresented: isAsking(about: match),
            titleVisibility: .visible
        ) {
            if match.catalogID != nil {
                Button("Zählt wie \(match.name)") {
                    write { _ = await catalog.count(name, as: match) }
                }
            }
            Button("Dasselbe, nur anders geschrieben") {
                write { await catalog.addAlias(name, to: match) }
            }
            Button("Eine Sorte von \(match.name)") {
                // The variety gets no category of its own. It takes the
                // parent's aisle and keeps following it if that changes.
                write { _ = await catalog.save(CatalogIngredient(name: name, parentName: match.name)) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("""
            Zählt wie: rechnet mit Nährwerten und Gewichten von „\(match.name)“, nur in diesem Haushalt; auf der Einkaufsliste bleibt „\(name)“ eine eigene Zeile.
            Anders geschrieben: wird als „\(match.name)“ gezählt, mit denselben Nährwerten und einer gemeinsamen Zeile auf der Einkaufsliste.
            Sorte: eine eigene Zutat unter „\(match.name)“, mit eigener Zeile auf der Einkaufsliste. Die Nährwerte von „\(match.name)“ gelten als Vorschlag.
            """)
        }
    }

    /// For a match that is itself a variety, the chain above it, such as
    /// "Sorte von Kokosmilch": Kokosmilch fettarm then reads as what it is.
    /// For any other match, its aisle.
    private func lineage(of ingredient: CatalogIngredient) -> String {
        let ancestors = catalog.catalog.ancestors(of: ingredient.name)
        guard !ancestors.isEmpty else { return ingredient.category.title }
        return "Sorte von " + ancestors.map(\.name).joined(separator: " → ")
    }

    private func isAsking(about match: CatalogIngredient) -> Binding<Bool> {
        Binding(get: { chosen?.key == match.key }, set: { if !$0 { chosen = nil } })
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    private var results: [CatalogIngredient] {
        catalog.catalog.search(searchText)
    }

    /// Finishes the write before the sheet closes. The recipe page behind it
    /// reads the catalog again on dismissal, and by then the catalog should
    /// already know the name.
    private func write(_ answer: @escaping () async -> Void) {
        guard !isWriting else { return }
        isWriting = true
        Task {
            await answer()
            dismiss()
        }
    }
}
