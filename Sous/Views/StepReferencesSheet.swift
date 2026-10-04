import SousKit
import SwiftUI

/// Which ingredients each step takes, and which written amounts belong to
/// which line, assigned or corrected by hand. Asking a chat is "Für Sous
/// optimieren", which brings the references along (one AI action, one
/// prompt). See ``StepReferences``.
struct StepReferencesSheet: View {
    @Environment(RecipeLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    let recipe: Recipe

    @AppStorage(SousSetting.optimizationChat, store: .sous)
    private var chat: OptimizationChat?
    /// What is being edited: the stored references while they still fit the
    /// recipe, or an empty start by hand. `nil` until one of those exists.
    @State private var draft: StepReferences?
    /// What the draft started as, so a swipe can tell whether it would lose
    /// anything.
    private let initialDraft: StepReferences?

    private let formatter = QuantityFormatter(locale: .sous)

    init(recipe: Recipe) {
        self.recipe = recipe
        let current = recipe.stepReferences.flatMap { $0.isCurrent(for: recipe) ? $0 : nil }
        _draft = State(initialValue: current)
        initialDraft = current
    }

    private var stored: StepReferences? { recipe.stepReferences }
    private var lines: [RecipeIngredient] { recipe.ingredients }

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                if draft == nil {
                    Section {
                        Button("Von Hand zuordnen", systemImage: "hand.point.up.left") {
                            draft = .empty(for: recipe)
                        }
                    } footer: {
                        Text(chat == .off
                            ? "Schritt für Schritt selbst festlegen, was jeder Schritt braucht. KI ist in den Einstellungen ausgeschaltet."
                            : "Schritt für Schritt selbst festlegen, was jeder Schritt braucht. Schneller geht es mit „Für Sous optimieren“, das die Zuordnung mitbringt.")
                    }
                } else {
                    editor
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Zutaten pro Schritt")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        guard let draft else { return }
                        Task {
                            await library.setStepReferences(draft, for: recipe)
                            dismiss()
                        }
                    }
                    .disabled(draft == nil || draft == stored)
                }
            }
        }
        // Swiping away would drop the draft without a word; once there is
        // something to lose, only the two buttons close it.
        .interactiveDismissDisabled(draft != initialDraft)
        .sousSheetSizing(.page)
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        if let stored {
            Section {
                if !stored.isCurrent(for: recipe) {
                    Label("Das Rezept wurde seitdem geändert — die gespeicherte Zuordnung passt nicht mehr.", systemImage: "exclamationmark.triangle")
                }
                Button("Zuordnung entfernen", role: .destructive) {
                    Task {
                        await library.setStepReferences(nil, for: recipe)
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Editing

    /// One section per step: the step as cook mode will show it, the written
    /// amounts with the line each belongs to, and the chips — every one of
    /// them changeable.
    @ViewBuilder
    private var editor: some View {
        if let draft {
            let rendition = recipeShowing(draft).stepRendition(formatter: formatter)
            ForEach(Array(recipe.steps.enumerated()), id: \.element.id) { stepIndex, step in
                let references = draft.steps.indices.contains(stepIndex) ? draft.steps[stepIndex] : []
                Section {
                    Text(AttributedString(stepSegments: rendition.segments(for: step)))
                        .font(.callout)

                    ForEach(Array(references.enumerated()), id: \.offset) { index, reference in
                        switch reference.kind {
                        case .amount:
                            amountRow(reference, at: index, inStepAt: stepIndex)
                        case .mention:
                            if let line = reference.line {
                                chipRow(line: line, amount: reference.amount, inStepAt: stepIndex)
                            }
                        }
                    }

                    let taken = Set(references.filter { $0.kind == .mention }.compactMap(\.line))
                    Menu {
                        ForEach(Array(lines.enumerated()), id: \.offset) { lineIndex, line in
                            if !taken.contains(lineIndex + 1) {
                                Button(label(for: line)) {
                                    self.draft?.setChip(line: lineIndex + 1, amount: nil, inStepAt: stepIndex)
                                }
                            }
                        }
                    } label: {
                        Label("Zutat hinzufügen", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Schritt \(stepIndex + 1)")
                }
            }
        }
    }

    /// A written amount: the line it scales with, changeable, or let go so
    /// the text stays as written.
    private func amountRow(_ reference: StepReferences.Reference, at index: Int, inStepAt stepIndex: Int) -> some View {
        HStack {
            Text(reference.text)
                .foregroundStyle(Color.sousAccent)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .font(.caption)
            Picker("Zeile", selection: Binding(
                get: { reference.line ?? 0 },
                set: { draft?.setLine($0 == 0 ? nil : $0, forReferenceAt: index, inStepAt: stepIndex) }
            )) {
                Text("Keine Zutat").tag(0)
                // Name and group only — the whole line would be cut off in
                // the row, and the amount is already written in the text.
                ForEach(Array(lines.enumerated()), id: \.offset) { lineIndex, line in
                    Text(line.group.map { "\(line.name) · \($0)" } ?? line.name).tag(lineIndex + 1)
                }
            }
            .labelsHidden()
            Spacer(minLength: 0)
            Button("Zuordnung lösen", systemImage: "xmark.circle") {
                draft?.removeReference(at: index, inStepAt: stepIndex)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    /// A chip: the line, how much of it the step takes, and a way to drop it.
    private func chipRow(line: Int, amount: String?, inStepAt stepIndex: Int) -> some View {
        let ingredient = lines.indices.contains(line - 1) ? lines[line - 1] : nil
        let text = amount ?? ""
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(ingredient?.name ?? "Zeile \(line)")
                    .lineLimit(2)
                // The whole line, so the cook can see what the step's share
                // is a share of.
                if let ingredient {
                    Text(label(for: ingredient))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            TextField("Menge", text: Binding(
                get: { text },
                set: { draft?.setChip(line: line, amount: $0, inStepAt: stepIndex) }
            ))
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 110)
            .foregroundStyle(text.isEmpty || StepReferencesPrompt.readsAsAmount(text) ? Color.primary : Color.red)
            Button("Entfernen", systemImage: "xmark.circle") {
                draft?.removeChip(line: line, fromStepAt: stepIndex)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    /// A line as the cook knows it from the list, with its group where the
    /// list has several — "200 g Butter (Füllung)".
    private func label(for line: RecipeIngredient) -> String {
        let text = formatter.string(for: line)
        guard let group = line.group else { return text }
        return "\(text) (\(group))"
    }

    private func recipeShowing(_ references: StepReferences) -> Recipe {
        var copy = recipe
        copy.stepReferences = references
        return copy
    }
}
