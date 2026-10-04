import SousKit
import SwiftUI

/// The household's requests for a chat model — "Haushalt → KI-Prompts". The
/// built-in ones are read-only and can be copied into one's own; the
/// household's own are edited, deleted and shared with whoever is in it.
struct PromptTemplatesView: View {
    @Environment(PromptTemplateLibrary.self) private var library

    @State private var editing: PromptTemplate?

    var body: some View {
        Form {
            Section {
                ForEach(library.own) { template in
                    Button { editing = template } label: {
                        row(template)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button("Löschen", role: .destructive) {
                            Task { await library.delete(template) }
                        }
                    }
                }
                Button("Neuer Prompt", systemImage: "plus") {
                    editing = PromptTemplate(title: "", text: "{{recipe}}")
                }
            } header: {
                Text("Eigene")
            } footer: {
                Text("Der Prompt sagt, was die KI mit dem Rezept tun soll. Wo {{recipe}} steht, setzt Sous das Rezept ein; Regeln, Antwortformat und Zutatenkatalog kommen automatisch dazu.")
            }
            Section("Vorgegeben") {
                ForEach(PromptTemplate.builtIn) { template in
                    row(template)
                        .contextMenu {
                            Button("Als eigenen Prompt kopieren", systemImage: "doc.on.doc") {
                                editing = PromptTemplate(title: template.title, text: template.text)
                            }
                        }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("KI-Prompts")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await library.reload() }
        .sheet(item: $editing) { template in
            PromptTemplateEditor(template: template)
        }
    }

    private func row(_ template: PromptTemplate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(template.title)
            Text(template.text.replacingOccurrences(of: RecipeReplacementPrompt.placeholder, with: "…"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

private struct PromptTemplateEditor: View {
    @Environment(PromptTemplateLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State var template: PromptTemplate

    var body: some View {
        NavigationStack {
            Form {
                Section("Titel") {
                    TextField("z. B. Vegan machen", text: $template.title)
                }
                Section {
                    TextField("Was soll die KI tun?", text: $template.text, axis: .vertical)
                        .lineLimit(4...12)
                } header: {
                    Text("Prompt")
                } footer: {
                    Text("{{recipe}} steht für das Rezept. Fehlt es, hängt Sous das Rezept hinten an.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Prompt")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        Task {
                            await library.save(template)
                            dismiss()
                        }
                    }
                    .disabled(template.isEmpty)
                }
            }
        }
        .sousSheetSizing(.page)
    }
}
