import SousKit
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// An unknown name the cook chose to give a local answer for.
///
/// A value handed upwards, because the sheet with the form must not be
/// attached to the view that was tapped. In the editor that view is a chip in
/// the keyboard bar. The bar is only there while the ingredients editor has
/// the keyboard, and the opening sheet takes the keyboard away, so the chip
/// disappears a moment after the tap and the sheet's presenter goes with it.
/// A view that stays holds the value instead: the editor's form, or the line.
struct IngredientTeaching: Hashable, Identifiable {
    let name: String

    var id: String { name }
}

/// The control on a name the catalog does not know.
///
/// The catalog answers; the app does not ask (INGREDIENTS-DATA §3 A). So an
/// unknown name offers exactly two things, and neither is a question: a local
/// answer for this household (``LocalAnswerForm``: "zählt wie", own values,
/// own weights, a product), and a report for the curator, copied as text
/// until sharing exists. Teaching the catalog a spelling, a variety or a new
/// ingredient is the curator's work, not the cook's.
///
/// The control reports the choice and presents nothing itself. The caller
/// decides where the form lives, as described at ``IngredientTeaching``. For
/// a control that stays on screen, that is one line: ``UnknownIngredientButton``.
struct UnknownIngredientControl<Label: View>: View {
    let name: String
    /// Named in the report, where there is a recipe.
    var recipeTitle: String?
    /// Called when "Lokale Angabe …" is chosen. The caller presents the form.
    let choose: (IngredientTeaching) -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Menu {
            Button("Lokale Angabe …", systemImage: "house") {
                choose(IngredientTeaching(name: name))
            }
            Button("Meldung kopieren", systemImage: "paperplane") {
                SousPasteboard.copy(CatalogReport.unknown(name, recipeTitle: recipeTitle))
            }
        } label: {
            label()
        }
        // The wrapped view draws the control: a chip in the editor, the line
        // on the recipe page. A menu button's own chrome is not used.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityHint("Lokale Angabe oder Meldung an den Katalog")
    }
}

extension UnknownIngredientControl where Label == AnyView {
    /// The chip shape the editor uses in its "Noch unbekannt" rows and in the
    /// keyboard bar — the same control in both, so the two do not drift.
    static func chip(
        name: String, recipeTitle: String? = nil, choose: @escaping (IngredientTeaching) -> Void
    ) -> UnknownIngredientControl<AnyView> {
        UnknownIngredientControl(name: name, recipeTitle: recipeTitle, choose: choose) {
            AnyView(
                HStack(spacing: 4) {
                    Text(name)
                        .lineLimit(1)
                    Image(systemName: "ellipsis.circle.fill")
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.sousField, in: .capsule)
            )
        }
    }
}

/// The control with the form attached to itself — for a control that is
/// still there once the form is open: a line on the recipe page. The editor's
/// chips come and go with the keyboard and hand the name to the editor
/// instead.
struct UnknownIngredientButton<Label: View>: View {
    let name: String
    var recipeTitle: String?
    /// Run once the form is gone. A local answer changes what the recipe it
    /// was given in can count.
    var onClose: () -> Void = {}
    @ViewBuilder var label: () -> Label

    @State private var teaching: IngredientTeaching?

    var body: some View {
        UnknownIngredientControl(name: name, recipeTitle: recipeTitle, choose: { teaching = $0 }, label: label)
            .ingredientTeaching($teaching, onClose: onClose)
    }
}

/// Presents ``LocalAnswerForm`` for the name the cook chose.
private struct IngredientTeachingSheet: ViewModifier {
    @Environment(IngredientCatalogLibrary.self) private var catalog
    @Binding var teaching: IngredientTeaching?
    let onClose: () -> Void

    func body(content: Content) -> some View {
        content.sheet(item: $teaching, onDismiss: onClose) { teaching in
            LocalAnswerForm(name: teaching.name, existing: catalog.localAnswer(for: teaching.name))
        }
    }
}

extension View {
    /// See ``IngredientTeachingSheet``.
    func ingredientTeaching(
        _ teaching: Binding<IngredientTeaching?>, onClose: @escaping () -> Void = {}
    ) -> some View {
        modifier(IngredientTeachingSheet(teaching: teaching, onClose: onClose))
    }
}

/// The system pasteboard on both platforms — where a report goes until
/// sharing exists.
enum SousPasteboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
