import SousKit
import SwiftUI

/// The stops one ingredient line makes on its way through the app: read,
/// found in the catalog, bought, counted — and, where the catalog does not
/// know it yet, taught once.
///
/// Told as stages of a single example rather than as a paragraph, because
/// every stage is something the cook gets without doing anything, and a
/// paragraph about a catalog reads like homework. The last stage is the one
/// that does ask something of them, and it is there so that the banners
/// asking it later ("fehlen im Katalog") read as the step they are rather
/// than as a defect.
enum IngredientJourneyStage: Int, CaseIterable, Identifiable {
    case reading
    case catalog
    case shopping
    case nutrition
    case teaching

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .reading: "Lesen"
        case .catalog: "Katalog"
        case .shopping: "Einkauf"
        case .nutrition: "Nährwerte"
        case .teaching: "Neu"
        }
    }

    var symbol: String {
        switch self {
        case .reading: "text.viewfinder"
        case .catalog: "text.book.closed"
        case .shopping: "cart"
        case .nutrition: "chart.bar"
        case .teaching: "plus.circle"
        }
    }
}

/// The example, run through the app's own parser, catalog and nutrition
/// tables rather than written out by hand — so the page can never show a
/// category, a spelling or a calorie figure the app would not arrive at
/// itself. Anything the data does not answer is `nil`, and the stage that
/// would show it leaves it out instead of inventing it.
struct IngredientJourneyExample {
    static let line = "200 g Zwiebeln, fein gewürfelt"
    /// A second recipe asking for the same thing under the same name, so the
    /// shopping stage has something to add up. Invented, and only ever shown
    /// beside the line it is added to.
    static let recipe = "Linsen-Dal"
    static let otherRecipe = "Gulasch"
    static let otherGrams = 300.0
    static let unknownLine = "400 ml dünne Kokosmilch"
    static let unknownName = "dünne Kokosmilch"

    var parsed: RecipeIngredient
    var ingredient: CatalogIngredient?
    var spellings: [String]
    var varieties: [String]
    var grams: Double?
    var basisName: String?
    var nutrients: NutritionInfo?
    var match: CatalogIngredient?

    @MainActor
    init(catalog: IngredientCatalog, nutrition: NutritionLibrary) {
        parsed = IngredientLineReader.readLine(Self.line, catalog: catalog)
        ingredient = catalog.ingredient(for: parsed.name)
        let name = ingredient?.name ?? parsed.name
        spellings = Array((ingredient?.aliases ?? []).filter {
            IngredientCatalog.normalize($0) != IngredientCatalog.normalize(name)
        }.prefix(3))
        varieties = Array(catalog.variants(of: name).map(\.name).prefix(2))
        grams = NutritionResolver.resolve(
            for: parsed, catalog: catalog, nutritionCatalog: nutrition.nutritionCatalog
        )?.grams
        let entry = nutrition.nutrition(forName: name)
        basisName = entry?.basis(for: parsed.state)?.catalogName
        if let grams, let values = entry?.nutrition(for: parsed.state) {
            nutrients = values.scaled(byGrams: grams)
        }
        match = catalog.search(Self.unknownName, limit: 1).first
    }

    var name: String { ingredient?.name ?? parsed.name }
}

/// The stages, one at a time, under a row of tappable stops.
///
/// Plays on its own while `isPlaying` — a stage every few seconds, round
/// and round — and stops for good the moment the cook picks a stage, since
/// from then on they are reading at their own pace. It never plays with
/// reduced motion or VoiceOver: text that changes under a reader is text
/// they cannot finish.
struct IngredientJourneyView: View {
    @Environment(IngredientCatalogLibrary.self) private var catalogLibrary
    @Environment(NutritionLibrary.self) private var nutritionLibrary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @Binding var stage: IngredientJourneyStage
    var isPlaying = false

    @State private var tookOver = false

    private let formatter = QuantityFormatter(locale: .sous)

    var body: some View {
        let example = IngredientJourneyExample(
            catalog: catalogLibrary.catalog, nutrition: nutritionLibrary
        )
        VStack(spacing: 16) {
            Text(stage == .teaching ? IngredientJourneyExample.unknownLine : IngredientJourneyExample.line)
                .font(SousStyle.groupHeading)
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(Color.sousSurface, in: .rect(cornerRadius: SousStyle.fieldRadius))
                .contentTransition(.opacity)
            stops
            // Every stage laid out at once and all but one faded out, so the
            // block is as tall as its tallest stage throughout. Swapping them
            // outright let the height change with each one, and the welcome
            // — which centres its pages — jumped up and down with it.
            ZStack(alignment: .top) {
                ForEach(IngredientJourneyStage.allCases) { item in
                    let isShown = item == stage
                    VStack(spacing: 16) {
                        Text(caption(item, example))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        content(item, example)
                            .frame(maxWidth: .infinity)
                            .offset(y: isShown || reduceMotion ? 0 : 8)
                    }
                    .opacity(isShown ? 1 : 0)
                    .accessibilityHidden(!isShown)
                }
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: stage)
        .task(id: autoplays) {
            guard autoplays else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, autoplays else { return }
                let next = IngredientJourneyStage(rawValue: stage.rawValue + 1) ?? .reading
                stage = next
            }
        }
    }

    private var autoplays: Bool {
        isPlaying && !tookOver && !reduceMotion && !voiceOver
    }

    private func caption(_ stage: IngredientJourneyStage, _ example: IngredientJourneyExample) -> String {
        switch stage {
        case .reading:
            "Sous liest jede Zutatenzeile und trennt Menge, Zutat und Zubereitung — ohne dass du etwas extra eintippst."
        case .catalog:
            "Im Zutatenkatalog ist „\(example.parsed.name)“ die Zutat \(example.name), egal wie ein Rezept sie schreibt. Dort steht auch, wo sie im Laden liegt."
        case .shopping:
            "Auf der Einkaufsliste wird daraus eine Zeile, auch wenn zwei Rezepte sie brauchen — sortiert nach Abteilung, wie du durch den Laden gehst."
        case .nutrition:
            "Zur Zutat gehören Nährwerte aus dem Bundeslebensmittelschlüssel. Aus Gramm und Nährwerten rechnet Sous jedes Rezept pro Portion aus."
        case .teaching:
            "Kennt Sous eine Zutat noch nicht, bringst du sie ihm einmal bei — als andere Schreibweise oder als Sorte. Danach gilt sie in jedem Rezept."
        }
    }

    @ViewBuilder
    private func content(_ stage: IngredientJourneyStage, _ example: IngredientJourneyExample) -> some View {
        switch stage {
        case .reading: reading(example)
        case .catalog: catalog(example)
        case .shopping: shopping(example)
        case .nutrition: nutrition(example)
        case .teaching: teaching(example)
        }
    }

    // MARK: - Stages

    /// The three parts in a row where they fit, stacked where they do not.
    /// Only the name is tinted: it is the part that travels on.
    private func reading(_ example: IngredientJourneyExample) -> some View {
        let parts = Group {
            if let quantity = example.parsed.quantity {
                part("Menge", formatter.string(for: quantity))
            }
            part("Zutat", example.parsed.name, isTraveling: true)
            if let preparation = example.parsed.preparation {
                part("Zubereitung", preparation)
            }
        }
        return ViewThatFits {
            HStack(alignment: .firstTextBaseline, spacing: 8) { parts }
            VStack(spacing: 8) { parts }
        }
    }

    @ViewBuilder
    private func part(_ title: String, _ value: String, isTraveling: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
                .sousToggleChip(isOn: isTraveling)
        }
    }

    private func catalog(_ example: IngredientJourneyExample) -> some View {
        card {
            HStack {
                Text(example.name)
                    .font(SousStyle.groupHeading)
                Spacer()
                if let category = example.ingredient?.category {
                    Text(category.title)
                        .font(.footnote.weight(.medium))
                        .sousChip()
                        .tint(Color.sousCategory(category.title))
                }
            }
            if !example.spellings.isEmpty {
                detail("auch", example.spellings.joined(separator: " · "))
            }
            if !example.varieties.isEmpty {
                detail("Sorten", example.varieties.joined(separator: " · "))
            }
        }
    }

    private func shopping(_ example: IngredientJourneyExample) -> some View {
        let grams = example.grams ?? 0
        let total = Quantity(grams + IngredientJourneyExample.otherGrams, .gram)
        let own = Quantity(grams, .gram)
        let other = Quantity(IngredientJourneyExample.otherGrams, .gram)
        return card {
            if let category = example.ingredient?.category {
                Text(category.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.sousCategory(category.title))
            }
            HStack {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                Text(example.name)
                Spacer()
                Text(formatter.string(for: total))
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
            Text(
                "\(formatter.string(for: own)) \(IngredientJourneyExample.recipe) · \(formatter.string(for: other)) \(IngredientJourneyExample.otherRecipe)"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.leading, 28)
        }
    }

    @ViewBuilder
    private func nutrition(_ example: IngredientJourneyExample) -> some View {
        card {
            if let basisName = example.basisName {
                detail("beruht auf", basisName)
            }
            if let nutrients = example.nutrients, let grams = example.grams {
                HStack(alignment: .firstTextBaseline) {
                    Text(formatter.string(for: Quantity(grams, .gram)))
                    Spacer()
                    Text("\(Int(nutrients.kcal.rounded())) kcal")
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.sousAccent)
                }
                HStack {
                    nutrient("Eiweiß", nutrients.proteinG)
                    nutrient("Kohlenhydrate", nutrients.carbsG)
                    nutrient("Fett", nutrients.fatG)
                }
            }
        }
    }

    private func nutrient(_ title: String, _ grams: Double) -> some View {
        VStack(spacing: 2) {
            Text("\(grams.formatted(.number.precision(.fractionLength(0...1)).locale(.sous))) g")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func teaching(_ example: IngredientJourneyExample) -> some View {
        card {
            HStack {
                Text(IngredientJourneyExample.unknownName)
                Spacer()
                Label("noch unbekannt", systemImage: "questionmark.circle")
                    .font(.footnote)
                    .sousSuggestionChip()
                    .foregroundStyle(.secondary)
            }
            if let match = example.match {
                detail("im Katalog", match.name)
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    Text("anders geschrieben")
                        .font(.footnote.weight(.medium))
                        .sousChip()
                        .tint(Color.sousAccent)
                    Text("eine Sorte davon")
                        .font(.footnote.weight(.medium))
                        .sousSuggestionChip()
                }
            }
        }
    }

    // MARK: - Pieces

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .overlay {
            RoundedRectangle(cornerRadius: SousStyle.fieldRadius)
                .strokeBorder(.separator)
        }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        (Text("\(title): ").foregroundStyle(.secondary) + Text(value))
            .font(.footnote)
    }

    /// The five stops, tappable. Also what VoiceOver moves through, one
    /// button per stage, with the chosen one marked selected.
    private var stops: some View {
        HStack(spacing: 4) {
            ForEach(IngredientJourneyStage.allCases) { item in
                Button {
                    tookOver = true
                    stage = item
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.symbol)
                            .font(.body)
                        Text(item.label)
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(item == stage ? Color.sousAccent : .secondary)
                    .background(
                        item == stage ? Color.sousAccent.opacity(SousStyle.chipTint) : .clear,
                        in: .rect(cornerRadius: 10)
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == stage ? .isSelected : [])
            }
        }
    }
}

/// The same stages on their own, for the "So funktioniert’s" beside a
/// banner — opened at the stage that banner is about.
struct IngredientJourneySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var stage: IngredientJourneyStage

    init(start: IngredientJourneyStage) {
        _stage = State(initialValue: start)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                IngredientJourneyView(stage: $stage)
                    .frame(maxWidth: 420)
                    .padding(20)
                    .frame(maxWidth: .infinity)
            }
            .navigationTitle("So funktioniert’s")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .sousSheetSizing(.form)
    }
}
