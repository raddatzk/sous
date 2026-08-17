import SousKit
import SwiftUI

struct RecipeEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Recipe
    @State private var categoriesText: String
    @State private var isSaving = false

    private let onSave: (Recipe) async -> Void

    init(recipe: Recipe, onSave: @escaping (Recipe) async -> Void) {
        _draft = State(initialValue: recipe)
        _categoriesText = State(initialValue: recipe.categories.joined(separator: ", "))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                basics
                ingredientSection
                stepSection
                Section("Notizen") {
                    TextField("Notizen", text: optional(\.notes), axis: .vertical)
                        .lineLimit(3...)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.title.isEmpty ? "Neues Rezept" : draft.title)
            .toolbar { editorToolbar }
        }
        .frame(minWidth: 480, minHeight: 560)
    }

    @ViewBuilder
    private var basics: some View {
        Section {
            TextField("Titel", text: $draft.title)
            TextField("Kurzbeschreibung", text: optional(\.summary), axis: .vertical)
                .lineLimit(1...3)
            Stepper("Portionen: \(draft.servings)", value: $draft.servings, in: 1...50)
            LabeledContent("Vorbereitung") {
                MinutesField(seconds: $draft.prepTimeSeconds)
            }
            LabeledContent("Kochzeit") {
                MinutesField(seconds: $draft.cookTimeSeconds)
            }
            TextField("Kategorien, mit Komma getrennt", text: $categoriesText)
        }
    }

    @ViewBuilder
    private var ingredientSection: some View {
        Section("Zutaten") {
            ForEach($draft.ingredients) { $ingredient in
                IngredientEditorRow(ingredient: $ingredient)
            }
            .onDelete { draft.ingredients.remove(atOffsets: $0) }
            .onMove { draft.ingredients.move(fromOffsets: $0, toOffset: $1) }

            Button("Zutat hinzufügen", systemImage: "plus") {
                draft.ingredients.append(RecipeIngredient(name: ""))
            }
        }
    }

    @ViewBuilder
    private var stepSection: some View {
        Section("Zubereitung") {
            ForEach(Array($draft.steps.enumerated()), id: \.element.id) { index, $step in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        TextField("Schritt beschreiben", text: $step.text, axis: .vertical)
                            .lineLimit(1...6)
                    }
                    HStack {
                        Text("Timer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        MinutesField(seconds: $step.durationSeconds)
                    }
                }
            }
            .onDelete { draft.steps.remove(atOffsets: $0) }
            .onMove { draft.steps.move(fromOffsets: $0, toOffset: $1) }

            Button("Schritt hinzufügen", systemImage: "plus") {
                draft.steps.append(RecipeStep(text: ""))
            }
        }
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Abbrechen") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Sichern") { save() }
                .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
        }
    }

    private func save() {
        isSaving = true
        var recipe = draft
        recipe.title = recipe.title.trimmingCharacters(in: .whitespaces)
        recipe.categories = categoriesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Rows the user added but never filled in are noise, not data.
        recipe.ingredients.removeAll { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        recipe.steps.removeAll { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }

        Task {
            await onSave(recipe)
            dismiss()
        }
    }

    /// Bridges an optional string property to a `TextField`, treating empty
    /// input as absent.
    private func optional(_ keyPath: WritableKeyPath<Recipe, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}

private struct IngredientEditorRow: View {
    @Binding var ingredient: RecipeIngredient

    @State private var amountText = ""
    @State private var unit: IngredientUnit = .gram

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                TextField("Menge", text: $amountText)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                #if os(iOS)
                    .keyboardType(.decimalPad)
                #endif

                Picker("Einheit", selection: $unit) {
                    ForEach(unitChoices, id: \.self) { choice in
                        Text(choice.symbol).tag(choice)
                    }
                }
                .labelsHidden()
                .frame(width: 96)

                TextField("Zutat", text: $ingredient.name)
            }

            HStack(spacing: 8) {
                TextField("Zubereitung", text: text(\.preparation))
                    .font(.callout)
                TextField("Gruppe", text: text(\.group))
                    .font(.callout)
                    .frame(maxWidth: 120)
            }
        }
        .onAppear {
            if let quantity = ingredient.quantity {
                amountText = Self.format(quantity.amount)
                unit = quantity.unit
            }
        }
        .onChange(of: amountText) { updateQuantity() }
        .onChange(of: unit) { updateQuantity() }
    }

    /// The known units, plus whatever this ingredient already carries, so an
    /// imported "Handvoll" is not silently dropped by the picker.
    private var unitChoices: [IngredientUnit] {
        var choices = IngredientUnit.allKnown
        if let current = ingredient.quantity?.unit, !choices.contains(current) {
            choices.append(current)
        }
        if !choices.contains(unit) {
            choices.append(unit)
        }
        return choices
    }

    private func updateQuantity() {
        let normalized = amountText.replacingOccurrences(of: ",", with: ".")
        guard let amount = Double(normalized), amount > 0 else {
            ingredient.quantity = nil
            return
        }
        ingredient.quantity = Quantity(amount, unit)
    }

    private func text(_ keyPath: WritableKeyPath<RecipeIngredient, String?>) -> Binding<String> {
        Binding(
            get: { ingredient[keyPath: keyPath] ?? "" },
            set: { ingredient[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private static func format(_ amount: Double) -> String {
        amount == amount.rounded()
            ? String(Int(amount))
            : String(amount).replacingOccurrences(of: ".", with: ",")
    }
}

/// A minutes field over a seconds-based property.
private struct MinutesField: View {
    @Binding var seconds: Int?

    var body: some View {
        HStack(spacing: 4) {
            TextField("–", text: minutes)
                .frame(width: 56)
                .multilineTextAlignment(.trailing)
            #if os(iOS)
                .keyboardType(.numberPad)
            #endif
            Text("Min.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var minutes: Binding<String> {
        Binding(
            get: { seconds.map { String($0 / 60) } ?? "" },
            set: { seconds = Int($0).map { $0 * 60 } }
        )
    }
}
