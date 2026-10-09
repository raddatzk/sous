import SousKit
import SwiftUI

/// The stops of one ingredient line that the welcome gives a page each:
/// found in the catalog, bought, counted.
///
/// Told with a single example rather than a paragraph, because every stop is
/// something the cook gets without doing anything, and a paragraph about a
/// catalog reads like homework. What an unknown name offers (the optimization,
/// a local answer, a report) is the catalog page's own text: none of it is
/// maintenance, the catalog is the curator's, not the cook's
/// (INGREDIENTS-DATA §3 A).
enum IngredientJourneyStage: Int, CaseIterable, Identifiable {
    case catalog
    case shopping
    case nutrition

    var id: Int { rawValue }
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

    var parsed: RecipeIngredient
    var ingredient: CatalogIngredient?
    var spellings: [String]
    var varieties: [String]
    var grams: Double?
    var basisName: String?
    var nutrients: NutritionInfo?

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
    }

    var name: String { ingredient?.name ?? parsed.name }
}

/// The example line and what one stop makes of it, as a tile.
struct IngredientJourneyTile: View {
    @Environment(IngredientCatalogLibrary.self) private var catalogLibrary
    @Environment(NutritionLibrary.self) private var nutritionLibrary

    let stage: IngredientJourneyStage

    private let formatter = QuantityFormatter(locale: .sous)

    var body: some View {
        let example = IngredientJourneyExample(
            catalog: catalogLibrary.catalog, nutrition: nutritionLibrary
        )
        VStack(spacing: 16) {
            Text(IngredientJourneyExample.line)
                .font(SousStyle.groupHeading)
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(Color.sousSurface, in: .rect(cornerRadius: SousStyle.fieldRadius))
            switch stage {
            case .catalog: catalog(example)
            case .shopping: shopping(example)
            case .nutrition: nutrition(example)
            }
        }
    }

    // MARK: - Stages

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
        // Interpolated rather than added together: `Text + Text` is
        // deprecated as of the 26 SDKs.
        Text("\(Text("\(title): ").foregroundStyle(.secondary))\(value)")
            .font(.footnote)
    }
}
