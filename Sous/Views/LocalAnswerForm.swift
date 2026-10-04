import SousKit
import SwiftUI

/// The one local form (INGREDIENTS-DATA §3 B): what this household says about
/// a name the catalog cannot answer yet. Three things, which combine — "zählt
/// wie" (or a product chosen for the name), own values with their source, and
/// own weights per unit.
///
/// The same form keeps an **own product**: an entry of the
/// household's catalog with name and brand, optionally EAN, label values and
/// a word it counts like until the label is in. A name links to it by
/// choosing it as its product; the name's own form carries no brand.
///
/// Deliberately not here: aliases, varieties, aisles, statuses. Those are
/// the catalog's, and reach it through the report, not through this form.
/// Whatever is saved stays the household's own: the shopping list goes on
/// showing the written name (R2).
struct LocalAnswerForm: View {
    @Environment(IngredientCatalogLibrary.self) private var catalog
    @Environment(NutritionLibrary.self) private var nutrition
    @Environment(\.dismiss) private var dismiss

    /// The name as written in the recipe — for an own product, the name it
    /// was opened with.
    let name: String
    private let existing: LocalAnswer?
    /// Whether the form keeps an own product rather than answers a name.
    private let isOwnProduct: Bool

    /// What the fields started as, so only a change counts as one.
    private let initialDraft: Draft
    /// Told the saved product's name — a new product made from a name's
    /// "Neues Produkt …", which that name then chooses.
    private let onSaved: ((String) -> Void)?

    @State private var draft: Draft
    @State private var targetQuery = ""
    @State private var isWriting = false
    @State private var isCreatingProduct = false

    /// The answer about `name`; an own product opens as one.
    init(name: String, existing: LocalAnswer?) {
        self.name = name
        self.existing = existing
        isOwnProduct = existing?.isLocalProduct ?? false
        initialDraft = Draft(existing ?? LocalAnswer(name: name))
        onSaved = nil
        _draft = State(initialValue: initialDraft)
    }

    /// A new own product — "Produkt hinzufügen" in the catalog, or "Neues
    /// Produkt …" from a name's form, counting like `like` until its label
    /// is in.
    init(newProduct: Void, like: String? = nil, onSaved: ((String) -> Void)? = nil) {
        name = ""
        existing = nil
        isOwnProduct = true
        initialDraft = Draft(LocalAnswer(name: "", targetID: like))
        self.onSaved = onSaved
        _draft = State(initialValue: initialDraft)
    }

    /// The units a weight can be given for. Mass and the litre stay out — a
    /// gram weighs a gram, and a millilitre is what the density answers.
    static let units: [IngredientUnit] = [
        .piece, .clove, .bunch, .leaf, .package, .pinch, .knifeTip, .cup, .teaspoon, .tablespoon,
        .can, .jar, .stalk, .sprig, .stem, .centimeter, .handful, .splash, .head,
    ]

    /// Whether the catalog itself knows the name. "Zählt wie" is only for a
    /// name it does not (§3 B); for a known one, a target is a brand choice.
    private var catalogKnowsName: Bool { !isOwnProduct && catalog.catalogKnows(name) }

    private var hasChanges: Bool { draft != initialDraft }

    /// An own product needs a name and a brand; a name's answer, nothing.
    private var canSave: Bool {
        guard isOwnProduct else { return true }
        return !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.brand.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var title: String {
        if isOwnProduct { return existing == nil ? "Neues Produkt" : existing!.name }
        return "„\(name)“"
    }

    var body: some View {
        NavigationStack {
            Form {
                if !isOwnProduct, let trace = catalog.localTrace(for: name), trace.status != .applied {
                    Section {
                        Text(trace.label)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if isOwnProduct { productSection }
                targetSection
                valuesSection
                weightsSection
                if existing != nil {
                    Section {
                        Button(isOwnProduct ? "Produkt entfernen" : "Lokale Angabe entfernen", role: .destructive) {
                            write { if let existing { await catalog.removeLocalAnswer(existing) } }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        let answer = draft.answer(
                            base: existing ?? LocalAnswer(name: name),
                            isOwnProduct: isOwnProduct,
                            isProductChoice: catalogKnowsName || chosenTargetIsProduct
                        )
                        write {
                            if await catalog.saveLocalAnswer(answer), isOwnProduct {
                                onSaved?(answer.name.trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                        }
                    }
                    .disabled(!hasChanges || !canSave || isWriting)
                }
            }
        }
        .interactiveDismissDisabled(hasChanges)
        .sousSheetSizing(.form)
        .sheet(isPresented: $isCreatingProduct) {
            LocalAnswerForm(newProduct: (), like: newProductLike) { productName in
                let key = IngredientCatalog.normalize(productName)
                draft.targetID = catalog.ownProducts.first { $0.writtenKey == key }?.key
            }
        }
    }

    /// What a product made from this name counts like until its label is
    /// in: the name's own catalog word, or the generic word it counts as.
    private var newProductLike: String? {
        if let word = catalog.catalogWithoutLocalAnswers.ingredient(writtenAs: name),
           word.product == nil, let id = word.catalogID {
            return id
        }
        guard let targetID = draft.targetID, !LocalAnswer.isKey(targetID),
              catalog.catalog.ingredient(forID: targetID)?.product == nil
        else { return nil }
        return targetID
    }

    // MARK: - Sections

    private var productSection: some View {
        Section {
            TextField("Name, z. B. Greenforce Sojahack", text: $draft.name)
            TextField("Marke", text: $draft.brand)
            TextField("EAN (optional)", text: $draft.ean)
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
            Text("Ein Name im Rezept, etwa „Sojahack“, verweist über „Produkt wählen“ auf dieses Produkt. Auf der Einkaufsliste steht dann die Marke dabei.")
        }
    }

    private var targetSection: some View {
        Section {
            if let targetID = draft.targetID {
                HStack {
                    Text(catalog.targetName(for: targetID) ?? targetID)
                    Spacer()
                    Button("Entfernen", role: .destructive) { draft.targetID = nil }
                        .buttonStyle(.borderless)
                }
            } else {
                TextField(isOwnProduct ? "Im Katalog suchen" : "Im Katalog und in eigenen Produkten suchen",
                          text: $targetQuery)
                ForEach(targets) { choice in
                    Button {
                        draft.targetID = choice.id
                        targetQuery = ""
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.name)
                            Text(choice.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                if !isOwnProduct {
                    Button("Neues Produkt …", systemImage: "plus") { isCreatingProduct = true }
                }
            }
        } header: {
            Text(isOwnProduct ? "Rechnet wie" : catalogKnowsName ? "Produkt wählen" : "Zählt wie oder Produkt")
        } footer: {
            Text(targetFooter)
        }
    }

    private var targetFooter: String {
        if isOwnProduct {
            return "Ohne Packungswerte rechnet das Produkt mit diesem Wort, als Schätzung. Packungswerte unten gehen vor."
        }
        if catalogKnowsName {
            return "Für diesen Haushalt rechnet „\(name)“ dann mit dem gewählten Produkt, auch wenn der Katalog später mehr weiß. Eigene Produkte legst du im Zutatenkatalog an."
        }
        return "„\(name)“ rechnet dann mit Nährwerten und Gewichten des Ziels und steht in dessen Gang. Auf der Einkaufsliste bleibt es „\(name)“. Kennt der Katalog den Namen später selbst, gilt seine Angabe – außer bei einem gewählten Produkt."
    }

    /// One thing a name can count as or choose: a catalog word or product, or
    /// one of the household's own products, by the id the answer stores.
    private struct TargetChoice: Identifiable {
        let id: String
        let name: String
        let detail: String
    }

    /// Whether the chosen target is a product, so the choice is a purchase,
    /// not a "zählt wie".
    private var chosenTargetIsProduct: Bool {
        guard let targetID = draft.targetID else { return false }
        if LocalAnswer.isKey(targetID) { return true }
        return catalog.catalog.ingredient(forID: targetID)?.product != nil
    }

    /// What a name can point at: the household's own products first, then
    /// shipped catalog words, which have an id to point at — never the name
    /// itself, and no product that is no longer sold. For a name the catalog
    /// knows, this is a brand choice, so products come first. An own
    /// product counts like a generic word only.
    private var targets: [TargetChoice] {
        let own: [TargetChoice] = isOwnProduct ? [] : {
            let query = IngredientCatalog.normalize(targetQuery)
            return catalog.ownProducts
                .filter { query.isEmpty || $0.writtenKey.contains(query)
                    || ($0.brand.map(IngredientCatalog.normalize)?.contains(query) ?? false) }
                .map { TargetChoice(id: $0.key, name: $0.name,
                                    detail: "Eigenes Produkt" + ($0.brand.map { " · \($0)" } ?? "")) }
        }()
        let words = catalog.catalogWithoutLocalAnswers.search(targetQuery, limit: 12)
            .filter {
                $0.catalogID != nil && $0.key != IngredientCatalog.normalize(name)
                    && $0.product?.isDiscontinued != true
                    && !(isOwnProduct && $0.product != nil)
            }
            .enumerated()
            .sorted { first, second in
                guard catalogKnowsName else { return first.offset < second.offset }
                let a = first.element.product == nil ? 1 : 0, b = second.element.product == nil ? 1 : 0
                return (a, first.offset) < (b, second.offset)
            }
            .map(\.element)
            .map { TargetChoice(id: $0.catalogID!, name: $0.name,
                                detail: $0.product.map { "Produkt · \($0.brand)" } ?? $0.category.title) }
        return Array((own + words).prefix(8))
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

    var name = ""
    var targetID: String?
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
        name = answer.name
        targetID = answer.targetID
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

    /// The draft written onto `base`, keeping its id and sharing stamp. An
    /// own product is a product with its brand; a name's answer carries none,
    /// and is a purchase where `isProductChoice` says the target is one.
    func answer(base: LocalAnswer, isOwnProduct: Bool, isProductChoice: Bool) -> LocalAnswer {
        var answer = base
        answer.targetID = targetID
        if isOwnProduct {
            answer.name = name
            answer.kind = .product
            answer.brand = brand
            answer.ean = ean
        } else {
            answer.kind = if targetID != nil {
                isProductChoice ? .product : .countsAs
            } else {
                base.kind == .word ? .word : nil
            }
        }
        let entered = [kcal, protein, fat, saturatedFat, carbs, sugar, fiber, salt].map(DecimalText.number)
        answer.values = entered.contains(where: { $0 != nil }) ? NutritionInfo.label(
            kcal: entered[0], proteinG: entered[1], fatG: entered[2],
            saturatedFatG: entered[3], carbsG: entered[4], sugarG: entered[5],
            fiberG: entered[6], saltG: entered[7]
        ) : nil
        answer.valuesSource = answer.values == nil ? nil : source
        answer.weights = weights.reduce(into: [:]) { result, weight in
            guard let grams = DecimalText.number(weight.grams), grams > 0 else { return }
            result[weight.unit] = LocalAnswer.Weight(grams: grams, state: weight.state)
        }
        return answer
    }
}
