import SousKit
import SwiftUI

/// The ingredient catalog: what the app knows.
///
/// To read, not to maintain (INGREDIENTS-DATA §3 A). The catalog comes with
/// the data set; what the household says lives beside it — a local answer
/// for a name the catalog cannot answer yet, and pantry, store and note.
struct IngredientCatalogView: View {
    @Environment(IngredientCatalogLibrary.self) private var catalog
    @Environment(NutritionLibrary.self) private var nutrition
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var showing: CatalogIngredient?
    @State private var isAddingProduct = false

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty {
                    CatalogNudgeCard()
                }
                if !ownProducts.isEmpty {
                    Section {
                        ForEach(ownProducts) { ingredient in
                            row(ingredient)
                        }
                    } header: {
                        Text("Eigene Produkte")
                            .sousGroupHeader()
                    }
                }
                ForEach(groups, id: \.category) { group in
                    Section {
                        ForEach(group.ingredients) { ingredient in
                            row(ingredient)
                        }
                    } header: {
                        Text(group.category.title)
                            .sousGroupHeader()
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
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Produkt hinzufügen", systemImage: "plus") { isAddingProduct = true }
                }
            }
            .overlay {
                if groups.isEmpty && ownProducts.isEmpty {
                    ContentUnavailableView.search
                }
            }
        }
        .task {
            await nutrition.ensureLoaded()
        }
        .sheet(item: $showing) { ingredient in
            IngredientDetailView(ingredient: ingredient)
        }
        .sheet(isPresented: $isAddingProduct) {
            LocalAnswerForm(newProduct: ())
        }
        .sousErrorAlert(catalog)
        .sousSheetSizing(.page)
    }

    @ViewBuilder
    private func row(_ ingredient: CatalogIngredient) -> some View {
        let kcal = nutrition.nutritionCatalog
            .nutrition(forCanonicalName: ingredient.name)?
            .nutrition(for: .unspecified)?
            .kcal

        // A button rather than a tap gesture: the pointer changes over it,
        // the keyboard reaches it, and the Mac gets the click it expects.
        Button {
            showing = ingredient
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
                if let kcal {
                    Text("\(Int(kcal.rounded())) kcal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if catalog.localTrace(for: ingredient.name)?.status == .applied {
                    // Where the household's own word stands over the
                    // catalog's.
                    Image(systemName: "house")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("lokal")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// The household's own products (phase 7b), on top and in no aisle —
    /// matching the search, where there is one.
    private var ownProducts: [CatalogIngredient] {
        let keys = Set(catalog.ownProducts.map(\.writtenKey))
        return matches.filter { keys.contains($0.key) }.sorted { $0.name < $1.name }
    }

    private var matches: [CatalogIngredient] {
        searchText.isEmpty
            ? catalog.catalog.ingredients
            : catalog.catalog.search(searchText, limit: 200, requiresEveryWord: true)
    }

    /// Matching ingredients, grouped by category in aisle order.
    private var groups: [(category: IngredientCategory, ingredients: [CatalogIngredient])] {
        let own = Set(catalog.ownProducts.map(\.writtenKey))
        return Dictionary(grouping: matches.filter { !own.contains($0.key) }, by: \.category)
            .map { (category: $0.key, ingredients: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.category.aisleOrder < $1.category.aisleOrder }
    }
}

/// One catalog word, read-only, with what the household says about it.
///
/// What the catalog says — name, spellings, what it is a variety of, the
/// basis and its source, the weights — is shown, not edited: a wrong answer
/// is a data fix for the curator, not a question for the cook (§3 A). What
/// the household says sits beside it:
/// - the local answer, marked "lokal", with "Lokale Angabe entfernen" (§3 B);
/// - pantry, preferred store and note, which are facts about the household,
///   not about the ingredient (§3 C).
struct IngredientDetailView: View {
    @Environment(IngredientCatalogLibrary.self) private var catalog
    @Environment(NutritionLibrary.self) private var nutrition
    @Environment(\.dismiss) private var dismiss

    let ingredient: CatalogIngredient

    /// The household fields as shown, and as they were loaded — only a change
    /// is written.
    @State private var isPantry = false
    @State private var storeDraft = ""
    @State private var noteDraft = ""
    @State private var storedStore = ""
    @State private var storedNote = ""
    @State private var hasLoaded = false
    /// Set while the local-answer form is open over this one.
    @State private var isEditingLocalAnswer = false
    @State private var isConfirmingRemoval = false
    /// Which of the entry's state variants is on screen — BLS lists many
    /// foods raw and cooked separately, and a figure must say which it is.
    @State private var shownState: IngredientState?

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                varietySection
                localAnswerSection
                householdSection
                nutritionSections
                measuresSection
            }
            .formStyle(.grouped)
            .navigationTitle(ingredient.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) {
                        Task {
                            await writeShopping()
                            dismiss()
                        }
                    }
                }
            }
            .sheet(isPresented: $isEditingLocalAnswer) {
                LocalAnswerForm(name: ingredient.name, existing: localAnswer)
            }
            .sousConfirmation(
                "Lokale Angabe entfernen?",
                isPresented: $isConfirmingRemoval,
                message: "Danach rechnet Sous für „\(ingredient.name)“ wieder mit dem, was der Katalog sagt."
            ) {
                if let localAnswer {
                    Button("Entfernen", role: .destructive) {
                        Task { await catalog.deleteLocalAnswer(localAnswer) }
                    }
                }
            }
            .task {
                await nutrition.ensureLoaded()
                let entry = catalog.householdIngredient(for: ingredient.name)
                isPantry = entry?.isPantry ?? false
                storedStore = entry?.preferredStore ?? ""
                storedNote = entry?.shoppingNote ?? ""
                storeDraft = storedStore
                noteDraft = storedNote
                hasLoaded = true
            }
            .sousErrorAlert(catalog)
        }
        .sousSheetSizing(.page)
    }

    // MARK: - What the catalog says

    private var identitySection: some View {
        Section {
            LabeledContent("Name", value: ingredient.name)
            LabeledContent("Kategorie", value: categoryText)
            if let product = ingredient.product {
                LabeledContent("Marke", value: product.brand)
                if !product.eans.isEmpty {
                    LabeledContent("EAN", value: product.eans.joined(separator: ", "))
                }
                if product.isDiscontinued {
                    LabeledContent("Handel", value: "nicht mehr erhältlich")
                }
            }
            if !ingredient.aliases.isEmpty {
                LabeledContent("Schreibweisen") {
                    Text(ingredient.aliases.joined(separator: ", "))
                        .multilineTextAlignment(.trailing)
                }
            }
        } footer: {
            Text("So steht die Zutat im Katalog. Fehlt eine Schreibweise oder stimmt etwas nicht, ist das eine Meldung an den Katalog wert.")
        }
    }

    /// "Gemüse — von Tomate" for a variety that takes its parent's aisle.
    private var categoryText: String {
        guard ingredient.ownCategory == nil, let parent = ingredient.parentName,
              let source = catalog.catalog.categorySource(for: parent)
        else { return ingredient.category.title }
        return "\(source.category.title) — von \(source.name)"
    }

    @ViewBuilder
    private var varietySection: some View {
        let ancestors = catalog.catalog.ancestors(of: ingredient.name)
        let children = catalog.catalog.ingredients
            .filter { $0.parentName.map(IngredientCatalog.normalize) == ingredient.key }
            .sorted { $0.name < $1.name }
        if !ancestors.isEmpty || !children.isEmpty {
            Section {
                if !ancestors.isEmpty {
                    LabeledContent("Sorte von", value: ancestors.map(\.name).joined(separator: " → "))
                }
                if !children.isEmpty {
                    LabeledContent("Sorten") {
                        Text(children.map(\.name).joined(separator: ", "))
                            .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text("Sorten")
            } footer: {
                Text("Eine Sorte rechnet mit Nährwerten und Maßen ihrer Stamm-Zutat, solange der Katalog ihr keine eigenen gibt. Auf der Einkaufsliste steht sie als eigene Zeile.")
            }
        }
    }

    // MARK: - What the household says

    private var localAnswer: LocalAnswer? {
        catalog.localAnswer(for: ingredient.name)
    }

    /// The household's local answer for this word, if one speaks — "lokal",
    /// with what it says, and quietly whether the catalog has since taken it
    /// over (§3 B, R3).
    private var localAnswerSection: some View {
        Section {
            if let trace = catalog.localTrace(for: ingredient.name) {
                Text(trace.label)
                    .foregroundStyle(.secondary)
                Button(trace.answer.isLocalProduct ? "Produkt bearbeiten …" : "Lokale Angabe bearbeiten …") {
                    isEditingLocalAnswer = true
                }
                Button("Lokale Angabe entfernen", role: .destructive) { isConfirmingRemoval = true }
            } else {
                Button("Lokale Angabe …") { isEditingLocalAnswer = true }
            }
        } header: {
            Text("Lokal")
        } footer: {
            Text("Eigene Werte von der Packung, eigene Gewichte oder ein Produkt – nur für diesen Haushalt, und sie gehen dem Katalog vor.")
        }
    }

    private var householdSection: some View {
        Section {
            Toggle("Vorrat", isOn: $isPantry)
                .onChange(of: isPantry) { _, flagged in
                    guard hasLoaded else { return }
                    Task { await catalog.setPantry(flagged, name: ingredient.name) }
                }
            TextField("Supermarkt, z. B. Lidl", text: $storeDraft)
                .onSubmit { Task { await writeShopping() } }
            TextField("Notiz, z. B. die feste Sorte", text: $noteDraft)
                .onSubmit { Task { await writeShopping() } }
        } header: {
            Text("Im Haushalt")
        } footer: {
            Text("Vorräte stehen auf der Einkaufsliste eingeklappt am Ende. Mit Supermarkt steht die Zutat als eigene Besorgung. Auf der Stamm-Zutat gesetzt gilt das auch für ihre Sorten.")
        }
    }

    /// Writes store and note if either changed — on return in a field and
    /// when the detail closes, so nothing typed is lost without a "Sichern".
    private func writeShopping() async {
        guard hasLoaded, storeDraft != storedStore || noteDraft != storedNote else { return }
        await catalog.setShoppingPreferences(store: storeDraft, note: noteDraft, name: ingredient.name)
        storedStore = storeDraft
        storedNote = noteDraft
    }

    // MARK: - Nutrition

    /// What the app computes with: the catalog's entry, with a local answer
    /// laid over it where one speaks.
    private var resolved: CatalogNutrition? {
        nutrition.nutrition(forName: ingredient.name)
    }

    /// The catalog's own entry, without the local answer — shown beside a
    /// local one (§3 B).
    private var catalogsOwn: CatalogNutrition? {
        NutritionCatalog.current.nutrition(forCanonicalName: ingredient.name)
    }

    private var localValuesApply: Bool {
        guard let trace = catalog.localTrace(for: ingredient.name), trace.status == .applied else { return false }
        return trace.answer.values != nil
    }

    private var availableStates: [IngredientState] {
        guard let resolved else { return [] }
        return IngredientState.displayOrder.filter { resolved.perHundredGrams[$0.rawValue] != nil }
    }

    private var selectedState: Binding<IngredientState> {
        Binding(
            get: { shownState ?? availableStates.first ?? .unspecified },
            set: { shownState = $0 }
        )
    }

    @ViewBuilder
    private var nutritionSections: some View {
        if let resolved, let basis = resolved.basis(for: selectedState.wrappedValue) {
            if basis.status == .deliberatelyWithout {
                Section {
                    Text(NutritionCoverage.GapReason.deliberatelyWithout.label)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Nährwerte")
                } footer: {
                    Text("Der Katalog führt diese Zutat bewusst ohne Werte – sie fehlt in keiner Summe.")
                }
            } else {
                valuesSection(resolved, basis: basis)
                micronutrientSection(basis.values)
            }
        } else {
            Section {
                Text(NutritionCoverage.GapReason.noNutritionValues.label)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Nährwerte")
            }
        }
    }

    /// The label a packet would carry, in the order it carries it. A
    /// secondary figure only when it is above zero: an unmeasured nutrient
    /// and a measured zero are stored the same way.
    private func valuesSection(_ entry: CatalogNutrition, basis: NutritionBasis) -> some View {
        let values = basis.values
        return Section {
            if availableStates.count > 1 {
                Picker("Zustand", selection: selectedState) {
                    ForEach(availableStates, id: \.self) { state in
                        Text(state.title).tag(state)
                    }
                }
            }
            nutrientRow(
                "Energie", values[.kcal].map { Self.nutrients.string(kilocalories: $0) } ?? Self.notStated,
                emphasized: true
            )
            statedRow("Fett", values, .fatG)
            statedRow("davon gesättigte Fettsäuren", values, .saturatedFatG, indented: true)
            statedRow("Kohlenhydrate", values, .carbsG)
            statedRow("davon Zucker", values, .sugarG, indented: true)
            statedRow("Ballaststoffe", values, .fiberG)
            statedRow("Eiweiß", values, .proteinG)
            // BLS reports sodium; the EU label shows salt.
            statedRow("Salz", values, .sodiumMg, gramsPerUnit: 2.5 / 1000)
        } header: {
            Text("Nährwerte")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Alle Werte je 100 g.")
                if localValuesApply {
                    Text("lokal: eigene Werte · Quelle: \(basis.source)")
                    if let own = catalogsOwn?.basis(for: selectedState.wrappedValue), own.status == .computed {
                        Text("Katalog: \(own.provenance ?? "\(Int(own.values.kcal.rounded())) kcal")")
                    }
                } else {
                    if let like = basis.estimatedLike {
                        Text("Schätzung wie \(like), bis die Packungswerte da sind")
                    }
                    if let inherited = basis.inheritedFrom {
                        Text("geerbt von \(inherited)")
                    }
                    if let catalogName = basis.catalogName {
                        Text("beruht auf: \(catalogName)")
                    }
                    Text("Quelle: \(basis.source)")
                }
            }
        }
    }

    @ViewBuilder
    private func micronutrientSection(_ info: NutritionInfo) -> some View {
        let rows = micronutrientRows(info)
        let absent = Self.micronutrients.filter { !info.states($0) }
        if !rows.isEmpty || !absent.isEmpty {
            Section {
                ForEach(rows, id: \.label) { row in
                    nutrientRow(row.label, row.value)
                }
            } header: {
                Text("Vitamine & Mineralstoffe")
            } footer: {
                // Absent, not zero: a label rarely states them, and a BLS
                // row sometimes leaves one out. Nothing is filled in.
                if !absent.isEmpty {
                    Text("Nicht angegeben: \(absent.map(\.label).joined(separator: ", "))")
                }
            }
        }
    }

    private static let micronutrients: [Nutrient] = [
        .vitaminAMcg, .vitaminCMg, .vitaminDMcg, .vitaminEMg,
        .calciumMg, .ironMg, .magnesiumMg, .potassiumMg,
    ]

    private static let notStated = "nicht angegeben"

    /// Only what the source had a value for — anything above zero, however
    /// small, since the formatter can always find a unit that fits it.
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

    // MARK: - Measures

    /// What a piece, a spoon or a cup of this ingredient weighs — the bridge
    /// to grams. A weight the household gave is marked "lokal".
    @ViewBuilder
    private var measuresSection: some View {
        let weights = resolved?.unitWeightsGrams ?? [:]
        let units = LocalAnswerForm.units.filter { weights[$0.symbol] != nil }
        let local = catalog.localTrace(for: ingredient.name)
            .flatMap { $0.status == .applied ? $0.answer.weights : nil } ?? [:]
        if !units.isEmpty || resolved?.densityGramsPerMl != nil {
            Section {
                ForEach(units, id: \.symbol) { unit in
                    LabeledContent {
                        Text(mass(weights[unit.symbol] ?? 0))
                            .monospacedDigit()
                    } label: {
                        HStack(spacing: 4) {
                            Text("1 \(unit.symbol)")
                            if let state = resolved?.unitStates[unit.symbol], state != .unspecified {
                                Text(state.title)
                                    .foregroundStyle(.secondary)
                            }
                            if local[unit.symbol] != nil {
                                Text("lokal")
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
                if let density = resolved?.densityGramsPerMl {
                    LabeledContent("1 ml wiegt", value: mass(density))
                }
            } header: {
                Text("Maße")
            } footer: {
                Text("Angenommene Werte, keine gemessenen. Eigene Gewichte gibst du als lokale Angabe.")
            }
        }
    }

    // MARK: - Rows

    /// A stated value, a stated zero included; an absent one says so
    /// rather than reading as 0.
    private func statedRow(
        _ label: String, _ values: NutritionInfo, _ nutrient: Nutrient,
        gramsPerUnit: Double = 1, indented: Bool = false
    ) -> some View {
        nutrientRow(label, values[nutrient].map { mass($0 * gramsPerUnit) } ?? Self.notStated, indented: indented)
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
}
