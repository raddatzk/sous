import SousKit
import SwiftUI

/// What the app offers for one ingredient it does not recognize.
///
/// Two answers, because there are two reasons a name is unknown. Either it
/// is genuinely a new food — then it needs an entry, and nutrition typed in
/// by hand. Or it is a spelling of something already in the catalog, and the
/// right move is to say which: no numbers to enter, and the ingredient
/// inherits everything that entry already knows.
struct UnknownIngredientButton<Label: View>: View {
    let name: String
    /// Run once either sheet is gone. Teaching the word changes what the
    /// recipe it was tapped in can count — the editor and the review sheet
    /// have nothing to recompute and leave it out.
    var onClose: () -> Void = {}
    @ViewBuilder var label: () -> Label

    @State private var teaching: CatalogIngredient?
    @State private var isPickingAlias = false

    var body: some View {
        Menu {
            Button("Neue Zutat", systemImage: "plus.circle") {
                teaching = CatalogIngredient(name: name, category: .other)
            }
            Button("Schreibweise einer bekannten Zutat", systemImage: "arrow.triangle.merge") {
                isPickingAlias = true
            }
        } label: {
            label()
        }
        // The menu is drawn by whatever it wraps — a chip in the editor, a
        // list row in the review sheet — not by a button's own chrome.
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .sheet(item: $teaching, onDismiss: onClose) { ingredient in
            IngredientFormView(ingredient: ingredient)
        }
        .sheet(isPresented: $isPickingAlias, onDismiss: onClose) {
            IngredientAliasPickerView(alias: name)
        }
    }
}

extension UnknownIngredientButton where Label == AnyView {
    /// The chip shape the editor uses in its "Noch unbekannt" rows and in the
    /// keyboard bar — the same control in both, so the two do not drift.
    static func chip(name: String) -> UnknownIngredientButton<AnyView> {
        UnknownIngredientButton(name: name) {
            AnyView(
                HStack(spacing: 4) {
                    Text(name)
                        .lineLimit(1)
                    Image(systemName: "plus.circle.fill")
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.sousField, in: .capsule)
            )
        }
    }
}
