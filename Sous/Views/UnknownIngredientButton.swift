import SousKit
import SwiftUI

/// An unknown name the cook asked to place in the catalog.
///
/// A value handed upwards, because the sheet that asks about the name must
/// not be attached to the view that was tapped. In the editor that view is a
/// chip in the keyboard bar. The bar is only there while the ingredients
/// editor has the keyboard, and the opening sheet takes the keyboard away, so
/// the chip disappears a moment after the tap and the sheet's presenter goes
/// with it. A view that stays holds the value instead: the editor's form, or
/// a list row.
struct IngredientTeaching: Hashable, Identifiable {
    let name: String

    var id: String { name }
}

/// The control on a name the app does not recognize.
///
/// A plain button. The sheet it leads to, ``UnknownIngredientSheet``, first
/// shows what the catalog already has, and only then asks whether the name
/// is a spelling, a variety or something new. The control reports the tap and
/// presents nothing itself. The caller decides where the sheet lives, as
/// described at ``IngredientTeaching``. For a control that stays on screen,
/// that is one line: ``UnknownIngredientButton``.
struct UnknownIngredientControl<Label: View>: View {
    let name: String
    /// Called when the name is tapped. The caller presents the sheet.
    let choose: (IngredientTeaching) -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button { choose(IngredientTeaching(name: name)) } label: { label() }
            // The wrapped view draws the control: a chip in the editor, a
            // list row in the review sheet. A button's own chrome is not used.
            .buttonStyle(.plain)
            .accessibilityHint("Sucht die Zutat im Katalog")
    }
}

extension UnknownIngredientControl where Label == AnyView {
    /// The chip shape the editor uses in its "Noch unbekannt" rows and in the
    /// keyboard bar — the same control in both, so the two do not drift.
    static func chip(
        name: String, choose: @escaping (IngredientTeaching) -> Void
    ) -> UnknownIngredientControl<AnyView> {
        UnknownIngredientControl(name: name, choose: choose) {
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

/// The control with the sheet attached to itself — for a control that is still
/// there once one is open: a row in the review sheet, a line on the recipe
/// page. The editor's chips come and go with the keyboard and hand the
/// name to the form instead.
struct UnknownIngredientButton<Label: View>: View {
    let name: String
    /// Run once the sheet is gone. Teaching the word changes what the
    /// recipe it was tapped in can count — the editor and the review sheet
    /// have nothing to recompute and leave it out.
    var onClose: () -> Void = {}
    @ViewBuilder var label: () -> Label

    @State private var teaching: IngredientTeaching?

    var body: some View {
        UnknownIngredientControl(name: name, choose: { teaching = $0 }, label: label)
            .ingredientTeaching($teaching, onClose: onClose)
    }
}

/// Presents ``UnknownIngredientSheet`` for the name the cook tapped.
private struct IngredientTeachingSheet: ViewModifier {
    @Binding var teaching: IngredientTeaching?
    let onClose: () -> Void

    func body(content: Content) -> some View {
        content.sheet(item: $teaching, onDismiss: onClose) { teaching in
            UnknownIngredientSheet(name: teaching.name)
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
