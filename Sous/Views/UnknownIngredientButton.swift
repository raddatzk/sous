import SousKit
import SwiftUI

/// What the cook decided to tell the app about a name it does not know.
///
/// A value rather than three booleans beside the menu, because the sheet
/// that asks the rest of the question must not hang off the view that was
/// tapped. In the editor that view is a chip in the keyboard bar, and the
/// bar is only there while the ingredients editor has the keyboard — which
/// the sheet itself takes away as it opens. The chip is gone a moment after
/// the tap, and with it went the sheet's own presenter. Handed upwards, the
/// decision is held by a view that stays: the editor's form, a list row.
enum IngredientTeaching: Hashable, Identifiable {
    /// Genuinely a new food: it needs an entry, with nutrition of its own.
    case newIngredient(String)
    /// A kind of something known — "Cocktailtomaten" as a variety of Tomate.
    case variety(String)
    /// Another way of writing something known.
    case spelling(String)

    var id: Self { self }

    var name: String {
        switch self {
        case let .newIngredient(name), let .variety(name), let .spelling(name): name
        }
    }
}

/// What the app offers for one ingredient it does not recognize.
///
/// Three answers, because there are three reasons a name is unknown. It may
/// be genuinely a new food — then it needs an entry, and nutrition typed in
/// by hand. It may be a spelling of something already in the catalog, and
/// the right move is to say which: no numbers to enter, and the ingredient
/// inherits everything that entry already knows. Or — for recipe text the
/// most common of the three — it is a *kind* of something known:
/// "Cocktailtomaten" is not a spelling of Tomate and not a new food, it is a
/// tomato with a qualifier, and saying so files it as a variety with its
/// parent's aisle and a proposed basis, in one tap.
///
/// The menu alone: it reports the answer and presents nothing. Whoever shows
/// it decides where the sheet lives — see ``IngredientTeaching`` — which for
/// anything standing still is one line, ``UnknownIngredientButton``.
struct UnknownIngredientMenu<Label: View>: View {
    let name: String
    /// Handed the cook's answer, for the caller to present.
    let choose: (IngredientTeaching) -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Menu {
            Button("Neue Zutat", systemImage: "plus.circle") { choose(.newIngredient(name)) }
            Button("Sorte einer bekannten Zutat", systemImage: "arrow.triangle.branch") { choose(.variety(name)) }
            Button("Schreibweise einer bekannten Zutat", systemImage: "arrow.triangle.merge") { choose(.spelling(name)) }
        } label: {
            label()
        }
        // The menu is drawn by whatever it wraps — a chip in the editor, a
        // list row in the review sheet — not by a button's own chrome.
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

extension UnknownIngredientMenu where Label == AnyView {
    /// The chip shape the editor uses in its "Noch unbekannt" rows and in the
    /// keyboard bar — the same control in both, so the two do not drift.
    static func chip(
        name: String, choose: @escaping (IngredientTeaching) -> Void
    ) -> UnknownIngredientMenu<AnyView> {
        UnknownIngredientMenu(name: name, choose: choose) {
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

/// The menu with the sheets attached to itself — for a control that is still
/// there once one is open: a row in the review sheet, a line on the recipe
/// page. The editor's chips come and go with the keyboard and hand the
/// answer to the form instead.
struct UnknownIngredientButton<Label: View>: View {
    let name: String
    /// Run once any sheet is gone. Teaching the word changes what the
    /// recipe it was tapped in can count — the editor and the review sheet
    /// have nothing to recompute and leave it out.
    var onClose: () -> Void = {}
    @ViewBuilder var label: () -> Label

    @State private var teaching: IngredientTeaching?

    var body: some View {
        UnknownIngredientMenu(name: name, choose: { teaching = $0 }, label: label)
            .ingredientTeaching($teaching, onClose: onClose)
    }
}

/// Asks the rest of whatever the cook chose from an unknown name's menu.
///
/// One sheet with three faces rather than three sheets: which one is up is
/// the one piece of state, so it cannot be two at once, and the modifier
/// goes on any view that outlives the tap.
private struct IngredientTeachingSheets: ViewModifier {
    @Binding var teaching: IngredientTeaching?
    let onClose: () -> Void

    @Environment(IngredientCatalogLibrary.self) private var catalog

    func body(content: Content) -> some View {
        content.sheet(item: $teaching, onDismiss: onClose) { teaching in
            switch teaching {
            case let .newIngredient(name):
                IngredientFormView(ingredient: CatalogIngredient(name: name, category: .other))
            case let .variety(name):
                IngredientParentPickerView(ingredientName: name) { parent in
                    // No category of its own: the variety inherits its
                    // parent's aisle, and keeps inheriting if the parent's
                    // ever changes. Awaited, so `onClose` recomputes against
                    // a catalog that already holds the variety rather than
                    // racing the write.
                    _ = await catalog.save(CatalogIngredient(name: name, parentName: parent.name))
                }
            case let .spelling(name):
                IngredientAliasPickerView(alias: name)
            }
        }
    }
}

extension View {
    /// See ``IngredientTeachingSheets``.
    func ingredientTeaching(
        _ teaching: Binding<IngredientTeaching?>, onClose: @escaping () -> Void = {}
    ) -> some View {
        modifier(IngredientTeachingSheets(teaching: teaching, onClose: onClose))
    }
}
