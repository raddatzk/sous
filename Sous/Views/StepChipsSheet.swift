import SousKit
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Lets a chat model the cook already uses say what each step takes: copy
/// the prompt, paste it into ChatGPT or Claude, paste the answer back. Sous
/// never talks to the model itself — see ``StepChips``.
struct StepChipsSheet: View {
    @Environment(RecipeLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    let recipe: Recipe

    @State private var didCopy = false
    @State private var reading: StepChipsPrompt.Reading?
    @State private var failure: String?

    private let formatter = QuantityFormatter(locale: .sous)

    var body: some View {
        NavigationStack {
            Form {
                if let stored = recipe.stepChips {
                    Section {
                        if stored.isCurrent(for: recipe) {
                            Label("Für dieses Rezept liegen Zutaten pro Schritt vor.", systemImage: "checkmark.circle")
                        } else {
                            Label("Das Rezept wurde seitdem geändert — die Zutaten pro Schritt passen nicht mehr.", systemImage: "exclamationmark.triangle")
                        }
                        Button("Entfernen", role: .destructive) {
                            Task {
                                await library.setStepChips(nil, for: recipe)
                                dismiss()
                            }
                        }
                    }
                }

                Section {
                    Button(didCopy ? "Prompt kopiert" : "Prompt kopieren", systemImage: didCopy ? "checkmark" : "doc.on.doc") {
                        copy(StepChipsPrompt.prompt(for: recipe))
                        didCopy = true
                    }
                    Link(destination: URL(string: "https://chatgpt.com/")!) {
                        Label("ChatGPT öffnen", systemImage: "arrow.up.forward.app")
                    }
                    Link(destination: URL(string: "https://claude.ai/new")!) {
                        Label("Claude öffnen", systemImage: "arrow.up.forward.app")
                    }
                } header: {
                    Text("1. Fragen")
                } footer: {
                    Text("Den kopierten Text in einen neuen Chat einfügen und abschicken.")
                }

                Section {
                    PasteButton(payloadType: String.self) { strings in
                        let pasted = strings.joined(separator: "\n")
                        Task { @MainActor in read(pasted) }
                    }
                    if let failure {
                        Label(failure, systemImage: "xmark.octagon")
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("2. Antwort einfügen")
                } footer: {
                    Text("Die Antwort des Chats kopieren — am einfachsten über den Kopieren-Knopf am Codeblock.")
                }

                if let reading {
                    if !reading.warnings.isEmpty {
                        Section("Hinweise") {
                            ForEach(reading.warnings, id: \.self) { warning in
                                Label(text(for: warning), systemImage: "exclamationmark.triangle")
                            }
                        }
                    }
                    preview(reading.chips)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Zutaten pro Schritt")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Übernehmen") {
                        guard let reading else { return }
                        Task {
                            await library.setStepChips(reading.chips, for: recipe)
                            dismiss()
                        }
                    }
                    .disabled(reading == nil)
                }
            }
        }
    }

    /// Each step with the chips the answer gives it, the way cook mode will
    /// show them — so a wrong answer is caught before it is kept.
    @ViewBuilder
    private func preview(_ chips: StepChips) -> some View {
        let byStep = chips.ingredientsByStep(of: recipe) ?? []
        Section("Vorschau") {
            ForEach(Array(zip(recipe.steps, byStep).enumerated()), id: \.element.0.id) { index, pair in
                let (step, used) = pair
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(index + 1). \(markdown(step.text))")
                        .font(.callout)
                        .lineLimit(3)
                    if used.isEmpty {
                        Text("Keine Zutaten")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(used) { ingredient in
                                IngredientLineView(ingredient: ingredient, formatter: formatter)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.tint.opacity(SousStyle.chipTint), in: .capsule)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// Steps carry the same inline markdown as everywhere else — a bold
    /// phase name reads bold here too.
    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private func read(_ pasted: String) {
        switch StepChipsPrompt.read(pasted, for: recipe) {
        case .success(let value):
            reading = value
            failure = nil
        case .failure(let error):
            reading = nil
            failure = error.localizedDescription
        }
    }

    private func text(for warning: StepChipsPrompt.Warning) -> String {
        let lines = recipe.ingredients
        func name(_ line: Int) -> String {
            lines.indices.contains(line - 1) ? lines[line - 1].name : "Zeile \(line)"
        }
        switch warning {
        case .unreadableAmount(let step, let line, let amount):
            return "Schritt \(step): „\(amount)“ bei \(name(line)) ist keine lesbare Menge — der Chip bleibt ohne."
        case .overbooked(let line, let percent):
            return "\(name(line)): Die Schritte nehmen zusammen \(percent) % der Menge."
        }
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
