import SousKit
import SwiftUI

/// "Mit KI bearbeiten": the cook's request — a saved template or a line they
/// type — copied together with the recipe and the catalog for a chat model
/// they already use; the chat shows the rewritten recipe, they talk about it,
/// and the JSON block of its last answer is pasted back here.
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

    enum Outcome: Hashable {
        case replace, new, variant
    }

    @AppStorage(SousSetting.optimizationChat, store: .sous)
    private var chat: OptimizationChat?
    @State private var typed = ""
    @State private var didCopy = false
    @State private var replacement: RecipeReplacement?
    @State private var outcome = Outcome.replace
    @State private var fields = RecipeReplacement.Fields.standard
    @State private var failure: String?
    /// The household's categories, most used first, for the prompt.
    @State private var categories: [String] = []
    @State private var showsNewIngredients = true
    @State private var showsNewSteps = true

    private var task: String { request.text ?? typed }
    private var canCopy: Bool { !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                askSection
                pasteSection
                if let replacement {
                    previewSection(replacement)
                }
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
                        .disabled(replacement == nil)
                }
            }
        }
        // A read answer is work the cook would lose by a swipe.
        .interactiveDismissDisabled(replacement != nil)
        .sousSheetSizing(.page)
        .task {
            categories = await library.categoryCounts()
                .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
                .prefix(80)
                .map(\.name)
        }
    }

    // MARK: - Asking

    private var askSection: some View {
        Section {
            if request.text == nil {
                TextField("Was soll sich ändern?", text: $typed, axis: .vertical)
                    .lineLimit(2...6)
            }
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
                OptimizationChatPicker()
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
            replacement = value
            failure = nil
        case .failure(let error):
            replacement = nil
            failure = error.localizedDescription
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private func previewSection(_ replacement: RecipeReplacement) -> some View {
        Section {
            if replacement.hasStepReferences {
                Label("Mit den Zutaten jedes Schritts — der Kochmodus rechnet die Mengen im Text mit.", systemImage: "wand.and.stars")
                    .foregroundStyle(.secondary)
            } else {
                Label("Die Antwort sagt nicht, welche Zutaten jeder Schritt braucht. Bitte den Chat darum, dann rechnet der Kochmodus die Mengen mit.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        Section {
            Picker("Was damit geschieht", selection: $outcome) {
                Text("Rezept ersetzen").tag(Outcome.replace)
                Text("Als neues Rezept").tag(Outcome.new)
                Text("Als Variante anlegen").tag(Outcome.variant)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("Ergebnis")
        } footer: {
            switch outcome {
            case .replace:
                Text("Das Rezept wird ersetzt. Die bisherige Fassung bleibt unter „Mehr“ › „Versionen“ erhalten und lässt sich dort vergleichen und wiederherstellen.")
            case .new:
                Text("Das Ergebnis wird ein eigenes Rezept, das aktuelle bleibt unverändert.")
            case .variant:
                Text("Das Ergebnis kommt als Variante neben das aktuelle Rezept, das unverändert bleibt.")
            }
        }

        if outcome == .replace {
            Section("Übernehmen") {
                Toggle(isOn: binding(.title)) { fieldLabel("Titel", old: recipe.title, new: replacement.title) }
                if let summary = replacement.summary {
                    Toggle(isOn: binding(.summary)) { fieldLabel("Beschreibung", old: recipe.summary, new: summary) }
                }
                if let servings = replacement.servings {
                    Toggle(isOn: binding(.servings)) {
                        fieldLabel("Portionen", old: "\(recipe.servings)", new: "\(servings)")
                    }
                }
                if let categories = replacement.categories {
                    Toggle(isOn: binding(.categories)) {
                        fieldLabel("Kategorien", old: recipe.categories.joined(separator: ", "), new: categories.joined(separator: ", "))
                    }
                }
            }
        } else {
            Section("Titel") { Text(replacement.title) }
        }

        let proposed = Recipe(
            title: replacement.title,
            servings: replacement.servings ?? recipe.servings,
            ingredientsText: replacement.ingredientsText,
            instructionsText: replacement.instructionsText
        )
        Section("Zutaten") {
            DisclosureGroup("Neu", isExpanded: $showsNewIngredients) {
                IngredientsPreview(recipe: proposed)
            }
            DisclosureGroup("Bisher") {
                IngredientsPreview(recipe: recipe)
            }
        }
        Section("Zubereitung") {
            DisclosureGroup("Neu", isExpanded: $showsNewSteps) {
                StepsPreview(recipe: proposed)
            }
            DisclosureGroup("Bisher") {
                StepsPreview(recipe: recipe)
            }
        }
    }

    private func fieldLabel(_ name: String, old: String?, new: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
            Text(new).font(.caption).foregroundStyle(.secondary)
            if let old, !old.isEmpty, old != new {
                Text("Bisher: \(old)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func binding(_ field: RecipeReplacement.Fields) -> Binding<Bool> {
        Binding(
            get: { fields.contains(field) },
            set: { if $0 { fields.insert(field) } else { fields.remove(field) } }
        )
    }

    // MARK: - Taking it

    private func apply() {
        guard let replacement else { return }
        let outcome = outcome
        let fields = fields
        Task {
            switch outcome {
            case .replace:
                if await library.applyReplacement(replacement, fields: fields, request: request.title, to: recipe) {
                    dismiss()
                } else {
                    failure = "Das Rezept wurde inzwischen geändert. Bitte den Prompt neu kopieren und neu fragen."
                    self.replacement = nil
                }
            case .new, .variant:
                if await library.addReplacement(replacement, of: recipe, asVariant: outcome == .variant) != nil {
                    dismiss()
                }
            }
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
