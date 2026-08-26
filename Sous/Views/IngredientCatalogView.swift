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
    private let isNew: Bool

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

    init(ingredient: CatalogIngredient) {
        original = ingredient
        isNew = ingredient.name.isEmpty
        _name = State(initialValue: ingredient.name)
        _aliasText = State(initialValue: ingredient.aliases.joined(separator: ", "))
        _category = State(initialValue: ingredient.category)
        _nutritionDraft = State(initialValue: NutritionDraft())
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

    /// The cook's own numbers for it, which are the editable ones.
    private var ownNutrition: CatalogNutrition? {
        guard !trimmedName.isEmpty else { return nil }
        return nutrition.ownNutrition(forCanonicalName: trimmedName)
    }

    /// Bundled values are shown, not offered for editing: correcting BLS
    /// belongs in a pull request against the data, not in one cook's device.
    private var isNutritionEditable: Bool {
        resolvedNutrition == nil || ownNutrition != nil
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
                pantrySection
                nutritionSection
            }
            .formStyle(.grouped)
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
                await nutrition.reload()
                nutritionDraft = NutritionDraft(ownNutrition)
                await shopping.ensurePantryLoaded()
                storedPantry = shopping.pantryKeys.contains(pantryKey)
                isPantry = storedPantry
            }
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

    /// The key the shopping list files this ingredient under.
    private var pantryKey: String {
        ShoppingItem.key(for: trimmedName, catalog: catalog.catalog)
    }

    private var pantrySection: some View {
        Section {
            Toggle("Vorrat", isOn: $isPantry)
        } footer: {
            Text("Vorräte stehen auf der Einkaufsliste eingeklappt am Ende — zum Durchsehen am Regal statt zwischen den Besorgungen.")
        }
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
                }
            }
            HStack {
                TextField("Weitere Schreibweise hinzufügen", text: $newAlias)
                    .onSubmit { addAlias() }
                Button("Hinzufügen", systemImage: "plus.circle.fill", action: addAlias)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(newAlias.trimmingCharacters(in: .whitespaces).isEmpty)
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
            if let perPiece = entry.unitWeightsGrams[IngredientUnit.piece.symbol] {
                nutrientRow("Ein Stück wiegt", mass(perPiece))
            }
        } header: {
            Text("Nährwerte je 100 g")
        } footer: {
            // The entry's own string, never a label hardcoded here — the day
            // a second source joins BLS, this line has to keep telling the
            // truth without anyone remembering to come back for it.
            Text("Quelle: \(entry.source)")
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

            Toggle("Hat eine typische Stückgröße", isOn: $nutritionDraft.hasUnitWeight)
            if nutritionDraft.hasUnitWeight {
                numberField("Ein Stück wiegt (g)", text: $nutritionDraft.unitWeight)
            }

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
            Text("Ohne Nährwerte zählt diese Zutat in keinem Rezept mit. Energie und die vier Hauptwerte reichen — alles Weitere ist freiwillig. Oder mach die Zutat zur Schreibweise einer Zutat, die die App schon kennt.")
        }
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

    private func save() {
        let ingredient = CatalogIngredient(
            name: trimmedName,
            aliases: aliasText
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            category: category
        )
        let isOwn = isOwnEntry
        let editable = isNutritionEditable
        let draft = nutritionDraft
        let entered = draft.catalogNutrition(named: trimmedName)
        let pantryChanged = isPantry != storedPantry
        let pantryFlagged = isPantry
        let key = pantryKey

        Task {
            if isOwn {
                await catalog.save(ingredient)
            }
            if editable {
                if let entered {
                    await nutrition.saveIngredientNutrition(entered)
                } else if ownNutrition != nil {
                    // Everything cleared out reads as taking the entry back.
                    await nutrition.deleteIngredientNutrition(name: trimmedName)
                }
            }
            if pantryChanged {
                await shopping.setPantry(pantryFlagged, key: key)
            }
            dismiss()
        }
    }
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
    var hasUnitWeight = false
    var unitWeight = ""
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
        if let perPiece = existing.unitWeightsGrams[IngredientUnit.piece.symbol] {
            hasUnitWeight = true
            unitWeight = Self.text(perPiece)
        }
        source = existing.source
    }

    /// What was typed, as a catalog entry — or `nil` when the form is empty
    /// enough that there is nothing to record.
    func catalogNutrition(named name: String) -> CatalogNutrition? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let entered = [kcal, protein, fat, saturatedFat, carbs, sugar, fiber, salt].map(Self.number)
        guard entered.contains(where: { $0 != nil }) else { return nil }

        let perPiece = hasUnitWeight ? Self.number(unitWeight) : nil
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
            unitWeightsGrams: perPiece.map { [IngredientUnit.piece.symbol: $0] } ?? [:],
            densityGramsPerMl: nil,
            source: trimmedSource.isEmpty ? CatalogNutrition.ownSource : trimmedSource
        )
    }

    /// A German keyboard offers a comma; `Double` only reads a point.
    private static func number(_ text: String) -> Double? {
        let normalized = text
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        return normalized.isEmpty ? nil : Double(normalized)
    }

    private static func text(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// Blank for zero — see the note in `init(_:)`.
    private static func optionalText(_ value: Double) -> String {
        value > 0 ? text(value) : ""
    }
}
