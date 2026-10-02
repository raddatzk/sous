import SousKit
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// "Für Sous optimieren": the recipe's lines brought into the line
/// principle's form by a chat model the cook already uses, checked by Sous,
/// and previewed old → new before anything is taken. See
/// ``RecipeOptimization``.
///
/// Built like ``StepReferencesSheet`` — copy the prompt, paste the answer
/// back, same chat setting — because it is the same act with a larger
/// answer: the step references come along, read against the new text.
struct RecipeOptimizationSheet: View {
    @Environment(RecipeLibrary.self) private var library
    @Environment(IngredientCatalogLibrary.self) private var catalogLibrary
    @Environment(NutritionLibrary.self) private var nutritionLibrary
    @Environment(\.dismiss) private var dismiss

    let recipe: Recipe

    @AppStorage(SousSetting.stepReferencesChat, store: .sous)
    private var chat: StepReferencesChat?
    @State private var backend = CopyPasteBackend()
    @State private var didCopy = false
    @State private var optimization: RecipeOptimization?
    @State private var selection = RecipeOptimization.Selection()
    @State private var reported: Set<Int> = []
    @State private var didCopyReport = false
    /// The proposals stored as local answers in this sheet, by line.
    @State private var storedLocally: Set<Int> = []
    @State private var failure: String?
    @State private var createdVariant: String?

    private var catalog: IngredientCatalog { catalogLibrary.catalog }

    var body: some View {
        NavigationStack {
            Form {
                askSection
                pasteSection
                if let optimization {
                    preview(optimization)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Für Sous optimieren")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { apply() }
                        .disabled(optimization == nil || selection == RecipeOptimization.Selection())
                }
            }
        }
        // A read answer is work the cook would lose by a swipe.
        .interactiveDismissDisabled(optimization != nil)
        .sousSheetSizing(.page)
        .onDisappear { backend.cancel() }
    }

    // MARK: - Asking

    private var askSection: some View {
        Section {
            Button(didCopy ? "Prompt kopiert" : "Prompt kopieren", systemImage: didCopy ? "checkmark" : "doc.on.doc") {
                didCopy = true
                ask()
            }
            if let chat {
                if let url = chat.url {
                    Link(destination: url) {
                        Label("\(chat.title) öffnen", systemImage: "arrow.up.forward.app")
                    }
                }
            } else {
                StepReferencesChatPicker()
            }
        } header: {
            Text("Chat fragen")
        } footer: {
            Text("Der Chat bringt die Zutaten in eine feste Form: Menge, Einheit, Zutat. Zubereitung wird ein Schritt, Alternativen kommen in die Notizen. Sous prüft jede Zeile, bevor sie angeboten wird; das Original bleibt erhalten.")
        }
    }

    private var pasteSection: some View {
        Section {
            PasteButton(payloadType: String.self) { strings in
                let pasted = strings.joined(separator: "\n")
                Task { @MainActor in
                    // The copy-paste backend is waiting for exactly this;
                    // opened afresh, nobody is waiting, and it is read as is.
                    if !backend.deliver(pasted) { read(pasted) }
                }
            }
            if let failure {
                Label(failure, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Antwort einfügen")
        } footer: {
            Text("Die Antwort des Chats kopieren — am einfachsten über den Kopieren-Knopf am Codeblock.")
        }
    }

    private func ask() {
        let recipe = recipe
        let catalog = catalog
        let nutritionCatalog = nutritionLibrary.nutritionCatalog
        let backend = backend
        Task { @MainActor in
            do {
                let result = try await RecipeOptimizer.optimize(
                    recipe, catalog: catalog, nutritionCatalog: nutritionCatalog, backend: backend
                )
                take(result)
            } catch {
                // Cancelled: the sheet closed, or the prompt was copied again.
            }
        }
    }

    private func read(_ pasted: String) {
        take(RecipeOptimizationPrompt.read(
            pasted, for: recipe, catalog: catalog, nutritionCatalog: nutritionLibrary.nutritionCatalog
        ))
    }

    private func take(_ result: Result<RecipeOptimization, RecipeOptimizationPrompt.Failure>) {
        switch result {
        case .success(let value):
            optimization = value
            selection = value.defaultSelection
            reported = Set(value.classifications.map(\.id))
            failure = nil
        case .failure(let error):
            optimization = nil
            failure = error.localizedDescription
        }
    }

    private func apply() {
        guard let optimization else { return }
        let applied = optimization.applied(selection)
        Task {
            if await library.applyOptimization(applied, to: recipe) {
                dismiss()
            } else {
                failure = "Das Rezept wurde inzwischen geändert. Bitte den Prompt neu kopieren und neu fragen."
                self.optimization = nil
            }
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private func preview(_ optimization: RecipeOptimization) -> some View {
        let applied = optimization.applied(selection)
        if !optimization.changesAnything {
            Section {
                Label("Die Zeilen sind schon in Form. Übernehmen speichert nur die Zuordnung der Schritte.", systemImage: "checkmark.seal")
            }
        }

        let changed = optimization.lines.filter { $0.isChanged && !$0.changes.contains(.group) }
        if !changed.isEmpty {
            Section {
                ForEach(changed) { line in
                    lineRow(line)
                }
            } header: {
                Text("Zeilen")
            } footer: {
                Text("Tippfehler sind nie vorab angehakt. Rot Markiertes bietet Sous nicht an; die Zeile bleibt dann, wie sie ist.")
            }
        }

        if !optimization.newSteps.isEmpty {
            Section("Neue Zubereitungsschritte") {
                ForEach(optimization.newSteps) { step in
                    Toggle(isOn: binding(step: step.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.text)
                            Text(step.before.map { "vor Schritt \($0)" } ?? "am Ende")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }

        let movedNotes = applied.recipe.notes.flatMap { notes in
            notes == (recipe.notes ?? "") ? nil : String(notes.dropFirst(recipe.notes?.count ?? 0))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let movedNotes, !movedNotes.isEmpty {
            Section("Kommt in die Notizen") {
                Text(movedNotes)
            }
        }

        let groups = optimization.groups.filter { $0.action != .keep }
        if !groups.isEmpty {
            Section {
                ForEach(groups) { group in
                    groupRow(group, in: optimization)
                }
            } header: {
                Text("Gruppen mit Alternativen")
            } footer: {
                Text("Eine Variante lohnt sich nur für ein wirklich anderes Gericht. Einzelne Tauschmöglichkeiten gehören in die Notizen.")
            }
        }

        if !optimization.classifications.isEmpty {
            classificationSection(optimization)
        }

        let warnings = applied.reading?.warnings ?? []
        if !optimization.notes.isEmpty || !warnings.isEmpty {
            Section {
                ForEach(optimization.notes, id: \.self) { note in
                    Label(note, systemImage: "text.badge.checkmark")
                }
                ForEach(warnings, id: \.self) { warning in
                    Label(text(for: warning, in: applied.recipe), systemImage: "exclamationmark.triangle")
                }
            } header: {
                Text("Passt im Rezept nicht zusammen")
            }
        }
    }

    @ViewBuilder
    private func lineRow(_ line: RecipeOptimization.Line) -> some View {
        let content = VStack(alignment: .leading, spacing: 4) {
            Text(line.written)
                .strikethrough()
                .foregroundStyle(.secondary)
            if line.rewritten.isEmpty {
                Text("entfällt")
                    .italic()
            }
            ForEach(Array(line.rewritten.enumerated()), id: \.offset) { _, text in
                Label(text, systemImage: "arrow.turn.down.right")
            }
            ForEach(changeNotes(line), id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(line.issues, id: \.self) { issue in
                Text(text(for: issue))
                    .font(.caption)
                    .foregroundStyle(issue.refuses ? Color.red : Color.orange)
            }
        }
        if line.isRefused {
            content
        } else {
            Toggle(isOn: binding(line: line.number)) { content }
        }
    }

    private func changeNotes(_ line: RecipeOptimization.Line) -> [String] {
        var notes: [String] = []
        if let preparation = line.preparation { notes.append("„\(preparation)“ wird ein Schritt") }
        if let weighing = line.weighing {
            let formatter = QuantityFormatter(locale: .sous)
            notes.append("\(formatter.string(for: weighing.from, size: nil)) → \(formatter.string(for: Quantity(weighing.grams, .gram), size: nil)), von Sous aus dem Katalog gewogen")
        }
        if let note = line.note { notes.append("In die Notizen: \(note)") }
        for typo in line.typos {
            notes.append("Tippfehler: \(typo.wrong) → \(typo.right)\(typo.declared ? "" : " (von Sous bemerkt)")")
        }
        if line.changes.contains(.split) { notes.append("Zwei Zutaten, zwei Zeilen") }
        if line.changes == [.noise] { notes.append("Nur Störtext entfernt") }
        return notes
    }

    @ViewBuilder
    private func groupRow(_ group: RecipeOptimization.GroupProposal, in optimization: RecipeOptimization) -> some View {
        Toggle(isOn: binding(group: group.name)) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Gruppe „\(group.name)“ entfernen")
                if let reason = group.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(group.lines.compactMap { number in
                    optimization.lines.first { $0.number == number }?.written
                }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        if let variant = group.variant {
            if createdVariant == variant.title {
                Label("„\(variant.title)“ angelegt", systemImage: "checkmark")
            } else {
                NavigationLink {
                    VariantProposalView(proposal: variant) {
                        Task {
                            if await library.addVariant(variant, of: recipe) != nil {
                                createdVariant = variant.title
                            }
                        }
                    }
                } label: {
                    Label("Als Variante anlegen: \(variant.title)", systemImage: "square.on.square")
                }
            }
        }
    }

    @ViewBuilder
    private func classificationSection(_ optimization: RecipeOptimization) -> some View {
        Section {
            ForEach(optimization.classifications) { item in
                Toggle(isOn: Binding(
                    get: { reported.contains(item.id) },
                    set: { if $0 { reported.insert(item.id) } else { reported.remove(item.id) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                        Text([item.kind.title, item.target].compactMap { $0 }.joined(separator: " "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let countsAs = item.countsAs {
                            if storedLocally.contains(item.id) || catalogLibrary.localTrace(for: item.name) != nil {
                                Label("lokal gespeichert: \(item.kind == .product ? "Produkt" : "zählt wie") \(countsAs)", systemImage: "checkmark")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("\(item.kind == .product ? "Produkt" : "zählt wie") \(countsAs)")
                                    .font(.caption)
                                    .foregroundStyle(Color.sousAccent)
                            }
                        }
                    }
                }
            }
            let storable = storableProposals(optimization)
            Button("Lokal speichern", systemImage: "house") {
                Task { await storeLocally(storable) }
            }
            .disabled(storable.isEmpty)
            Button(didCopyReport ? "Meldung kopiert" : "Meldung kopieren", systemImage: didCopyReport ? "checkmark" : "paperplane") {
                SousPasteboard.copy(optimization.report(optimization.classifications.filter { reported.contains($0.id) }))
                didCopyReport = true
            }
            .disabled(reported.isEmpty)
        } header: {
            Text("Für den Katalog")
        } footer: {
            Text("Sous kennt diese Namen noch nicht. „Lokal speichern“ legt die angehakten „zählt wie“- und Produktvorschläge für diesen Haushalt an: Nährwerte und Gewichte kommen vom Ziel, die Einkaufsliste zeigt weiter den geschriebenen Namen. Die Meldung geht an den Katalog.")
        }
    }

    /// The ticked proposals that name a catalog word to count as, and are
    /// not stored yet.
    private func storableProposals(_ optimization: RecipeOptimization) -> [RecipeOptimization.Classification] {
        optimization.classifications.filter { item in
            reported.contains(item.id) && item.countsAs != nil
                && !storedLocally.contains(item.id)
                && catalogLibrary.localTrace(for: item.name) == nil
        }
    }

    /// Writes the proposals as local answers (INGREDIENTS-DATA §3 B): a
    /// product as a purchase choice, everything else as "zählt wie".
    private func storeLocally(_ proposals: [RecipeOptimization.Classification]) async {
        for item in proposals {
            guard let name = item.countsAs, let target = catalog.ingredient(for: name) else { continue }
            if await catalogLibrary.count(item.name, as: target, kind: item.kind == .product ? .product : .countsAs) {
                storedLocally.insert(item.id)
            }
        }
        if let message = catalogLibrary.errorMessage { failure = message }
    }

    // MARK: - Bindings and texts

    private func binding(line: Int) -> Binding<Bool> {
        Binding(
            get: { selection.lines.contains(line) },
            set: { if $0 { selection.lines.insert(line) } else { selection.lines.remove(line) } }
        )
    }

    private func binding(step: Int) -> Binding<Bool> {
        Binding(
            get: { selection.steps.contains(step) },
            set: { if $0 { selection.steps.insert(step) } else { selection.steps.remove(step) } }
        )
    }

    private func binding(group: String) -> Binding<Bool> {
        Binding(
            get: { selection.groups.contains(group) },
            set: { if $0 { selection.groups.insert(group) } else { selection.groups.remove(group) } }
        )
    }

    private func text(for issue: RecipeOptimization.Line.Issue) -> String {
        switch issue {
        case .amountChanged(let from, let to): "Menge geändert: \(from) → \(to)"
        case .amountInvented(let amount): "Menge erfunden: \(amount)"
        case .amountDropped(let amount): "Menge fehlt: \(amount)"
        case .newWord(let word): "Neues Wort „\(word)“ — Zeilen werden nicht ausgetauscht"
        case .typoTooFar(let wrong, let right): "\(wrong) → \(right) ist kein Tippfehler"
        case .typoNotInLine(let word): "„\(word)“ steht nicht in der Zeile"
        case .typoDoesNotResolve(let word): "Auch „\(word)“ kennt Sous nicht"
        case .removedWithoutPlace: "Die Zeile fiele weg, ohne dass ihr Inhalt irgendwo bleibt"
        case .readsAs(_, let claimed, let read): "Der Chat meint \(claimed), Sous liest \(read ?? "nichts Bekanntes")"
        case .unknownClaim(let name): "„\(name)“ steht nicht im Katalog"
        case .amountRepeated: "Die Menge steht jetzt in mehreren Zeilen"
        case .unweighed(let amount): "„\(amount)“ misst die zubereitete Zutat, und Sous kennt kein Gewicht dafür"
        }
    }

    private func text(for warning: StepReferencesPrompt.Warning, in recipe: Recipe) -> String {
        let lines = recipe.ingredients
        switch warning {
        case .notInStep(let step, let text):
            return "Schritt \(step): Die Menge „\(text)“ steht so nicht im Text und wird nicht umgerechnet."
        case .unreadableAmount(let step, let text):
            return "Schritt \(step): „\(text)“ ist keine lesbare Menge und bleibt, wie sie ist."
        case .overbooked(let line, let percent):
            let name = lines.indices.contains(line - 1) ? lines[line - 1].name : "Zeile \(line)"
            return "\(name): Die im Text geschriebenen Mengen ergeben zusammen \(percent) % der Zeile."
        }
    }
}

/// A variant the optimization proposes, read in full before it is created.
private struct VariantProposalView: View {
    @Environment(\.dismiss) private var dismiss

    let proposal: RecipeOptimization.VariantProposal
    let create: () -> Void

    var body: some View {
        Form {
            Section("Zutaten") {
                Text(proposal.ingredientsText)
                ForEach(proposal.foreignAmounts, id: \.self) { line in
                    Label("„\(line)“: Diese Menge steht nirgends im Rezept.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Section("Zubereitung") {
                Text(proposal.instructionsText)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(proposal.title)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Anlegen") {
                    create()
                    dismiss()
                }
            }
        }
    }
}

/// The first backend: the cook's own chat. Asking is copying the prompt;
/// the answer arrives when the cook pastes it back.
@MainActor @Observable
final class CopyPasteBackend: RecipeOptimizationBackend {
    private var pending: CheckedContinuation<String, any Error>?

    func answer(to prompt: String) async throws -> String {
        SousPasteboard.copy(prompt)
        // Copied again: the earlier question is not waited for any more.
        pending?.resume(throwing: CancellationError())
        return try await withCheckedThrowingContinuation { pending = $0 }
    }

    /// Hands a pasted answer to whoever is waiting — `false` if nobody is.
    func deliver(_ text: String) -> Bool {
        guard let pending else { return false }
        self.pending = nil
        pending.resume(returning: text)
        return true
    }

    func cancel() {
        pending?.resume(throwing: CancellationError())
        pending = nil
    }
}
