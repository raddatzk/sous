import SousKit
import SwiftUI

/// One row of the food catalog, as both places that offer one draw it: the
/// picker under a recipe line and the Grundlage section of the ingredient
/// form. Its name, its calories, and whether it is the one picked.
///
/// One view rather than two copies, so a wording fix, a number format or an
/// accessibility label reaches the recipe page and the form together. The
/// two hosts differ only in how the row sits: on its own in the picker, or
/// indented under the answer row it belongs to in the form.
struct BLSRow: View {
    let row: BLSEntry
    let isSelected: Bool
    /// Set where the row is one of several under a leading answer row, and
    /// the form's own spacing does the rest.
    var indented = false
    let onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(.tint)
                    .padding(.leading, indented ? 14 : 0)
                Text(row.name)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text("\(Int(row.perHundredGrams.kcal.rounded())) kcal")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, indented ? 0 : 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// What to say under an empty search: the table wants three characters,
    /// and a list that changes completely on the third keystroke is worse
    /// than one that says it is waiting for it.
    static func emptySearchNote(query: String) -> String {
        query.count < 3 ? "Noch ein Buchstabe." : "Keine Zeile gefunden."
    }
}

/// The free search over the whole food catalog — the one way in for a word
/// whose row shares no spelling with it. Same field in both hosts.
struct BLSSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Im Lebensmittelkatalog suchen", text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Löschen", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
