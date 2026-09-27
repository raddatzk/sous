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
    /// What the cook is looking for by hand. While it holds something, it
    /// replaces the proposals rather than sitting beside them: two lists of
    /// catalog rows under one question is one list too many.
    @State private var query = ""
    /// The row the cook tapped, not yet written. `nil` means "whatever is on
    /// file", so the proposal starts out marked and a decision taken elsewhere
    /// shows up without having to be copied in.
    @State private var picked: String?

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
            header
            searchField
            if trimmedQuery.isEmpty {
                candidateList
            } else {
                searchResults
            }
            otherAnswers
        }
        .font(.footnote)
        .padding(.vertical, 4)
        .sheet(item: $ownValuesFor) { ingredient in
            IngredientFormView(ingredient: ingredient, startsOnOwnValues: true)
        }
    }

    /// The row marked in the list: the one just tapped, or the one on file.
    private var selection: String? {
        picked ?? current?.code
    }

    /// What "Übernehmen" would write, when there is anything to write: a row
    /// other than the filed one, or the filed one while it is only proposed.
    private var pendingCode: String? {
        guard let selection else { return nil }
        if selection != current?.code || current?.status == .proposed { return selection }
        return nil
    }

    /// The row marked in the list when it is not the one on file — what
    /// "Übernehmen" would write instead.
    private var markedRowName: String? {
        guard let picked, picked != current?.code else { return nil }
        return nutrition.row(forCode: picked)?.name
    }

    /// What the numbers rest on, what is marked instead, and the one tap that
    /// settles it — up here where the eye starts. A proposal can head a list
    /// of twenty-five rows, and saying yes to it should not mean scrolling
    /// past all of them.
    ///
    /// The button stays put whichever row is marked; one that vanished the
    /// moment another row was tapped looked like the tap had broken it. The
    /// "Ausgewählt" line is what keeps it unambiguous: beside "Zurzeit" alone
    /// it would read as confirming the old row.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                currentLine
                if let markedRowName {
                    Text("Ausgewählt: \(markedRowName)")
                        .fontWeight(.semibold)
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
            if let pendingCode {
                confirmButton(pendingCode)
            }
        }
    }

    /// What the numbers rest on right now.
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
            VStack(alignment: .leading, spacing: 1) {
                // Own values name no catalog row, so they say whose they
                // are instead — never nothing.
                Text("Zurzeit: \(current?.provenance ?? current?.source ?? "")")
                Text(currentStatusLine)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The real rows, not a guess at them: the synonym table's candidates
    /// first, then whatever the catalog's own names turn up. Schmelzkäse has
    /// eleven of them, and picking between them was never a question a build
    /// step got to answer.
    @ViewBuilder
    private var candidateList: some View {
        let rows = nutrition.candidates(forName: name, state: state)
        if rows.isEmpty {
            Text("Der Lebensmittelkatalog schlägt zu diesem Namen nichts vor. Such von Hand, trag eigene Werte ein oder lass es bewusst ohne.")
                .foregroundStyle(.secondary)
        } else {
            rowList(rows)
        }
    }

    /// What the cook typed, answered from the whole table.
    ///
    /// The kitchen's word and the catalog's word are nearly disjoint
    /// languages, so a name-based proposal can miss entirely while the right
    /// row sits in the file — "Räucherlachs" is there, under "Lachs
    /// geräuchert". This is the way to it.
    @ViewBuilder
    private var searchResults: some View {
        let rows = nutrition.search(trimmedQuery)
        if rows.isEmpty {
            Text(BLSRow.emptySearchNote(query: trimmedQuery))
                .foregroundStyle(.secondary)
        } else {
            rowList(rows)
        }
    }

    private var searchField: some View {
        BLSSearchField(text: $query)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One shape for both lists, so a proposal and a search hit are picked the
    /// same way and look the same when picked — and the same shape the form
    /// uses, see ``BLSRow``.
    ///
    /// A tap marks, "Übernehmen" writes — what the circle promises, and what
    /// the form's own page does. A tap that wrote at once and folded the
    /// picker away left no moment to see which row had been hit.
    ///
    /// The marked row leads wherever it is not among the rows shown, so a
    /// search hit stays visible after the search is cleared and the button
    /// never confirms something off screen.
    private func rowList(_ rows: [BLSEntry]) -> some View {
        var shown = rows
        if let selection, !rows.contains(where: { $0.code == selection }),
           let marked = nutrition.row(forCode: selection) {
            shown.insert(marked, at: 0)
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { row in
                BLSRow(row: row, isSelected: selection == row.code) {
                    picked = row.code
                }
            }
        }
    }

    /// Writes the marked row. The same button in both places it appears.
    private func confirmButton(_ code: String) -> some View {
        Button("Übernehmen") {
            decide { await nutrition.confirmBasis(code: code, state: target, forName: name) }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    /// Wraps rather than squeezing: with "Übernehmen" in front, four
    /// capsules no longer fit one line of a sheet, and a squeezed one broke
    /// its own label in two.
    private var otherAnswers: some View {
        FlowLayout(spacing: 12, lineSpacing: 8) {
            if let pendingCode {
                confirmButton(pendingCode)
            }
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
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// "vorgeschlagen — geerbt von Lachs": the status, and where the basis
    /// came from when it was not this ingredient's own. Saying only the first
    /// half is how a variety's inherited number passed for its own.
    private var currentStatusLine: String {
        let label = current?.status.label ?? ""
        guard let parent = current?.inheritedFrom else { return label }
        return "\(label) — geerbt von \(parent)"
    }

    private func decide(_ work: @escaping () async -> Void) {
        Task {
            await work()
            picked = nil
            await onDecision()
        }
    }
}
