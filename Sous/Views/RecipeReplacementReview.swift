import SousKit
import SwiftUI

/// What the cook is about to take from a model's rewrite: the replacement,
/// what to do with it, which fields, and the same lines brought into Sous's
/// form. Shared by the sheet that pastes an answer and the one that talks to
/// a provider, which differ in how the replacement arrives and in nothing
/// after that.
@MainActor @Observable
final class RecipeReplacementDraft {
    enum Outcome: Hashable {
        case replace, new, variant
    }

    let recipe: Recipe
    let requestTitle: String

    var replacement: RecipeReplacement? {
        didSet { if replacement != oldValue { resetTidying() } }
    }
    var outcome = Outcome.replace
    var fields = RecipeReplacement.Fields.standard
    /// The proposal with its lines brought into Sous's form, where they were not.
    private(set) var tidied: Recipe?
    private(set) var isTidying = false
    private(set) var tidyProblem: String?
    /// Why taking it failed, for the sheet to say.
    var failure: String?
    private var tidyTask: Task<Void, Never>?

    init(recipe: Recipe, requestTitle: String) {
        self.recipe = recipe
        self.requestTitle = requestTitle
    }

    /// The proposal as Sous would read it: the lines as the model wrote them.
    var candidate: Recipe? { replacement.map { $0.applied(to: recipe, fields: fields) } }
    /// Whether the lines are in Sous's form now, tidied or not.
    var isInForm: Bool { (tidied ?? candidate)?.isOptimizedForSous == true }

    func resetTidying() {
        tidyTask?.cancel()
        tidied = nil
        isTidying = false
        tidyProblem = nil
    }

    func cancel() { tidyTask?.cancel() }

    /// Brings the lines into form with the cook's provider: nothing is asked
    /// where they are in form already.
    func tidy(with connection: AIConnection, catalog: IngredientCatalog, nutritionCatalog: NutritionCatalog) {
        guard let edited = candidate, !isTidying, !edited.isOptimizedForSous else { return }
        isTidying = true
        tidyProblem = nil
        tidyTask = Task { @MainActor in
            defer { isTidying = false }
            do {
                switch try await RecipeTidier.tidy(
                    edited, catalog: catalog, nutritionCatalog: nutritionCatalog, backend: connection.client()
                ) {
                case .success(let result): tidied = result
                case .failure(let reason): tidyProblem = "Aufräumen nicht möglich: \(reason.providerDescription)"
                case nil: break
                }
            } catch is CancellationError {
            } catch {
                tidyProblem = error.localizedDescription
            }
        }
    }

    /// Takes it into the library; `false` where that was refused.
    func apply(to library: RecipeLibrary) async -> Bool {
        guard let replacement else { return false }
        switch outcome {
        case .replace:
            if await library.applyReplacement(
                replacement, fields: fields, tidied: tidied, request: requestTitle, to: recipe
            ) {
                return true
            }
            failure = "Das Rezept wurde inzwischen geändert. Bitte neu fragen."
            self.replacement = nil
            return false
        case .new, .variant:
            return await library.addReplacement(replacement, of: recipe, asVariant: outcome == .variant) != nil
        }
    }
}

/// The sections of a proposal: whether its lines are in Sous's form, what is
/// done with it, which fields, and the ingredients and steps old and new.
struct RecipeReplacementSections: View {
    @Bindable var draft: RecipeReplacementDraft
    /// The provider that can tidy the lines; without one the cook is told.
    let connection: AIConnection?

    @Environment(IngredientCatalogLibrary.self) private var catalogLibrary
    @Environment(NutritionLibrary.self) private var nutritionLibrary
    @State private var showsNewIngredients = true
    @State private var showsNewSteps = true

    var body: some View {
        if let replacement = draft.replacement {
            tidyingSection
            outcomeSections(replacement)
            previewSections(replacement)
        }
    }

    private var tidyingSection: some View {
        Section {
            if draft.isTidying {
                HStack { ProgressView(); Text("Zeilen werden für Sous aufgeräumt …") }
            } else if draft.isInForm {
                Label(
                    draft.tidied == nil ? "Alle Zeilen sind in Sous-Form." : "Die Zeilen sind für Sous aufgeräumt.",
                    systemImage: "checkmark.seal")
            } else if draft.tidied != nil {
                // Tidying never invents an amount: a line without one stays as written.
                Label("Aufgeräumt, soweit es ging. Zeilen ohne Menge bleiben, wie sie sind.", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
            } else {
                Label("Einige Zeilen sind noch nicht in Sous-Form.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                if let connection {
                    Button("Für Sous aufräumen", systemImage: "sparkles") {
                        draft.tidy(
                            with: connection, catalog: catalogLibrary.catalog,
                            nutritionCatalog: nutritionLibrary.nutritionCatalog)
                    }
                }
            }
            if let problem = draft.tidyProblem {
                Label(problem, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
            if let failure = draft.failure {
                Label(failure, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
        } header: {
            Text("Für Sous")
        } footer: {
            if !draft.isInForm && draft.tidied == nil && !draft.isTidying {
                Text("Auch nach dem Übernehmen lässt sich das Rezept über „Für Sous optimieren“ aufräumen. Als neues Rezept oder Variante wird es unaufgeräumt angelegt.")
            }
        }
    }

    @ViewBuilder
    private func outcomeSections(_ replacement: RecipeReplacement) -> some View {
        Section {
            if replacement.hasStepReferences {
                Label("Mit den Zutaten jedes Schritts — der Kochmodus rechnet die Mengen im Text mit.", systemImage: "wand.and.stars")
                    .foregroundStyle(.secondary)
            } else {
                Label("Die Antwort sagt nicht, welche Zutaten jeder Schritt braucht. Bitte um sie, dann rechnet der Kochmodus die Mengen mit.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        Section {
            Picker("Was damit geschieht", selection: $draft.outcome) {
                Text("Rezept ersetzen").tag(RecipeReplacementDraft.Outcome.replace)
                Text("Als neues Rezept").tag(RecipeReplacementDraft.Outcome.new)
                Text("Als Variante anlegen").tag(RecipeReplacementDraft.Outcome.variant)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("Ergebnis")
        } footer: {
            switch draft.outcome {
            case .replace:
                Text("Das Rezept wird ersetzt. Die bisherige Fassung bleibt unter „Mehr“ › „Versionen“ erhalten und lässt sich dort vergleichen und wiederherstellen.")
            case .new:
                Text("Das Ergebnis wird ein eigenes Rezept, das aktuelle bleibt unverändert.")
            case .variant:
                Text("Das Ergebnis kommt als Variante neben das aktuelle Rezept, das unverändert bleibt.")
            }
        }

        if draft.outcome == .replace {
            let recipe = draft.recipe
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
    }

    @ViewBuilder
    private func previewSections(_ replacement: RecipeReplacement) -> some View {
        let recipe = draft.recipe
        let proposed = Recipe(
            title: replacement.title,
            servings: replacement.servings ?? recipe.servings,
            ingredientsText: draft.tidied?.ingredientsText ?? replacement.ingredientsText,
            instructionsText: draft.tidied?.instructionsText ?? replacement.instructionsText
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
            get: { draft.fields.contains(field) },
            set: { if $0 { draft.fields.insert(field) } else { draft.fields.remove(field) } }
        )
    }
}
