import SousKit
import SwiftUI

/// "Mit KI bearbeiten" by copy and paste: the cook's request — a saved
/// template or a line they type — copied together with the recipe and the
/// catalog for a chat model they already use; the chat shows the rewritten
/// recipe, they talk about it, and the JSON block of its last answer is
/// pasted back here. (With a provider of their own, `RecipeAIChatSheet` does
/// the talking instead.)
///
/// What comes back replaces the recipe (one step back, and the original
/// stays), or becomes a recipe of its own, or a variant beside it. Nothing is
/// written before the cook confirms. See ``RecipeReplacement``.
struct RecipeAIEditSheet: View {
    /// The request: a template's text, or `nil` where the cook types it.
    struct Request: Identifiable {
        let id = UUID()
        let title: String
        let text: String?
    }

    @Environment(RecipeLibrary.self) private var library
    @Environment(IngredientCatalogLibrary.self) private var catalogLibrary
    @Environment(\.dismiss) private var dismiss

    let recipe: Recipe
    let request: Request

    @AppStorage(SousSetting.optimizationChat, store: .sous)
    private var chat: OptimizationChat?
    @State private var draft: RecipeReplacementDraft
    @State private var typed = ""
    @State private var didCopy = false
    @State private var failure: String?
    /// The household's categories, most used first, for the prompt.
    @State private var categories: [String] = []

    init(recipe: Recipe, request: Request) {
        self.recipe = recipe
        self.request = request
        _draft = State(initialValue: RecipeReplacementDraft(recipe: recipe, requestTitle: request.title))
    }

    private var task: String { request.text ?? typed }
    private var canCopy: Bool { !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                if request.text == nil { taskSection }
                askSection
                pasteSection
                RecipeReplacementSections(draft: draft, connection: nil)
            }
            .formStyle(.grouped)
            .navigationTitle(request.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { apply() }
                        .disabled(draft.replacement == nil)
                }
            }
        }
        // A read answer is work the cook would lose by a swipe.
        .interactiveDismissDisabled(draft.replacement != nil)
        .sousSheetSizing(.page)
        .task {
            categories = await library.categoryCounts()
                .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
                .prefix(80)
                .map(\.name)
        }
    }

    // MARK: - Asking

    private var taskSection: some View {
        Section {
            TextField("Was soll sich ändern?", text: $typed, axis: .vertical)
                .lineLimit(2...6)
        }
    }

    private var askSection: some View {
        Section {
            Button(didCopy ? "Prompt kopiert" : "Prompt kopieren", systemImage: didCopy ? "checkmark" : "doc.on.doc") {
                SousPasteboard.copy(RecipeReplacementPrompt.prompt(
                    task: task, for: recipe, catalog: catalogLibrary.catalog, categories: categories
                ))
                didCopy = true
            }
            .disabled(!canCopy)
            if let chat {
                if let url = chat.url {
                    Link(destination: url) {
                        Label("\(chat.title) öffnen", systemImage: "arrow.up.forward.app")
                    }
                }
            } else {
                OptimizationChatPicker(includesOff: false)
            }
        } header: {
            Text("Chat fragen")
        } footer: {
            Text("Der Chat zeigt dir das Rezept lesbar und dazu den aktuellen Stand als JSON-Block. Ihr könnt so lange darüber sprechen, wie ihr wollt; kopiere zum Schluss den JSON-Block der letzten Antwort.")
        }
    }

    private var pasteSection: some View {
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
            Text("Antwort einfügen")
        }
    }

    private func read(_ pasted: String) {
        switch RecipeReplacementPrompt.read(pasted) {
        case .success(let value):
            draft.replacement = value
            failure = nil
        case .failure(let error):
            draft.replacement = nil
            failure = error.localizedDescription
        }
    }

    private func apply() {
        Task {
            if await draft.apply(to: library) { dismiss() }
        }
    }
}

/// A recipe's ingredients as the recipe page shows them — groups under their
/// headings, the amount in the accent — without the taps of the real lines:
/// this is what a proposal would look like, not something to work with.
struct IngredientsPreview: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(recipe.ingredientGroups(), id: \.group) { group in
                VStack(alignment: .leading, spacing: 8) {
                    if let name = group.group {
                        Text(name).font(SousStyle.groupHeading)
                    }
                    ForEach(group.ingredients) { ingredient in
                        IngredientLineView(ingredient: ingredient)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

/// A recipe's steps as the recipe page shows them: numbered, the numbering
/// starting again under each heading.
struct StepsPreview: View {
    let recipe: Recipe

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(recipe.stepGroups, id: \.group) { group in
                if let name = group.group {
                    Text(name).font(SousStyle.groupHeading)
                }
                ForEach(Array(group.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text("\(index + 1)")
                            .font(SousStyle.groupHeading)
                            .foregroundStyle(.tint)
                            .frame(minWidth: 20, alignment: .trailing)
                        Text(AttributedString(inlineMarkdown: step.text))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}
