import SousKit
import SwiftUI

/// The ingredient catalog: what the app knows, and what you taught it.
struct IngredientCatalogView: View {
    @Environment(IngredientCatalogLibrary.self) private var catalog
    @Environment(NutritionLibrary.self) private var nutrition
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var editing: CatalogIngredient?
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(groups, id: \.category) { group in
                    Section {
                        ForEach(group.ingredients) { ingredient in
                            row(ingredient)
                        }
                    } header: {
                        Text(group.category.title)
                            .font(SousStyle.groupHeading)
                            .textCase(nil)
                    }
                }
            }
            .navigationTitle("Zutaten")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Zutat suchen"
            )
            #else
            .searchable(text: $searchText, prompt: "Zutat suchen")
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Zutat hinzufügen", systemImage: "plus") { isAdding = true }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .overlay {
                if groups.isEmpty {
                    ContentUnavailableView.search
                }
            }
        }
        .task {
            await catalog.reload()
            await nutrition.reload()
        }
        .sheet(item: $editing) { ingredient in
            IngredientFormView(ingredient: ingredient)
        }
        .sheet(isPresented: $isAdding) {
            IngredientFormView(ingredient: CatalogIngredient(name: "", category: .other))
        }
        .sousSheetSizing(.page)
    }

    @ViewBuilder
    private func row(_ ingredient: CatalogIngredient) -> some View {
        let isOwn = catalog.isOwn(ingredient)
        let kcal = nutrition.nutritionCatalog
            .nutrition(forCanonicalName: ingredient.name)?
            .nutrition(for: .unspecified)?
            .kcal

        // A button rather than a tap gesture: the pointer changes over it,
        // the keyboard reaches it, and the Mac gets the click it expects.
        // Bundled entries open too — their name and category are read-only
        // there, but their spellings and nutrition can still be added to.
        Button {
            editing = ingredient
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ingredient.name)
                    if !ingredient.aliases.isEmpty {
                        Text(ingredient.aliases.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                // The gap this whole screen exists to close is a silent one:
                // no number here is what "contributes nothing" looks like.
                if let kcal {
                    Text("\(Int(kcal.rounded())) kcal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if isOwn {
                    // Says which entries the cook owns outright, as opposed
                    // to the bundled ones they can only add to.
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .swipeActions { deleteAction(ingredient, isOwn: isOwn) }
        // The same action again, because a swipe needs a trackpad to exist
        // at all and gives no sign that it is there.
        .contextMenu { deleteAction(ingredient, isOwn: isOwn) }
    }

    @ViewBuilder
    private func deleteAction(_ ingredient: CatalogIngredient, isOwn: Bool) -> some View {
        if isOwn {
            Button("Entfernen", systemImage: "trash", role: .destructive) {
                Task { await catalog.delete(ingredient) }
            }
        }
    }

    /// Matching ingredients, grouped by category in aisle order.
    private var groups: [(category: IngredientCategory, ingredients: [CatalogIngredient])] {
        let matches = searchText.isEmpty
            ? catalog.catalog.ingredients
            : catalog.catalog.suggestions(for: searchText, limit: 200)

        return Dictionary(grouping: matches, by: \.category)
            .map { (category: $0.key, ingredients: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.category.aisleOrder < $1.category.aisleOrder }
    }
}

/// Adds or edits one catalog entry.
///
/// Two shapes in one sheet, because what a cook may change depends on where
/// the entry came from. Their own entries are theirs outright. A bundled one
/// is replaced whenever the app updates, so its name, category and shipped
/// spellings are shown read-only and everything they add to it — further
/// spellings, nutrition — is stored beside it as an override instead.
struct IngredientFormView: View {
    @Environment(IngredientCatalogLibrary.self) private var catalog
    @Environment(NutritionLibrary.self) private var nutrition
    @Environment(ShoppingLibrary.self) private var shopping
    @Environment(\.dismiss) private var dismiss

    private let original: CatalogIngredient
    /// Opened straight from the basis picker's "Eigene Werte": the cook has
    /// already said they want to type numbers, so the bundled read-only view
    /// would be one tap in the way.
    private let startsOnOwnValues: Bool

    @State private var name: String
    @State private var aliasText: String
    @State private var category: IngredientCategory
    /// The one further spelling being typed for a bundled entry.
    @State private var newAlias = ""
    @State private var nutritionDraft: NutritionDraft
    /// The pantry flag as shown, and as it was when the form opened — only
    /// a change is written back.
    @State private var isPantry = false
    @State private var storedPantry = false
    /// Where this ingredient is bought and what to know at the shelf, as
    /// shown and as loaded — like the pantry flag, only a change writes.
    @State private var storeDraft = ""
    @State private var noteDraft = ""
    @State private var storedStore = ""
    @State private var storedNote = ""
    /// Set once the cook asks to enter their own numbers over shipped ones.
    @State private var isEnteringOwnValues = false
    /// The ingredient this one is filed as a variety of — proposed for a new
    /// name by the word-ending heuristic, and editable afterwards.
    @State private var parentName: String?
    /// The proposal, kept apart from `parentName` so that dismissing it is
    /// remembered for as long as the form is open. Decision B: asked once,
    /// in passing, at the moment the ingredient comes into being.
    @State private var variantProposal: CatalogIngredient?
    /// Whether the parent picker is up — the way to the relation that does
    /// not depend on the heuristic having guessed right at creation time.
    @State private var isPickingParent = false
    /// The measure fields the cook has touched, by unit symbol. Only what is
    /// in here is written back on save — an untouched field shows what the
    /// app currently believes and must not turn that into a correction just
    /// because the form was opened.
    @State private var measureDraft: [String: String] = [:]
    /// The answer this form will write for the state on screen, and the one
    /// it found there.
    ///
    /// Part of the draft rather than written on the tap, because a new
    /// ingredient has no entry to write a basis onto until it is saved —
    /// which is the whole reason this used to be a second trip through a
    /// recipe. Only a *change* is written: opening a form must never turn a
    /// proposal the app made into a confirmation the cook did not.
    @State private var basisChoice: BasisChoice = .unset
    @State private var storedBasisChoice: BasisChoice = .unset
    /// The free search over the catalog, beside the proposals.
    @State private var basisQuery = ""
    /// Whether the row list is unfolded. Kept apart from the choice itself:
    /// tapping "Zeile im Lebensmittelkatalog" with nothing picked yet has to
    /// open the list, not answer the question with a row nobody chose.
    @State private var isChoosingRow = false

    init(ingredient: CatalogIngredient, startsOnOwnValues: Bool = false) {
        original = ingredient
        self.startsOnOwnValues = startsOnOwnValues
        _name = State(initialValue: ingredient.name)
        _aliasText = State(initialValue: ingredient.aliases.joined(separator: ", "))
        _category = State(initialValue: ingredient.category)
        _nutritionDraft = State(initialValue: NutritionDraft())
        _parentName = State(initialValue: ingredient.parentName)
        _isEnteringOwnValues = State(initialValue: startsOnOwnValues)
    }

    /// Whether this entry is coming into being — the empty form, or a name
    /// the catalog does not know yet.
    ///
    /// The second case is what "Neue Zutat" hands in for an unknown
    /// ingredient: the name as the cook wrote it in a recipe, wrapped in a
    /// `CatalogIngredient` that exists nowhere else. Counting only the empty
    /// name as new made the form tell them that word belonged to the app's
    /// own stock, and locked the two fields they had opened it to fill in.
    private var isNew: Bool {
        original.name.isEmpty || catalog.catalog.ingredient(for: original.name) == nil
    }

    /// Whether this entry is the cook's own — a new one counts, since saving
    /// it is what makes it theirs.
    private var isOwnEntry: Bool {
        isNew || catalog.isOwn(original)
    }

    /// What the app currently knows about this ingredient's nutrition, if
    /// anything — bundled or overridden, whichever wins.
    private var resolvedNutrition: CatalogNutrition? {
        guard !trimmedName.isEmpty else { return nil }
        return nutrition.nutritionCatalog.nutrition(forCanonicalName: trimmedName)
    }

    /// What a mapping of this ingredient used to rest on, where a data update
    /// has taken that row away — the name the mapping remembered, which is
    /// the only thing left to identify what has to be decided again.
    private var orphanedBasisName: String? {
        guard !trimmedName.isEmpty else { return nil }
        return nutrition.orphanedCatalogNames(forName: trimmedName).first
    }

    /// The cook's own numbers for it, which are the editable ones.
    private var ownNutrition: CatalogNutrition? {
        guard !trimmedName.isEmpty else { return nil }
        return nutrition.ownNutrition(forCanonicalName: trimmedName)
    }

    /// Bundled values are shown rather than offered for editing: correcting
    /// BLS belongs in a pull request against the data, not in one cook's
    /// device. But own values are one of the three answers to "what is this
    /// based on", so the read-only view is a default, not a wall — asking to
    /// type numbers over shipped ones opens the form.
    private var isNutritionEditable: Bool {
        isEnteringOwnValues || resolvedNutrition?.hasBases != true || ownNutrition != nil
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        NavigationStack {
            Form {
                if isOwnEntry {
                    ownIdentitySection
                    ownAliasSection
                } else {
                    bundledIdentitySection
                    bundledAliasSection
                }
                variantSection
                pantrySection
                shoppingSection
                basisSection
                nutritionSection
                measuresSection
            }
            .formStyle(.grouped)
            .sheet(isPresented: $isPickingParent) {
                // Into the draft, not the store: the form writes on save, and
                // a parent chosen for a name that does not exist yet has no
                // entry to be written onto until then.
                IngredientParentPickerView(ingredientName: trimmedName) { parent in
                    parentName = parent.name
                    variantProposal = nil
                }
            }
            .navigationTitle(isNew ? "Neue Zutat" : name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { save() }
                        .disabled(trimmedName.isEmpty)
                }
            }
            // The draft is filled after the load, not on appear: what the
            // cook already entered is not known until the store has answered.
            .task {
                // Before anything reads the catalog: which shape this form
                // takes depends on whether it knows the name.
                await catalog.ensureLoaded()
                await nutrition.reload()
                nutritionDraft = NutritionDraft(ownNutrition)
                loadBasisChoice()
                // Opened from the picker's "Eigene Werte": the answer was
                // given on the way in, and the form should show it as given
                // rather than make the cook say it a second time.
                if startsOnOwnValues { basisChoice = .ownValues }
                await shopping.ensurePantryLoaded()
                storedPantry = shopping.pantryKeys.contains(pantryKey)
                isPantry = storedPantry
                let entry = catalog.entry(for: pantryName)
                storedStore = entry?.preferredStore ?? ""
                storedNote = entry?.shoppingNote ?? ""
                storeDraft = storedStore
                noteDraft = storedNote
                proposeVariantIfNew()
            }
            // Retyping the name is still "coming into being": the proposal
            // follows what is being written until the entry is saved.
            .onChange(of: trimmedName) { proposeVariantIfNew() }
            // Each state carries its own answer, so switching which one is on
            // screen switches the question too.
            .onChange(of: shownState) { loadBasisChoice() }
        }
        .sousSheetSizing(.form)
    }

    // MARK: - The cook's own entries

    private var ownIdentitySection: some View {
        Section {
            TextField("Name", text: $name)
            Picker("Kategorie", selection: $category) {
                ForEach(IngredientCategory.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
        } footer: {
            Text("Die Kategorie bestimmt, in welcher Abteilung die Zutat auf der Einkaufsliste steht.")
        }
    }

    private var ownAliasSection: some View {
        Section {
            TextField("Tomaten, Cocktailtomaten", text: $aliasText, axis: .vertical)
                .lineLimit(1...3)
        } header: {
            Text("Andere Schreibweisen")
        } footer: {
            Text("Mit Komma getrennt. Rezepte, die eine davon nennen, zählen zur selben Zutat.")
        }
    }

    // MARK: - Pantry

    /// The name the pantry flag is filed under — the catalog's, so the flag
    /// and the list agree about which ingredient is meant.
    private var pantryName: String {
        catalog.catalog.canonicalName(for: trimmedName)
    }

    private var pantryKey: String {
        IngredientCatalog.normalize(pantryName)
    }

    private var pantrySection: some View {
        Section {
            Toggle("Vorrat", isOn: $isPantry)
        } footer: {
            Text("Vorräte stehen auf der Einkaufsliste eingeklappt am Ende — zum Durchsehen am Regal statt zwischen den Besorgungen.")
        }
    }

    private var shoppingSection: some View {
        Section {
            TextField("Supermarkt, z. B. Lidl", text: $storeDraft)
            TextField("Notiz, z. B. die feste Sorte", text: $noteDraft)
        } header: {
            Text("Einkauf")
        } footer: {
            Text("Mit Supermarkt steht die Zutat auf der Einkaufsliste als eigene Besorgung. Auf der Stamm-Zutat gesetzt gilt beides auch für ihre Sorten.")
        }
    }

    // MARK: - Varieties

    /// What this ingredient is a variety of, and what is a variety of it.
    ///
    /// The proposal at the top appears only while the ingredient is coming
    /// into being, and only when the word ends in another one — decision B's
    /// single, casual moment. The button under it is what used to be missing:
    /// the relation was acceptable and releasable, never *choosable*, so a
    /// declined proposal was the end of the matter. Now the section is always
    /// here, and a parent can be set or changed whenever the ingredient is
    /// open (catalog target, decision A and §1).
    @ViewBuilder
    private var variantSection: some View {
        let children = trimmedName.isEmpty ? [] : catalog.catalog.variants(of: pantryName)
        if !trimmedName.isEmpty {
            Section {
                if let proposal = variantProposal, parentName == nil {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Als Sorte von \(proposal.name) führen?")
                        Spacer(minLength: 8)
                        Button("Ja") {
                            parentName = proposal.name
                            variantProposal = nil
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Nein") { variantProposal = nil }
                    }
                    .controlSize(.small)
                }
                if let parentName {
                    HStack {
                        LabeledContent("Sorte von", value: parentLineage(from: parentName))
                        Spacer(minLength: 8)
                        Button("Lösen", systemImage: "minus.circle", role: .destructive) {
                            self.parentName = nil
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Sorten-Zuordnung lösen")
                    }
                }
                Button(
                    parentName == nil ? "Als Sorte einordnen" : "Andere Stamm-Zutat wählen",
                    systemImage: "arrow.triangle.branch"
                ) {
                    isPickingParent = true
                }
                ForEach(children) { child in
                    LabeledContent("Sorte", value: child.name)
                }
            } header: {
                Text("Sorten")
            } footer: {
                Text("Eine Sorte erbt Nährwerte und Maße ihrer Stamm-Zutat, solange sie keine eigenen hat — als Vorschlag, den du einmal bestätigst. Auf der Einkaufsliste steht sie als eigene Zeile. Rezepte mit einer Sorte finden sich auch unter der Stamm-Zutat.")
            }
        }
    }

    /// "Champignon → Pilz" where the chosen parent is itself a variety: the
    /// chain may be any depth, and the row should say where it leads.
    private func parentLineage(from parentName: String) -> String {
        ([parentName] + catalog.catalog.ancestors(of: parentName).map(\.name))
            .joined(separator: " → ")
    }

    // MARK: - Bundled entries

    private var bundledIdentitySection: some View {
        Section {
            LabeledContent("Name", value: original.name)
            LabeledContent("Kategorie", value: original.category.title)
        } footer: {
            Text("Diese Zutat gehört zum Bestand der App. Name und Kategorie werden bei jedem Update erneuert — Schreibweisen und Nährwerte, die du ergänzt, bleiben erhalten.")
        }
    }

    /// The shipped spellings, then the cook's own ones, then a field to add
    /// another. Additive rather than one comma-separated field: replacing the
    /// whole list is fine for an entry the cook owns and wrong for one that
    /// arrives with the app.
    private var bundledAliasSection: some View {
        let own = catalog.ownAliases(of: original)
        let shipped = original.aliases.filter { alias in
            !own.contains { IngredientCatalog.normalize($0) == IngredientCatalog.normalize(alias) }
        }

        return Section {
            if !shipped.isEmpty {
                Text(shipped.joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
            ForEach(own, id: \.self) { alias in
                HStack {
                    Text(alias)
                    Spacer()
                    Button("Entfernen", systemImage: "minus.circle", role: .destructive) {
                        Task { await catalog.removeAlias(alias, from: original) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Schreibweise entfernen")
                }
            }
            HStack {
                TextField("Weitere Schreibweise hinzufügen", text: $newAlias)
                    .onSubmit { addAlias() }
                Button("Hinzufügen", systemImage: "plus.circle.fill", action: addAlias)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(newAlias.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Schreibweise hinzufügen")
            }
        } header: {
            Text("Andere Schreibweisen")
        } footer: {
            Text("Rezepte, die eine davon nennen, zählen zu dieser Zutat — und übernehmen damit auch ihre Nährwerte.")
        }
    }

    private func addAlias() {
        let alias = newAlias.trimmingCharacters(in: .whitespaces)
        guard !alias.isEmpty else { return }
        newAlias = ""
        Task { await catalog.addAlias(alias, to: original) }
    }

    // MARK: - Nutrition

    /// Which of an entry's state variants is on screen. BLS lists many foods
    /// raw and cooked separately — very different water content, so very
    /// different numbers — and showing one of them silently would put a
    /// figure on screen without saying what it is a figure for.
    ///
    /// Read through a binding rather than initialized on appear: what is
    /// available only becomes known once the nutrition data is loaded, which
    /// happens after the view is first built.
    @State private var shownState: IngredientState?

    private var availableStates: [IngredientState] {
        guard let resolved = resolvedNutrition else { return [] }
        return IngredientState.displayOrder.filter { resolved.perHundredGrams[$0.rawValue] != nil }
    }

    private var selectedState: Binding<IngredientState> {
        Binding(
            get: { shownState ?? availableStates.first ?? .unspecified },
            set: { shownState = $0 }
        )
    }

    private func values(of entry: CatalogNutrition) -> NutritionInfo {
        entry.perHundredGrams[selectedState.wrappedValue.rawValue]
            ?? entry.nutrition(for: .unspecified)
            ?? .zero
    }

    @ViewBuilder
    private var nutritionSection: some View {
        if let resolved = resolvedNutrition, !isNutritionEditable {
            bundledNutritionSection(resolved)
            micronutrientSection(resolved)
        } else {
            editableNutritionSection
        }
    }

    // MARK: - Measures

    /// What a piece, a spoon or a cup of this ingredient weighs — the gram
    /// bridge, per ingredient, and editable no matter where the nutrition
    /// numbers come from.
    ///
    /// It used to sit inside the own-values form, which meant a bundled
    /// ingredient had no piece weight to correct until the cook typed a whole
    /// nutrition label over it. That is two unrelated decisions welded
    /// together: what an onion weighs is not a claim about its calories, and
    /// the concept asks for exactly this one on its own ("the cook can
    /// override any value on their ingredient — 'my onions are bigger'").
    ///
    /// Any unit, not only `Stk.`: the storage was always keyed by unit
    /// symbol. Mass and the litre stay out — a gram weighs a gram, and a
    /// millilitre is what the density answers.
    private static let measurableUnits: [IngredientUnit] = [
        .piece, .clove, .bunch, .leaf, .package, .pinch, .cup, .teaspoon, .tablespoon,
        .can, .jar, .stalk, .sprig, .stem, .centimeter,
    ]

    /// The units worth showing: everything anybody has a weight for, plus
    /// whatever the cook is in the middle of typing one for.
    private var shownMeasureUnits: [IngredientUnit] {
        let known = resolvedNutrition?.unitWeightsGrams ?? [:]
        return Self.measurableUnits.filter {
            known[$0.symbol] != nil || measureDraft[$0.symbol] != nil
        }
    }

    private var addableMeasureUnits: [IngredientUnit] {
        let shown = Set(shownMeasureUnits.map(\.symbol))
        return Self.measurableUnits.filter { !shown.contains($0.symbol) }
    }

    @ViewBuilder
    private var measuresSection: some View {
        if !trimmedName.isEmpty {
            Section {
                ForEach(shownMeasureUnits, id: \.symbol) { unit in
                    measureField(for: unit)
                }
                if !addableMeasureUnits.isEmpty {
                    Menu("Maß hinzufügen") {
                        ForEach(addableMeasureUnits, id: \.symbol) { unit in
                            Button(unit.symbol) { measureDraft[unit.symbol] = "" }
                        }
                    }
                }
                if let density = resolvedNutrition?.densityGramsPerMl {
                    LabeledContent("1 ml wiegt", value: mass(density))
                }
            } header: {
                Text("Maße")
            } footer: {
                Text("Angenommene Werte, keine gemessenen. Was du hier änderst, gilt für jedes Rezept mit dieser Zutat — und schlägt für diese Einheit auch die Dichte.")
            }
        }
    }

    private func measureField(for unit: IngredientUnit) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("1 \(unit.symbol) wiegt")
                if let parent = inheritedMeasureSource(for: unit) {
                    Text("von \(parent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            TextField(
                "g",
                text: Binding(
                    get: { measureDraft[unit.symbol] ?? initialMeasureText(for: unit) },
                    set: { measureDraft[unit.symbol] = $0 }
                )
            )
            .frame(maxWidth: 70)
            .multilineTextAlignment(.trailing)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            Text("g").foregroundStyle(.secondary)
        }
    }

    private func initialMeasureText(for unit: IngredientUnit) -> String {
        guard let grams = resolvedNutrition?.unitWeightsGrams[unit.symbol] else { return "" }
        return DecimalText.text(grams)
    }

    /// The label a packet would carry, in the order it carries it.
    ///
    /// Every secondary figure is shown only when it is above zero: in a table
    /// this size an unmeasured nutrient and a measured zero are stored the
    /// same way, and "davon Zucker: 0 g" next to real numbers would claim a
    /// precision the data does not have.
    @ViewBuilder
    private func bundledNutritionSection(_ entry: CatalogNutrition) -> some View {
        let states = availableStates
        let values = values(of: entry)
        Section {
            if states.count > 1 {
                Picker("Zustand", selection: selectedState) {
                    ForEach(states, id: \.self) { state in
                        Text(state.title).tag(state)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            nutrientRow("Energie", Self.nutrients.string(kilocalories: values.kcal), emphasized: true)
            nutrientRow("Fett", mass(values.fatG))
            measuredRow("davon gesättigte Fettsäuren", values.saturatedFatG, indented: true)
            nutrientRow("Kohlenhydrate", mass(values.carbsG))
            measuredRow("davon Zucker", values.sugarG, indented: true)
            measuredRow("Ballaststoffe", values.fiberG)
            nutrientRow("Eiweiß", mass(values.proteinG))
            // BLS reports sodium; the standard EU label shows salt, in grams
            // — which the formatter drops to milligrams where it has to.
            measuredRow("Salz", values.sodiumMg * 2.5 / 1000)
        } header: {
            Text("Nährwerte je 100 g")
        } footer: {
            // What the numbers rest on, in two lines that answer different
            // questions: which row of the catalog these values are, and whose
            // catalog it is. The kitchen word is almost never the source's
            // word — "Kartoffel" is "Kartoffel geschält, gekocht" there — and
            // until now the app showed the values without ever saying so.
            VStack(alignment: .leading, spacing: 2) {
                if let basis = entry.basis(for: selectedState.wrappedValue) {
                    if let catalogName = basis.catalogName {
                        Text("beruht auf: \(catalogName) — \(basis.status.label)")
                    } else {
                        Text(basis.status.label)
                    }
                }
                // The entry's own string, never a label hardcoded here — the
                // day a second source joins BLS, this line has to keep
                // telling the truth without anyone remembering to come back.
                Text("Quelle: \(entry.source)")
            }
        }
    }

    @ViewBuilder
    private func micronutrientSection(_ entry: CatalogNutrition) -> some View {
        let rows = micronutrientRows(values(of: entry))
        if !rows.isEmpty {
            Section("Vitamine & Mineralstoffe") {
                ForEach(rows, id: \.label) { row in
                    nutrientRow(row.label, row.value)
                }
            }
        }
    }

    /// Only what the source actually had a value for. A stored zero and
    /// "was never measured" are the same thing in a table this size, so a
    /// zero is left off rather than claiming a precision the data lacks —
    /// but anything above zero is shown, however small, because the
    /// formatter can always find a unit that fits it.
    private func micronutrientRows(_ info: NutritionInfo) -> [(label: String, value: String)] {
        let candidates: [(String, Double, NutrientFormatter.MassUnit)] = [
            ("Vitamin A", info.vitaminAMcg, .micrograms),
            ("Vitamin C", info.vitaminCMg, .milligrams),
            ("Vitamin D", info.vitaminDMcg, .micrograms),
            ("Vitamin E", info.vitaminEMg, .milligrams),
            ("Calcium", info.calciumMg, .milligrams),
            ("Eisen", info.ironMg, .milligrams),
            ("Magnesium", info.magnesiumMg, .milligrams),
            ("Kalium", info.potassiumMg, .milligrams),
        ]
        return candidates
            .filter { $0.1 > 0 }
            .map { (label: $0.0, value: Self.nutrients.string($0.1, in: $0.2)) }
    }

    /// A row for a figure the source has a value for — see the note above.
    @ViewBuilder
    private func measuredRow(_ label: String, _ grams: Double, indented: Bool = false) -> some View {
        if grams > 0 {
            nutrientRow(label, mass(grams), indented: indented)
        }
    }

    private func nutrientRow(
        _ label: String, _ value: String, indented: Bool = false, emphasized: Bool = false
    ) -> some View {
        LabeledContent {
            Text(value)
                .fontWeight(emphasized ? .semibold : .regular)
                .monospacedDigit()
        } label: {
            Text(label)
                .padding(.leading, indented ? 14 : 0)
                .foregroundStyle(indented ? .secondary : .primary)
        }
    }

    private static let nutrients = NutrientFormatter(locale: .sous)

    private func mass(_ grams: Double) -> String {
        Self.nutrients.string(grams, in: .grams)
    }

    /// The same figures the read-only view shows, as far as a person can
    /// reasonably be asked to type them: everything a packet prints, and
    /// nothing below it. Vitamins and minerals stay out — sixteen fields
    /// would get one filled in.
    private var editableNutritionSection: some View {
        Section {
            numberField("Energie (kcal)", text: $nutritionDraft.kcal)
            numberField("Fett (g)", text: $nutritionDraft.fat)
            numberField("davon gesättigte Fettsäuren (g)", text: $nutritionDraft.saturatedFat, indented: true)
            numberField("Kohlenhydrate (g)", text: $nutritionDraft.carbs)
            numberField("davon Zucker (g)", text: $nutritionDraft.sugar, indented: true)
            numberField("Ballaststoffe (g)", text: $nutritionDraft.fiber)
            numberField("Eiweiß (g)", text: $nutritionDraft.protein)
            numberField("Salz (g)", text: $nutritionDraft.salt)

            HStack {
                Text("Quelle")
                Spacer(minLength: 8)
                // Labelled like the rows above it: prefilled with "Eigene
                // Angabe", the placeholder never shows, so without a label
                // the field reads as a stray value.
                TextField("Eigene Angabe", text: $nutritionDraft.source)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
            }

            if ownNutrition != nil {
                Button("Nährwerte entfernen", role: .destructive) {
                    Task {
                        await nutrition.deleteIngredientNutrition(name: trimmedName)
                        nutritionDraft = NutritionDraft()
                    }
                }
            }
        } header: {
            Text("Nährwerte je 100 g")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ohne Nährwerte zählt diese Zutat in keinem Rezept mit. Energie und die vier Hauptwerte reichen — alles Weitere ist freiwillig. Oder mach die Zutat zur Schreibweise einer Zutat, die die App schon kennt.")
                // Two questions wear the same stamp, and they are not the
                // same question. The re-key's: these numbers hang on a name
                // that matches no row, so a data update cannot follow them.
                // Phase 6's: the row they *did* hang on is gone from the
                // shipped data. Only the second one can name what was lost,
                // and telling a cook their word "was never in the catalog"
                // when it was there until the last update would be false.
                if let was = orphanedBasisName {
                    Text("Die zugeordnete Zeile „\(was)“ ist in den aktuellen Daten nicht mehr enthalten. Bitte unten neu zuordnen.")
                }
            }
        }
    }

    // MARK: - Grundlage

    /// The one question the numbers hang on: what do they rest on.
    ///
    /// Three answers that exclude one another — a row of the food table, the
    /// cook's own numbers, or the decision to have neither. The model has
    /// said so since phase 4; the form used to lay two of them out as
    /// separate sections with the exclusivity hidden in a footnote, and keep
    /// the third only in the recipe. Worse, the row picker appeared only
    /// while `isNutritionEditable` — that is, only for ingredients that had
    /// no values yet — so an ingredient whose numbers were fine and whose row
    /// was wrong could not be corrected here at all.
    ///
    /// Asked for the state on screen, because that is what a row answers:
    /// picking one says what a *cooked* potato is. Own values stay a
    /// statement about the ingredient — see `save()` — and that asymmetry is
    /// deliberate, not an oversight.
    ///
    /// Written on save, not on the tap, because a new ingredient has no entry
    /// to carry a basis until it has one.
    ///
    /// Exclusive on purpose, and decided so on review: a catalog row is *not*
    /// kept beside own values as a note of what they stand for, although
    /// `BasisAssignment` could hold both. A subordinate choice under one of
    /// three answers turns them back into the two questions this section
    /// exists to replace — and the doubt it answers was the cook's own, about
    /// having values *and* a reference at once.
    @ViewBuilder
    private var basisSection: some View {
        if !trimmedName.isEmpty {
            Section {
                basisAnswer(
                    title: "Zeile im Lebensmittelkatalog",
                    detail: chosenRowName,
                    isChosen: chosenRowCode != nil
                ) { chooseCatalogRow() }
                if chosenRowCode != nil || isChoosingRow {
                    basisRowList
                }
                basisAnswer(
                    title: "Eigene Werte",
                    detail: nil,
                    isChosen: basisChoice == .ownValues,
                    action: chooseOwnValues
                )
                basisAnswer(
                    title: "Bewusst ohne Nährwerte",
                    detail: nil,
                    isChosen: basisChoice == .deliberatelyWithout
                ) { choose(.deliberatelyWithout) }
            } header: {
                Text(availableStates.count > 1
                    ? "Grundlage (\(selectedState.wrappedValue.title.lowercased()))"
                    : "Grundlage")
            } footer: {
                Text(basisFooter)
            }
        }
    }

    /// One of the three answers, as a row that can also be tapped a second
    /// time to take it back. With no other way to unpick one, a mis-tap would
    /// otherwise be permanent.
    private func basisAnswer(
        title: String, detail: String?, isChosen: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isChosen ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// The rows to choose between: the proposals for this name, or whatever
    /// the cook is searching for. Typing replaces the list rather than adding
    /// a second one beneath it.
    @ViewBuilder
    private var basisRowList: some View {
        let query = basisQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = query.isEmpty
            ? nutrition.candidates(forName: trimmedName)
            : nutrition.search(query)
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Im Lebensmittelkatalog suchen", text: $basisQuery)
                .autocorrectionDisabled()
        }
        if rows.isEmpty {
            Text(emptyRowListNote(query: query))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            ForEach(rows) { row in
                Button {
                    chooseRow(row.code)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: chosenRowCode == row.code
                            ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(.tint)
                            .padding(.leading, 14)
                        Text(row.name)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text("\(Int(row.perHundredGrams.kcal.rounded())) kcal")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func emptyRowListNote(query: String) -> String {
        if query.isEmpty {
            return "Zu diesem Namen schlägt der Katalog nichts vor. Such von Hand — die Küche und der Katalog nennen dieselbe Sache selten gleich."
        }
        return query.count < 3 ? "Noch ein Buchstabe." : "Keine Zeile gefunden."
    }

    private var basisFooter: String {
        switch basisChoice {
        case .catalogRow:
            "Die Werte dieser Zeile zählen für jedes Rezept mit dieser Zutat."
        case .ownValues:
            "Deine Zahlen zählen — in jedem Rezept mit dieser Zutat und in jedem Zustand."
        case .deliberatelyWithout:
            "Diese Zutat zählt bewusst in keiner Summe mit und fragt nicht mehr nach."
        case .unset:
            "Ohne Grundlage lässt jede Summe diese Zutat aus und nennt sie als Lücke."
        }
    }

    // MARK: - Grundlage, the answering

    private var chosenRowCode: String? {
        if case .catalogRow(let code) = basisChoice { return code }
        return nil
    }

    /// The chosen row's name — and, while the row on screen is still the one
    /// that came down the chain unchanged, whose it is and that it is only
    /// proposed. A variety shows its parent's row here until the cook picks;
    /// showing it without saying so is exactly how inherited numbers used to
    /// pass for the variety's own.
    private var chosenRowName: String? {
        guard let code = chosenRowCode else { return nil }
        let name = nutrition.row(forCode: code)?.name
        guard basisChoice == storedBasisChoice,
              let parent = resolvedNutrition?.inheritedFrom
        else { return name }
        return name.map { "\($0) — geerbt von \(parent), vorgeschlagen" }
    }

    /// Whether a measure on screen came down the chain rather than being
    /// this ingredient's own — the same honesty for grams that the basis
    /// row has for numbers. Compared against the entry as written, since the
    /// resolved one has already merged its ancestor's weights in.
    private func inheritedMeasureSource(for unit: IngredientUnit) -> String? {
        guard let parent = resolvedNutrition?.inheritedFrom,
              measureDraft[unit.symbol] == nil,
              nutrition.nutritionCatalog.ownEntry(forCanonicalName: trimmedName)?
                  .unitWeightsGrams[unit.symbol] == nil
        else { return nil }
        return parent
    }

    /// Reads the answer currently filed for the state on screen. Called again
    /// when that state changes, because each one carries its own answer.
    private func loadBasisChoice() {
        storedBasisChoice = filedBasisChoice()
        basisChoice = storedBasisChoice
        isChoosingRow = false
    }

    private func filedBasisChoice() -> BasisChoice {
        guard !trimmedName.isEmpty,
              let basis = nutrition.nutrition(forName: trimmedName)?
                  .basis(for: selectedState.wrappedValue)
        else { return .unset }
        if basis.status == .deliberatelyWithout { return .deliberatelyWithout }
        if ownNutrition != nil { return .ownValues }
        return basis.code.map(BasisChoice.catalogRow) ?? .unset
    }

    /// Picking an answer, or taking it back by picking it again.
    private func choose(_ choice: BasisChoice) {
        basisChoice = basisChoice == choice ? .unset : choice
        if basisChoice != .ownValues, !startsOnOwnValues {
            isEnteringOwnValues = false
        }
        if chosenRowCode == nil { isChoosingRow = false }
    }

    /// The catalog-row answer has no value until a row is picked, so tapping
    /// it opens the list rather than choosing anything.
    private func chooseCatalogRow() {
        if chosenRowCode != nil {
            basisChoice = .unset
            isChoosingRow = false
        } else {
            isChoosingRow.toggle()
        }
    }

    /// Picking a row, or unpicking it. The list stays open either way:
    /// taking one back is usually the first half of choosing a different one.
    private func chooseRow(_ code: String) {
        basisChoice = chosenRowCode == code ? .unset : .catalogRow(code)
        isChoosingRow = true
        if !startsOnOwnValues { isEnteringOwnValues = false }
    }

    /// Own values are chosen by saying so, and the fields appear at once —
    /// the answer and the place to type it are one thought.
    private func chooseOwnValues() {
        choose(.ownValues)
        if basisChoice == .ownValues { isEnteringOwnValues = true }
    }

    private func numberField(_ label: String, text: Binding<String>, indented: Bool = false) -> some View {
        HStack {
            Text(label)
                .padding(.leading, indented ? 14 : 0)
                .foregroundStyle(indented ? .secondary : .primary)
            Spacer(minLength: 8)
            TextField("—", text: text)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .frame(maxWidth: 90)
        }
    }

    // MARK: - Saving

    /// Decision B's one moment: only for a name that is coming into being,
    /// only once per spelling, and only ever as a question.
    private func proposeVariantIfNew() {
        guard isNew, parentName == nil else { return }
        variantProposal = VariantHeuristic.parent(for: trimmedName, in: catalog.catalog)
    }

    private func save() {
        let ingredient = CatalogIngredient(
            name: trimmedName,
            aliases: aliasText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            category: category,
            parentName: parentName
        )
        let isOwn = isOwnEntry
        let editable = isNutritionEditable
        let draft = nutritionDraft
        let entered = draft.catalogNutrition(named: trimmedName)
        let measures = measureDraft.compactMapValues { text -> Double?? in
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            // An emptied field takes the correction back; a field with
            // something unreadable in it is left alone.
            if trimmed.isEmpty { return .some(nil) }
            return DecimalText.number(trimmed).map { .some($0) }
        }
        let basis = basisChoice
        let storedBasis = storedBasisChoice
        let hadOwnValues = ownNutrition != nil
        let basisState = selectedState.wrappedValue
        let measureTarget = pantryName
        let pantryChanged = isPantry != storedPantry
        let pantryFlagged = isPantry
        let pantryTarget = pantryName
        let shoppingChanged = storeDraft != storedStore || noteDraft != storedNote
        let storeEntered = storeDraft
        let noteEntered = noteDraft

        let parent = parentName
        let wasParented = original.parentName
        Task {
            if isOwn {
                await catalog.save(ingredient)
            } else if parent != wasParented {
                // A shipped ingredient the cook filed under another one:
                // everything else about it stays the app's.
                await catalog.setParent(parent, of: trimmedName)
            }
            if basis == .ownValues, editable {
                if let entered {
                    await nutrition.saveIngredientNutrition(entered)
                } else if hadOwnValues {
                    // Everything cleared out reads as taking the entry back.
                    await nutrition.deleteIngredientNutrition(name: trimmedName)
                }
            } else if storedBasis == .ownValues, hadOwnValues {
                // Moving off own values takes the numbers with it. They win
                // over a code at read time, so leaving them behind would mean
                // picking a row and watching nothing change.
                await nutrition.deleteIngredientNutrition(name: trimmedName)
            }
            // After the numbers, never before: `confirmBasis` carries own
            // values across, so it has to see the ones just entered.
            if basis != storedBasis {
                switch basis {
                case .catalogRow(let code):
                    await nutrition.confirmBasis(
                        code: code, state: basisState, forName: trimmedName
                    )
                case .deliberatelyWithout:
                    await nutrition.setDeliberatelyWithoutBasis(
                        forName: trimmedName, state: basisState
                    )
                case .unset:
                    await nutrition.clearBasis(forName: trimmedName, state: basisState)
                case .ownValues:
                    // The numbers written above are the answer; there is no
                    // second thing to record.
                    break
                }
            }
            for (symbol, grams) in measures {
                await nutrition.setUnitWeight(
                    grams, unit: IngredientUnit(symbol: symbol), forName: measureTarget
                )
            }
            if pantryChanged {
                await shopping.setPantry(pantryFlagged, name: pantryTarget)
            }
            if shoppingChanged {
                // Through the catalog library, not the shopping one: the
                // share extension shows this form without a ShoppingLibrary
                // in its environment.
                await catalog.setShoppingPreferences(
                    store: storeEntered, note: noteEntered, name: pantryTarget
                )
            }
            dismiss()
        }
    }
}

/// What an ingredient's numbers rest on, as one question with three answers.
///
/// The shape `BasisAssignment` has had since phase 4, in the form's own
/// terms: a row of the food table, the cook's own numbers, or the decision to
/// have neither — plus the state of never having said. They exclude one
/// another, which is exactly what two stacked form sections could not show.
private enum BasisChoice: Equatable {
    /// Nothing said yet. A named gap in every sum that uses the ingredient.
    case unset
    case catalogRow(String)
    case ownValues
    case deliberatelyWithout
}

/// The nutrition form's fields as typed, before they mean anything.
///
/// Text rather than numbers so an empty field stays empty instead of showing
/// a 0 nobody entered — "not filled in" and "measured as zero" are different
/// things, and only the first should leave the ingredient uncounted.
private struct NutritionDraft {
    var kcal = ""
    var protein = ""
    var fat = ""
    var saturatedFat = ""
    var carbs = ""
    var sugar = ""
    var fiber = ""
    /// Salt, not sodium: it is what a packet prints, and what the read-only
    /// view shows. Converted on the way in and out — BLS stores sodium.
    var salt = ""
    var source = CatalogNutrition.ownSource

    /// Milligrams of sodium per gram of salt.
    private static let sodiumMgPerSaltGram = 400.0

    init() {}

    init(_ existing: CatalogNutrition?) {
        guard let existing else { return }
        let values = existing.nutrition(for: .unspecified) ?? .zero
        kcal = Self.text(values.kcal)
        protein = Self.text(values.proteinG)
        fat = Self.text(values.fatG)
        carbs = Self.text(values.carbsG)
        // Left blank rather than "0" when nothing was entered, so reopening
        // the form does not turn "did not say" into "said zero".
        saturatedFat = Self.optionalText(values.saturatedFatG)
        sugar = Self.optionalText(values.sugarG)
        fiber = Self.optionalText(values.fiberG)
        salt = Self.optionalText(values.sodiumMg / Self.sodiumMgPerSaltGram)
        source = existing.source
    }

    /// What was typed, as a catalog entry — or `nil` when the form is empty
    /// enough that there is nothing to record.
    func catalogNutrition(named name: String) -> CatalogNutrition? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let entered = [kcal, protein, fat, saturatedFat, carbs, sugar, fiber, salt].map(Self.number)
        guard entered.contains(where: { $0 != nil }) else { return nil }

        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return CatalogNutrition(
            name: name,
            perHundredGrams: [IngredientState.unspecified.rawValue: NutritionInfo(
                kcal: Self.number(kcal) ?? 0,
                proteinG: Self.number(protein) ?? 0,
                fatG: Self.number(fat) ?? 0,
                saturatedFatG: Self.number(saturatedFat) ?? 0,
                carbsG: Self.number(carbs) ?? 0,
                sugarG: Self.number(sugar) ?? 0,
                fiberG: Self.number(fiber) ?? 0,
                sodiumMg: (Self.number(salt) ?? 0) * Self.sodiumMgPerSaltGram,
                vitaminAMcg: 0, vitaminCMg: 0, vitaminDMcg: 0, vitaminEMg: 0,
                calciumMg: 0, ironMg: 0, magnesiumMg: 0, potassiumMg: 0
            )],
            densityGramsPerMl: nil,
            source: trimmedSource.isEmpty ? CatalogNutrition.ownSource : trimmedSource
        )
    }

    private static func number(_ text: String) -> Double? { DecimalText.number(text) }
    private static func text(_ value: Double) -> String { DecimalText.text(value) }
    /// Blank for zero — see the note in `init(_:)`.
    private static func optionalText(_ value: Double) -> String { DecimalText.optionalText(value) }
}
