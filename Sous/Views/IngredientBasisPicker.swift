import SousKit
import SwiftUI

/// Which food catalog row an ingredient's numbers rest on — the candidate
/// list, the cook's own values, and the deliberate opt-out, in one place.
///
/// Not a modal. It unfolds where it was asked for: under a line of the
/// coverage drill-down in the recipe, or under a row of the collected
/// "Zutaten klären" view. The concept wants this question to be answerable in
/// passing, wherever it becomes visible — a dialog that has to be dismissed
/// before the recipe can be read again would make it a task instead.
struct IngredientBasisPicker: View {
    @Environment(NutritionLibrary.self) private var nutrition

    /// The ingredient as it is written — resolved through the catalog, so a
    /// decision taken here holds for every spelling of it.
    let name: String
    /// Called once the question has been answered, so the caller can fold the
    /// picker away and re-read its figures.
    var onDecision: () async -> Void = {}

    @State private var ownValuesFor: CatalogIngredient?

    private var current: NutritionBasis? {
        nutrition.nutrition(forName: name)?.basis(for: .unspecified)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            currentLine
            candidateList
            otherAnswers
        }
        .font(.footnote)
        .padding(.vertical, 4)
        .sheet(item: $ownValuesFor) { ingredient in
            IngredientFormView(ingredient: ingredient, startsOnOwnValues: true)
        }
    }

    /// What the numbers rest on right now, and — while that is only a
    /// proposal — the one tap that settles it. The batch flow is this button,
    /// once per ingredient.
    @ViewBuilder
    private var currentLine: some View {
        switch current?.status {
        case nil:
            Text("Noch keine Grundlage — die Summe lässt diese Zutat aus.")
                .foregroundStyle(.secondary)
        case .deliberatelyWithout:
            Text("Bewusst ohne Nährwerte — diese Zutat fragt nicht mehr nach.")
                .foregroundStyle(.secondary)
        case .orphaned:
            Text("Die zugeordnete Zeile gibt es in den Daten nicht mehr.")
                .foregroundStyle(.secondary)
        case .proposed, .confirmed:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    // Own values name no catalog row, so they say whose they
                    // are instead — never nothing.
                    Text("Zurzeit: \(current?.provenance ?? current?.source ?? "")")
                    Text(current?.status.label ?? "")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if current?.status == .proposed {
                    Button("Übernehmen") {
                        decide { await nutrition.confirmProposedBasis(forName: name) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }

    /// The real rows, not a guess at them: the synonym table's candidates
    /// first, then whatever the catalog's own names turn up. Schmelzkäse has
    /// eleven of them, and picking between them was never a question a build
    /// step got to answer.
    @ViewBuilder
    private var candidateList: some View {
        let rows = nutrition.candidates(forName: name)
        if rows.isEmpty {
            Text("Der Lebensmittelkatalog hat zu diesem Namen nichts. Eigene Werte oder bewusst ohne.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    Button {
                        decide { await nutrition.confirmBasis(code: row.code, forName: name) }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: current?.code == row.code
                                ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(.tint)
                            Text(row.name)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Text("\(Int(row.perHundredGrams.kcal.rounded())) kcal")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 4)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var otherAnswers: some View {
        HStack(spacing: 12) {
            Button("Eigene Werte") {
                ownValuesFor = nutrition.catalogIngredient(forName: name)
            }
            Button("Bewusst ohne") {
                decide { await nutrition.setDeliberatelyWithoutBasis(forName: name) }
            }
            if let current, current.status != .proposed {
                Button("Zurücknehmen", role: .destructive) {
                    decide { await nutrition.clearBasis(forName: name) }
                }
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func decide(_ work: @escaping () async -> Void) {
        Task {
            await work()
            await onDecision()
        }
    }
}
