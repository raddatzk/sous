import SousKit
import SwiftUI

struct RecipeEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Recipe
    @State private var categoriesText: String
    @State private var isSaving = false
    @State private var linkTarget: LinkTarget?

    /// Which field a picked recipe link should be appended to.
    private enum LinkTarget: String, Identifiable {
        case ingredients
        case instructions
        var id: String { rawValue }
    }

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

                Section {
                    TextEditor(text: $draft.ingredientsText)
                        .frame(minHeight: 180)
                    Button("Rezept verlinken", systemImage: "link") {
                        linkTarget = .ingredients
                    }
                } header: {
                    Text("Zutaten")
                } footer: {
                    Text("Eine Zutat pro Zeile, etwa „300 g Zucchini, fein gehackt“. Eine Zeile mit Doppelpunkt beginnt einen Abschnitt: „Für den Teig:“")
                }

                Section {
                    TextEditor(text: $draft.instructionsText)
                        .frame(minHeight: 220)
                    Button("Rezept verlinken", systemImage: "link") {
                        linkTarget = .instructions
                    }
                } header: {
                    Text("Zubereitung")
                } footer: {
                    Text("Ein Schritt pro Zeile, Nummerierung übernimmt die App. **Fett** und *kursiv* sind erlaubt, „# Überschrift“ beginnt einen Abschnitt.")
                }

                Section("Notizen") {
                    TextField("Notizen", text: optional(\.notes), axis: .vertical)
                        .lineLimit(3...)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.title.isEmpty ? "Neues Rezept" : draft.title)
            .toolbar { editorToolbar }
            .sheet(item: $linkTarget) { target in
                RecipePickerView(excluding: draft.id) { picked in
                    append(link: picked, to: target)
                }
            }
        }
        // A minimum size is right for a macOS sheet and wrong on a phone,
        // where it pushes the content wider than the screen.
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 620)
        #endif
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

        Task {
            await onSave(recipe)
            dismiss()
        }
    }

    /// Appends the link on its own line. Inserting at the cursor would be
    /// nicer, but a `TextEditor` does not hand out its selection, and a link
    /// on the last line is easy to move.
    private func append(link recipe: Recipe, to target: LinkTarget) {
        let markdown = RecipeLink.markdown(title: recipe.title, id: recipe.id)
        switch target {
        case .ingredients:
            draft.ingredientsText = appending(markdown, to: draft.ingredientsText)
        case .instructions:
            draft.instructionsText = appending(markdown, to: draft.instructionsText)
        }
    }

    private func appending(_ line: String, to text: String) -> String {
        text.isEmpty ? line : text + (text.hasSuffix("\n") ? "" : "\n") + line
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
