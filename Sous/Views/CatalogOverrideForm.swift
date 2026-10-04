import SousKit
import SwiftUI

/// The edit mode of an ingredient's detail: what the household
/// overrides of the catalog for one word — its aisle, what it is a variety
/// of, further spellings, and the spelling it is shown by.
///
/// Names differ by region (Brötchen, Semmel, Schrippe), so these are the
/// household's to say, and they go before the catalog's. Exactly these four
/// fields; numbers, weights and products stay with the local answer
/// (``LocalAnswerForm``). A spelling the catalog gives to another word is
/// claimed only after one question, here — never later as a conflict.
struct CatalogOverrideForm: View {
    @Environment(IngredientCatalogLibrary.self) private var catalog
    @Environment(NutritionLibrary.self) private var nutrition
    @Environment(\.dismiss) private var dismiss

    /// The word as the household catalog has it when the form opens.
    let word: CatalogIngredient

    @State private var draft: OverrideDraft
    private let initialDraft: OverrideDraft
    @State private var parentQuery = ""
    @State private var newSpelling = ""
    /// What the last typed spelling could not be, said under the field.
    @State private var spellingHint: String?
    /// A spelling of another catalog word, waiting for "umdeuten".
    @State private var claim: Claim?
    @State private var isWriting = false

    private struct Claim: Identifiable {
        let spelling: String
        let owner: String
        var id: String { spelling }
    }

    init(word: CatalogIngredient, answer: LocalAnswer?) {
        self.word = word
        let draft = OverrideDraft(answer)
        _draft = State(initialValue: draft)
        initialDraft = draft
    }

    private var hasChanges: Bool { draft != initialDraft }

    /// The word as the data set's catalog has it — `nil` for one only the
    /// household knows.
    private var catalogWord: CatalogIngredient? { catalog.catalogWord(of: word) }

    var body: some View {
        NavigationStack {
            Form {
                categorySection
                parentSection
                spellingsSection
                displayNameSection
            }
            .formStyle(.grouped)
            .navigationTitle("„\(word.shownName)“ anpassen")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { save() }
                        .disabled(!hasChanges || isWriting)
                }
            }
            .sousConfirmation(
                claim.map { "Im Katalog ist „\($0.spelling)“ \($0.owner)" } ?? "",
                isPresented: Binding(get: { claim != nil }, set: { if !$0 { claim = nil } }),
                message: claim.map {
                    "Für deinen Haushalt umdeuten? Dann liest Sous „\($0.spelling)“ in deinen Rezepten als \(word.shownName)."
                } ?? ""
            ) {
                if let claim {
                    Button("Umdeuten") {
                        draft.spellings.append(claim.spelling)
                        newSpelling = ""
                    }
                }
            }
        }
        .interactiveDismissDisabled(hasChanges)
        .sousSheetSizing(.form)
    }

    // MARK: - Sections

    private var categorySection: some View {
        Section {
            Picker("Kategorie", selection: $draft.category) {
                Text("wie im Katalog (\((catalogWord ?? word).category.title))").tag(IngredientCategory?.none)
                ForEach(IngredientCategory.allCases.sorted { $0.aisleOrder < $1.aisleOrder }, id: \.self) { category in
                    Text(category.title).tag(Optional(category))
                }
            }
        } footer: {
            Text("Der Gang, in dem die Zutat auf der Einkaufsliste steht – und ihre Sorten mit ihr, solange sie keinen eigenen haben.")
        }
    }

    private var parentSection: some View {
        Section {
            if let parentID = draft.parentID {
                HStack {
                    Text(catalog.catalogWithoutLocalAnswers.ingredient(forID: parentID)?.name ?? parentID)
                    Spacer()
                    Button("Entfernen", role: .destructive) { draft.parentID = nil }
                        .buttonStyle(.borderless)
                }
            } else {
                if let parent = catalogWord?.parentName {
                    LabeledContent("Im Katalog", value: parent)
                }
                TextField("Stamm-Zutat suchen", text: $parentQuery)
                ForEach(parentChoices) { choice in
                    Button {
                        draft.parentID = choice.catalogID
                        parentQuery = ""
                    } label: {
                        Text(choice.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Sorte von")
        } footer: {
            Text("Eine Sorte steht auf der Einkaufsliste als eigene Zeile, im Gang ihrer Stamm-Zutat, mit deren Vorrat, Supermarkt und Notiz – und rechnet mit deren Werten, solange sie keine eigenen hat.")
        }
    }

    /// Catalog words to choose as the parent: never the word itself, nor
    /// one of its own varieties, nor a product.
    private var parentChoices: [CatalogIngredient] {
        catalog.catalogWithoutLocalAnswers.search(parentQuery, limit: 12)
            .filter { candidate in
                candidate.catalogID != nil && candidate.product == nil && candidate.key != word.key
                    && !catalog.catalog.ancestors(of: candidate.name).contains { $0.key == word.key }
            }
            .prefix(8)
            .map { $0 }
    }

    private var spellingsSection: some View {
        Section {
            if let aliases = catalogAliases, !aliases.isEmpty {
                LabeledContent("Im Katalog") {
                    Text(aliases.joined(separator: ", "))
                        .multilineTextAlignment(.trailing)
                }
            }
            ForEach(draft.spellings, id: \.self) { spelling in
                HStack {
                    Text(spelling)
                    Spacer()
                    Button("Entfernen", role: .destructive) {
                        draft.spellings.removeAll { $0 == spelling }
                        if draft.displayName == spelling { draft.displayName = nil }
                    }
                    .buttonStyle(.borderless)
                }
            }
            TextField("Schreibweise hinzufügen, z. B. Schrippe", text: $newSpelling)
                .onSubmit(addSpelling)
                .onChange(of: newSpelling) { spellingHint = nil }
            if let spellingHint {
                Text(spellingHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Schreibweisen")
        } footer: {
            Text("Eine eigene Schreibweise ist dieselbe Zutat: dieselbe Zeile auf der Einkaufsliste, derselbe Vorrat.")
        }
    }

    /// The catalog's own spellings of the word, which the household keeps.
    private var catalogAliases: [String]? { catalogWord?.aliases }

    private func addSpelling() {
        let spelling = newSpelling.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = IngredientCatalog.normalize(spelling)
        guard !key.isEmpty else { return }
        if draft.spellings.contains(where: { IngredientCatalog.normalize($0) == key }) {
            spellingHint = "„\(spelling)“ steht schon da."
            return
        }
        // A spelling saved before, taken out in this draft, comes back as it was.
        if initialDraft.spellings.contains(where: { IngredientCatalog.normalize($0) == key }) {
            draft.spellings.append(spelling)
            newSpelling = ""
            return
        }
        switch catalog.checkSpelling(spelling, for: word) {
        case .empty:
            return
        case .alreadyKnown:
            spellingHint = "„\(word.shownName)“ kennt „\(spelling)“ schon."
        case .new:
            draft.spellings.append(spelling)
            newSpelling = ""
        case .claims(let owner):
            claim = Claim(spelling: spelling, owner: owner)
        case .taken(let owner):
            spellingHint = "„\(spelling)“ ist im Katalog die Zutat „\(owner)“ und lässt sich nicht umdeuten."
        }
    }

    private var displayNameSection: some View {
        Section {
            Picker("Anzeigen als", selection: $draft.displayName) {
                Text(word.name).tag(String?.none)
                ForEach(displayChoices, id: \.self) { spelling in
                    Text(spelling).tag(Optional(spelling))
                }
            }
        } header: {
            Text("Anzeigename")
        } footer: {
            Text("So heißt die Zutat für deinen Haushalt im Katalog, auf der Einkaufsliste und in den Vorschlägen. Was sie ist, ändert sich dadurch nicht.")
        }
    }

    /// The spellings the word may be shown by, besides its name.
    private var displayChoices: [String] {
        var seen: Set<String> = [word.key]
        return ((catalogAliases ?? []) + draft.spellings)
            .filter { seen.insert(IngredientCatalog.normalize($0)).inserted }
    }

    private func save() {
        guard !isWriting else { return }
        isWriting = true
        Task {
            await catalog.saveOverrides(
                of: word,
                category: draft.category,
                parentID: draft.parentID,
                spellings: draft.spellings,
                displayName: draft.displayName
            )
            await nutrition.ensureLoaded()
            dismiss()
        }
    }
}

/// The form's fields as chosen.
private struct OverrideDraft: Equatable {
    var category: IngredientCategory?
    var parentID: String?
    var spellings: [String] = []
    var displayName: String?

    init(_ answer: LocalAnswer?) {
        category = answer?.category
        parentID = answer?.parentID
        spellings = answer?.spellings ?? []
        displayName = answer?.displayName
    }
}

/// One place where the catalog has moved away from what the household
/// says, asked quietly: what the catalog says now, what the
/// household says, and the two ways out. In the ingredient's detail and
/// under "Abweichungen" in the catalog.
struct CatalogConflictRow: View {
    @Environment(IngredientCatalogLibrary.self) private var catalog
    @Environment(NutritionLibrary.self) private var nutrition

    let conflict: CatalogConflict
    /// Whether the word is named — in the catalog's list, not in its own
    /// detail.
    var namesWord = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if namesWord {
                Text(conflict.word)
                    .font(.headline)
            }
            Text(conflict.message)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button("Katalog übernehmen") {
                    Task {
                        await catalog.adoptCatalog(conflict)
                        await nutrition.ensureLoaded()
                    }
                }
                Button("Meine behalten") {
                    Task { await catalog.keepLocal(conflict) }
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(.vertical, 2)
    }
}
