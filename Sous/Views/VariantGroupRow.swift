import SousKit
import SwiftUI

/// The row a variant group's members stand under.
///
/// Deliberately unlike ``RecipeRow``: no picture, no time, no calories. A
/// group has none of those — it is not a recipe, and a row that looked like
/// one would invite the reader to plan it, favourite it, cook it. What it
/// says is what it is: a dish, and how many versions of it are here.
struct VariantGroupRow: View {
    let group: VariantGroup
    /// The members drawn under it, which under a filter is fewer than the
    /// group has.
    let shown: Int
    /// Everything the group holds, so a filtered row can say what it left
    /// out instead of quietly shrinking the dish to the one hit.
    let total: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.on.square")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title)
                    .font(SousStyle.recipeName)
                    .lineLimit(1)
                // Only when it is news. The versions are drawn underneath
                // this row, so counting them is something the reader can do
                // by looking — except where a filter kept some of them out,
                // and then saying so is the whole point of the row.
                if let hidden {
                    Text(hidden)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            // What the row does, rather than what the group has. Tapping it
            // opens the comparison, and that is worth saying once here —
            // otherwise the row is a heading nobody would think to press.
            Text("Vergleichen")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var hidden: String? {
        guard shown < total else { return nil }
        return "\(shown) von \(total) Varianten"
    }
}
