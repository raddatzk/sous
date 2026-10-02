import SousKit
import SwiftUI

/// The one local form (INGREDIENTS-DATA §3 B): what this household says about
/// a name the catalog cannot answer yet. Three things, which combine — "zählt
/// wie" (or a product chosen for the name), own values with their source, and
/// own weights per unit — plus brand and EAN for a product of its own.
///
/// Deliberately not here: aliases, varieties, aisles, statuses. Those are
/// the catalog's, and reach it through the report, not through this form.
/// Whatever is saved stays the household's own: the shopping list goes on
/// showing the written name (R2).
struct LocalAnswerForm: View {
    @Environment(IngredientCatalogLibrary.self) private var catalog
    @Environment(NutritionLibrary.self) private var nutrition
    @Environment(\.dismiss) private var dismiss

    /// The name as written in the recipe.
    let name: String
    private let existing: LocalAnswer?

    @State private var draft: Draft
    @State private var targetQuery = ""
    @State private var isWriting = false

    init(name: String, existing: LocalAnswer?) {
        self.name = name
        self.existing = existing
        _draft = State(initialValue: Draft(existing ?? LocalAnswer(name: name)))
    }

    /// The units a weight can be given for. Mass and the litre stay out — a
    /// gram weighs a gram, and a millilitre is what the density answers.
    static let units: [IngredientUnit] = [
        .piece, .clove, .bunch, .leaf, .package, .pinch, .knifeTip, .cup, .teaspoon, .tablespoon,
        .can, .jar, .stalk, .sprig, .stem, .centimeter, .handful, .splash, .head,
    ]

    /// Whether the catalog itself knows the name. "Zählt wie" is only for a
    /// name it does not (§3 B); for a known one, a target is a brand choice.
    private var catalogKnowsName: Bool { catalog.catalogKnows(name) }

    private var hasChanges: Bool { draft != Draft(existing ?? LocalAnswer(name: name)) }

    var body: some View {
        NavigationStack {
            Form {
                if let trace = catalog.localTrace(for: name), trace.status != .applied {
                    Section {
                        Text(trace.label)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                targetSection
                valuesSection
                productSection
                weightsSection
                if existing != nil {
                    Section {
                        Button("Lokale Angabe entfernen", role: .destructive) {
                            write { if let existing { await catalog.deleteLocalAnswer(existing) } }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("„\(name)“")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        let answer = draft.answer(base: existing ?? LocalAnswer(name: name), catalogKnowsName: catalogKnowsName)
                        write { await catalog.saveLocalAnswer(answer) }
                    }
                    .disabled(!hasChanges || isWriting)
                }
            }
        }
        .interactiveDismissDisabled(hasChanges)
        .sousSheetSizing(.form)
    }

    // MARK: - Sections

    private var targetSection: some View {
        Section {
            if let targetID = draft.targetID {
                HStack {
                    Text(catalog.catalog.ingredient(forID: targetID)?.name ?? targetID)
                    Spacer()
                    Button("Entfernen", role: .destructive) { draft.targetID = nil }
                        .buttonStyle(.borderless)
                }
                if !catalogKnowsName {
                    Toggle("Markenwahl (Produkt)", isOn: $draft.isProduct)
                }
            } else {
                TextField("Im Katalog suchen", text: $targetQuery)
                ForEach(targets) { match in
                    Button {
                        draft.targetID = match.catalogID
                        targetQuery = ""
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.name)
                            Text(match.product.map { "Produkt · \($0.brand)" } ?? match.category.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text(catalogKnowsName ? "Produkt wählen" : "Zählt wie")
        } footer: {
            Text(catalogKnowsName
                ? "Für diesen Haushalt rechnet „\(name)“ dann mit dem gewählten Produkt, auch wenn der Katalog später mehr weiß."
                : "„\(name)“ rechnet dann mit Nährwerten und Gewichten des Ziels und steht in dessen Gang. Auf der Einkaufsliste bleibt es „\(name)“. Kennt der Katalog den Namen später selbst, gilt seine Angabe – außer bei einer Markenwahl.")
        }
    }

    /// Catalog words to count as: only shipped ones, which have an id to
    /// point at, never the name itself, and no product that is no longer
    /// sold. For a name the catalog knows, this is a brand choice, so its
    /// products come first.
    private var targets: [CatalogIngredient] {
        catalog.catalogWithoutLocalAnswers.search(targetQuery, limit: 12)
            .filter {
                $0.catalogID != nil && $0.key != IngredientCatalog.normalize(name)
                    && $0.product?.isDiscontinued != true
            }
            .enumerated()
            .sorted { first, second in
                guard catalogKnowsName else { return first.offset < second.offset }
                let a = first.element.product == nil ? 1 : 0, b = second.element.product == nil ? 1 : 0
                return (a, first.offset) < (b, second.offset)
            }
            .prefix(8)
            .map(\.element)
    }

    private var valuesSection: some View {
        Section {
            numberField("Energie (kcal)", text: $draft.kcal)
            numberField("Fett (g)", text: $draft.fat)
            numberField("davon gesättigte Fettsäuren (g)", text: $draft.saturatedFat, indented: true)
            numberField("Kohlenhydrate (g)", text: $draft.carbs)
            numberField("davon Zucker (g)", text: $draft.sugar, indented: true)
            numberField("Ballaststoffe (g)", text: $draft.fiber)
            numberField("Eiweiß (g)", text: $draft.protein)
            numberField("Salz (g)", text: $draft.salt)
            TextField("Quelle, z. B. Packung", text: $draft.source)
        } header: {
            Text("Eigene Werte je 100 g")
        } footer: {
            Text("Schlagen die Werte des Katalogs und des Ziels. Was die Packung nicht angibt, bleibt leer: es fehlt, statt als 0 zu zählen.")
        }
    }

    private var productSection: some View {
        Section {
            TextField("Marke", text: $draft.brand)
            TextField("EAN", text: $draft.ean)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            if draft.eanLooksWrong {
                Text("Die Prüfziffer passt nicht zu dieser EAN.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Eigenes Produkt")
        } footer: {
            Text("Mit Marke oder EAN wird die Angabe ein eigenes Produkt.")
        }
    }

    private var weightsSection: some View {
        Section {
            ForEach($draft.weights) { $weight in
                HStack {
                    Text("1 \(weight.unit) =")
                    TextField("—", text: $weight.grams)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .frame(maxWidth: 80)
                    Text("g")
                    Picker("Zustand", selection: $weight.state) {
                        Text("wie gekauft").tag(IngredientState?.none)
                        Text("roh").tag(IngredientState?.some(.raw))
                        Text("gegart/abgetropft").tag(IngredientState?.some(.cooked))
                    }
                    .labelsHidden()
                }
            }
            .onDelete { draft.weights.remove(atOffsets: $0) }
            let free = Self.units.filter { unit in !draft.weights.contains { $0.unit == unit.symbol } }
            if !free.isEmpty {
                Menu("Gewicht hinzufügen", systemImage: "plus") {
                    ForEach(free, id: \.symbol) { unit in
                        Button(unit.symbol) { draft.weights.append(.init(unit: unit.symbol)) }
                    }
                }
            }
        } header: {
            Text("Eigene Gewichte")
        } footer: {
            Text("Ein Gewicht gilt nur für seine Einheit und schlägt dort den Katalog.")
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

    /// Finishes the write before the sheet closes, so what opens next already
    /// reads with it — and the nutrition table with it.
    private func write(_ change: @escaping () async -> Void) {
        guard !isWriting else { return }
        isWriting = true
        Task {
            await change()
            await nutrition.ensureLoaded()
            dismiss()
        }
    }
}

/// The form's fields as typed — text, so an empty field stays empty rather
/// than turning into a 0 nobody entered.
private struct Draft: Equatable {
    struct Weight: Identifiable, Equatable {
        let id = UUID()
        var unit: String
        var grams = ""
        var state: IngredientState?

        static func == (lhs: Weight, rhs: Weight) -> Bool {
            lhs.unit == rhs.unit && lhs.grams == rhs.grams && lhs.state == rhs.state
        }
    }

    var targetID: String?
    var isProduct = false
    var kcal = ""
    var protein = ""
    var fat = ""
    var saturatedFat = ""
    var carbs = ""
    var sugar = ""
    var fiber = ""
    var salt = ""
    var source = ""
    var brand = ""
    var ean = ""
    var weights: [Weight] = []

    /// An EAN was typed, and its check digit does not fit.
    var eanLooksWrong: Bool {
        let code = ean.trimmingCharacters(in: .whitespaces)
        return !code.isEmpty && !CatalogProduct.isValidEAN(code)
    }

    init(_ answer: LocalAnswer) {
        targetID = answer.targetID
        isProduct = answer.kind == .product
        if let values = answer.values {
            // A stated 0 reads "0"; only an absent value is a blank field.
            func text(_ nutrient: Nutrient, _ factor: Double = 1) -> String {
                values[nutrient].map { DecimalText.text($0 / factor) } ?? ""
            }
            kcal = text(.kcal)
            protein = text(.proteinG)
            fat = text(.fatG)
            saturatedFat = text(.saturatedFatG)
            carbs = text(.carbsG)
            sugar = text(.sugarG)
            fiber = text(.fiberG)
            salt = text(.sodiumMg, NutritionInfo.sodiumMgPerSaltGram)
        }
        source = answer.valuesSource ?? ""
        brand = answer.brand ?? ""
        ean = answer.ean ?? ""
        weights = answer.weights.keys.sorted().map { unit in
            Weight(unit: unit, grams: DecimalText.text(answer.weights[unit]?.grams ?? 0), state: answer.weights[unit]?.state)
        }
    }

    /// The draft written onto `base`, keeping its id and sharing stamp.
    func answer(base: LocalAnswer, catalogKnowsName: Bool) -> LocalAnswer {
        var answer = base
        answer.targetID = targetID
        let isBrand = !brand.trimmingCharacters(in: .whitespaces).isEmpty
            || !ean.trimmingCharacters(in: .whitespaces).isEmpty
        answer.kind = if targetID != nil {
            catalogKnowsName || isProduct ? .product : .countsAs
        } else {
            isBrand ? .product : nil
        }
        let entered = [kcal, protein, fat, saturatedFat, carbs, sugar, fiber, salt].map(DecimalText.number)
        answer.values = entered.contains(where: { $0 != nil }) ? NutritionInfo.label(
            kcal: entered[0], proteinG: entered[1], fatG: entered[2],
            saturatedFatG: entered[3], carbsG: entered[4], sugarG: entered[5],
            fiberG: entered[6], saltG: entered[7]
        ) : nil
        answer.valuesSource = answer.values == nil ? nil : source
        answer.brand = brand
        answer.ean = ean
        answer.weights = weights.reduce(into: [:]) { result, weight in
            guard let grams = DecimalText.number(weight.grams), grams > 0 else { return }
            result[weight.unit] = LocalAnswer.Weight(grams: grams, state: weight.state)
        }
        return answer
    }
}
