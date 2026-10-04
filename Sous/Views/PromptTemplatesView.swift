import SousKit
import SwiftUI

/// The household's requests for a chat model — "Haushalt → KI-Prompts". The
/// ones every household starts with are ordinary entries: changed, taken away
/// and brought back like any other.
struct PromptTemplatesView: View {
    @Environment(PromptTemplateLibrary.self) private var library

    @State private var editing: PromptTemplate?
    @State private var isConfirmingRestore = false

    var body: some View {
        Form {
            Section {
                ForEach(library.all) { template in
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
                Button("Neuer Prompt", systemImage: "plus.circle.fill") {
                    editing = PromptTemplate(title: "", text: PromptTemplatesView.newText)
                }
            } footer: {
                Text("Der Prompt sagt, was die KI mit dem Rezept tun soll. Wo {{recipe}} steht, setzt Sous das Rezept ein; Regeln, Antwortformat und Zutatenkatalog kommen automatisch dazu.")
            }
            if library.hasChangedBuiltIns {
                Section {
                    Button("Vorgaben wiederherstellen", systemImage: "arrow.counterclockwise") {
                        isConfirmingRestore = true
                    }
                } footer: {
                    Text("Stellt die mitgelieferten Prompts so wieder her, wie sie waren — auch gelöschte. Eigene bleiben.")
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
        .sousConfirmation(
            "Vorgaben wiederherstellen?",
            isPresented: $isConfirmingRestore,
            message: "Geänderte mitgelieferte Prompts stehen wieder im Ausgangszustand da, gelöschte kommen zurück. Eigene Prompts bleiben."
        ) {
            Button("Wiederherstellen", role: .destructive) {
                Task { await library.restoreBuiltIns() }
            }
        }
    }

    private static let newText = "{{recipe}}"

    private func row(_ template: PromptTemplate) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(.tint.opacity(0.12), in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(template.title)
                    .foregroundStyle(.primary)
                Text(template.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
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
