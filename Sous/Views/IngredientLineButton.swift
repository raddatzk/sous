import SousKit
import SwiftUI

/// An ingredient line on the recipe page, with the catalog entry behind it one
/// tap away.
///
/// The recipe is where a cook actually thinks about an ingredient — "das steht
/// doch immer da, das muss ich nie kaufen", "die Nährwerte können nicht
/// stimmen", "das schreibe ich sonst anders". Sending them to the catalog to
/// search for the very word they are looking at is a detour past the thought,
/// and the thought is what gets lost on the way. So the line opens the same
/// sheet the catalog opens: Vorrat, Kategorie, Schreibweisen, Nährwerte and
/// die Maßangabe are corrected where the doubt came up.
///
/// Three shapes, because a line can mean three different things:
///
/// - a name the catalog knows opens its entry;
/// - a name it does not know offers the two ways to teach it — the same menu
///   the editor and the review sheet already put on an unknown word, so the
///   cook meets one answer to "unbekannt", not two;
/// - a line that links to another recipe stays a link. "1 Portion Naan" is a
///   recipe, not a food with values of its own, and the tap it already has
///   belongs to that.
struct IngredientLineButton: View {
    let ingredient: RecipeIngredient
    var formatter = QuantityFormatter(locale: .sous)
    /// Run once the sheet is gone: what was corrected in it — a basis, a
    /// gram weight, own values — changes this recipe's figures, and nothing
    /// else on the page would notice.
    var onClose: () async -> Void = {}

    @Environment(IngredientCatalogLibrary.self) private var catalog

    @State private var editing: CatalogIngredient?

    var body: some View {
        if !RecipeLink.referencedIDs(in: ingredient.name).isEmpty {
            line
        } else if let known = catalog.catalog.ingredient(for: name) {
            Button { editing = known } label: { line }
                .buttonStyle(IngredientLineButtonStyle())
                .accessibilityHint("Öffnet die Zutat")
                .sheet(item: $editing, onDismiss: { Task { await onClose() } }) { entry in
                    IngredientFormView(ingredient: entry)
                }
        } else if name.count >= 2 {
            UnknownIngredientButton(name: name, onClose: { Task { await onClose() } }) {
                line
            }
        } else {
            line
        }
    }

    private var line: some View {
        IngredientLineView(ingredient: ingredient, formatter: formatter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
    }

    /// The written name with the markdown of a link taken off it — the same
    /// form the catalog is asked about everywhere else.
    private var name: String {
        ShoppingItem.displayName(for: ingredient.name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A line that reads as prose and answers to a tap.
///
/// No permanent marker on it: the recipe is something to read, a list of
/// twelve underlined words is not, and the dotted underline this app draws
/// already means something else — "hier ist etwas offen". What the press
/// gets instead is the highlight a list row gives, bleeding just past the
/// text so the tap has visible width, and laid over the line rather than
/// around it so no ingredient shifts by a pixel for being tappable.
private struct IngredientLineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.sousField)
                    .padding(.horizontal, -6)
                    .padding(.vertical, -3)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
