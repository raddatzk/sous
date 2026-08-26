import SousKit
import SwiftUI

/// Which food catalog row an ingredient's numbers rest on — the candidate
/// list, the cook's own values, and the deliberate opt-out, in one place.
///
/// Not a modal. It unfolds where it was asked for: under a line of the
/// coverage drill-down in the recipe, or under a row of the collected
/// "Nährwerte zuordnen" view. The concept wants this question to be answerable in
/// passing, wherever it becomes visible — a dialog that has to be dismissed
/// before the recipe can be read again would make it a task instead.
struct IngredientBasisPicker: View {
    @Environment(NutritionLibrary.self) private var nutrition

    /// The ingredient as it is written — resolved through the catalog, so a
    /// decision taken here holds for every spelling of it.
    let name: String
    /// The state the line asked for. Bases have been per-state since phase 4
    /// and phase 5 actually writes them, so a picker pinned to `unspecified`
    /// could not repair a mapping that lives under `cooked` — it wrote a
    /// second, general basis and left the broken one exactly as it was.
    var state: IngredientState = .unspecified
    /// Called once the question has been answered, so the caller can fold the
    /// picker away and re-read its figures.
    var onDecision: () async -> Void = {}

    @State private var ownValuesFor: CatalogIngredient?

    private var current: NutritionBasis? {
        nutrition.nutrition(forName: name)?.basis(for: state)
    }

    /// Where an answer is written: the state the basis being looked at is
    /// actually filed under, which is not always the one the line names —
    /// see `NutritionLibrary.basisState(forName:asking:)`.
    private var target: IngredientState {
        nutrition.basisState(forName: name, asking: state)
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
            // What §7 asks to be said out loud: the mapping remembered the
            // row's name at confirmation time precisely so that it can still
            // be named once the row itself is gone. Saying only "gibt es
            // nicht mehr" withheld the one fact the cook needs to recognize
            // what has to be re-decided.
            VStack(alignment: .leading, spacing: 1) {
                if let was = current?.catalogName {
                    Text("Beruhte auf: \(was)")
                    Text("In den aktuellen Daten nicht mehr enthalten — bitte neu zuordnen.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Die zugeordnete Zeile gibt es in den Daten nicht mehr.")
                        .foregroundStyle(.secondary)
                }
            }
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
                        decide { await nutrition.confirmProposedBasis(forName: name, state: target) }
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
                        decide {
                            await nutrition.confirmBasis(code: row.code, state: target, forName: name)
                        }
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
            // The one answer that stays general on purpose: the form behind
            // it edits the whole ingredient — name, aisle, measures, one set
            // of values — and there is no per-state set of fields to fill.
            // Typing numbers is a statement about the ingredient; picking a
            // row is a statement about a state. Answering a state's question
            // this way therefore leaves that state's own basis standing, and
            // the way to retire it is "Zurücknehmen" right here, after which
            // the state falls back to the numbers just typed.
            Button("Eigene Werte") {
                ownValuesFor = nutrition.catalogIngredient(forName: name)
            }
            Button("Bewusst ohne") {
                decide { await nutrition.setDeliberatelyWithoutBasis(forName: name, state: target) }
            }
            if let current, current.status != .proposed {
                Button("Zurücknehmen", role: .destructive) {
                    decide { await nutrition.clearBasis(forName: name, state: target) }
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
