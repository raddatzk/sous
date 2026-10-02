import Foundation
import SwiftData
import Testing
@testable import SousKit

/// Phase 7: products off a label, and values the source leaves out being
/// absent rather than zero (INGREDIENTS-DATA §3 I).
///
/// The two products are fixtures, laid over the bundled files the way
/// `compile.py` would write them: `Data/` holds none until the cook brings
/// the packs.
@Suite("Products and absent values")
struct ProductTests {
    // MARK: - Fixture

    /// The bundled set plus two brands of vegan butter, a discontinued drink,
    /// and their label rows — no fibre, no micronutrients, as labels go.
    static let products: DataSet = {
        func json(_ name: String) -> Any {
            let url = DataSet.bundledURL(of: name)!
            return try! JSONSerialization.jsonObject(with: Data(contentsOf: url))
        }
        var words = json("kitchen_words.json") as! [[String: Any]]
        words += [
            ["id": "testmarke-vegane-butter", "name": "Testmarke Vegane Butter", "aliases": [String](),
             "category": "dairy", "kind": "product", "brand": "Testmarke", "ean": ["0012345678905"]],
            ["id": "probe-vegane-butter", "name": "Probe Vegane Butter", "aliases": [String](),
             "category": "dairy", "kind": "product", "brand": "Probe"],
            ["id": "probe-haferdrink", "name": "Probe Haferdrink", "aliases": [String](),
             "category": "drinks", "kind": "product", "brand": "Probe", "discontinued": true],
            // No label yet: one counts like Margarine, one is not computed.
            ["id": "beispiel-vegane-butter", "name": "Beispiel Vegane Butter", "aliases": [String](),
             "category": "dairy", "kind": "product", "brand": "Beispiel", "like": "margarine"],
            ["id": "leer-vegane-butter", "name": "Leer Vegane Butter", "aliases": [String](),
             "category": "dairy", "kind": "product", "brand": "Leer"],
        ]
        var curation = json("curation.json") as! [String: Any]
        var curated = curation["words"] as! [String: Any]
        curated["Testmarke Vegane Butter"] = ["targets": ["unspecified": ["Z-testmarke-vegane-butter"]]]
        curated["Probe Vegane Butter"] = ["targets": ["unspecified": ["Z-probe-vegane-butter"]]]
        curated["Probe Haferdrink"] = ["targets": ["unspecified": ["Z-probe-haferdrink"]]]
        curation["words"] = curated
        var community = json("community.json") as! [String: Any]
        func row(_ code: String, _ name: String, per: String, _ values: [String: Double]) -> [String: Any] {
            ["code": code, "name": name, "group": "Z", "category": "dairy",
             "source": "Nährwertdeklaration der Packung", "checked": "2026-10-02", "per": per,
             "perHundredGrams": values]
        }
        community["entries"] = (community["entries"] as! [[String: Any]]) + [
            row("Z-testmarke-vegane-butter", "Testmarke Vegane Butter", per: "as-sold", [
                "kcal": 714, "fatG": 80, "saturatedFatG": 37, "carbsG": 0.5, "sugarG": 0.5,
                "proteinG": 0.2, "sodiumMg": 480,
            ]),
            row("Z-probe-vegane-butter", "Probe Vegane Butter", per: "drained", [
                "kcal": 540, "fatG": 60, "saturatedFatG": 20, "carbsG": 1, "sugarG": 1,
                "proteinG": 0.5, "sodiumMg": 400,
            ]),
            row("Z-probe-haferdrink", "Probe Haferdrink", per: "as-sold", ["kcal": 45, "fatG": 1.5]),
        ]
        let files: [DataSet.File: Data] = [
            .kitchenWords: try! JSONSerialization.data(withJSONObject: words),
            .curation: try! JSONSerialization.data(withJSONObject: curation),
            .community: try! JSONSerialization.data(withJSONObject: community),
        ]
        return try! DataSet(manifest: .bundled, origin: .bundled) { file throws(DataSetRejection) in
            if let data = files[file] { return data }
            guard let url = DataSet.bundledURL(of: file.fileName), let data = try? Data(contentsOf: url)
            else { throw .missing(file: file.fileName) }
            return data
        }
    }()

    private static func aggregate(_ text: String, in set: DataSet = products) -> NutritionReport {
        NutritionAggregator.aggregate(
            recipe: Recipe(title: "Test", servings: 1, ingredientsText: text),
            servings: 1, catalog: set.catalog, nutritionCatalog: set.nutrition
        ) { _ in nil }
    }

    // MARK: - Absent is not zero

    @Test("A BLS row's gap decodes as absent, not as a stated zero")
    func blsGapsAreAbsent() throws {
        let rows = DataSet.bundled.bls.entries
        // Fruit is not one of vitamin E's assumed-zero groups.
        let feige = try #require(DataSet.bundled.bls.entry(for: "F505100"))
        #expect(!feige.perHundredGrams.states(.vitaminEMg))
        #expect(feige.perHundredGrams[.vitaminEMg] == nil)
        #expect(feige.perHundredGrams.states(.kcal))
        // Of the 656 BLS rows the review counted, the ones a blank still
        // leaves open once Data/assumed-zeros.yaml has spoken.
        #expect(rows.filter { !$0.code.hasPrefix("Z") && !$0.perHundredGrams.absent.isEmpty }.count == 269)
    }

    @Test("A BLS blank in an assumed-zero group is a stated zero")
    func assumedZerosFillBLSBlanks() throws {
        let bls = DataSet.bundled.bls
        // Vitamin C in bread, grain and eggs; fibre and vitamin C in fish.
        for (code, nutrient) in [
            ("B271000", Nutrient.vitaminCMg), ("C111000", .vitaminCMg),
            ("E111100", .vitaminCMg), ("T410100", .fiberG),
        ] {
            let row = try #require(bls.entry(for: code))
            #expect(row.perHundredGrams[nutrient] == 0, "\(code) \(nutrient)")
        }
    }

    @Test("Assumed zeros fill the BLS's blanks only, never a supplement's or a stated value")
    func assumedZerosLeaveSupplementsAlone() throws {
        func file(_ entries: String, rules: String = "") -> Data {
            Data("""
            {"datasetVersion": "1", "release": "r", "license": "l", "attribution": "a",
             "changeNote": "c", \(rules) "entries": [\(entries)]}
            """.utf8)
        }
        let bls = file("""
            {"code": "C000001", "name": "Mehl", "group": "C", "category": "baking",
             "perHundredGrams": {"kcal": 350}},
            {"code": "C000002", "name": "Keim", "group": "C", "category": "baking",
             "perHundredGrams": {"kcal": 350, "vitaminCMg": 4}}
            """)
        let supplements = file("""
            {"code": "Z000009", "name": "Etikett", "group": "C", "category": "baking",
             "source": "Packung", "perHundredGrams": {"kcal": 350}}
            """, rules: #""assumedZero": [{"nutrient": "vitaminCMg", "groups": ["C"]}, {"nutrient": "nonsenseMg", "groups": ["C"]}],"#)
        let catalog = try BLSCatalog(bls: bls, supplements: supplements)

        #expect(catalog.entry(for: "C000001")?.perHundredGrams[.vitaminCMg] == 0)
        #expect(catalog.entry(for: "C000001")?.perHundredGrams[.fiberG] == nil)
        #expect(catalog.entry(for: "C000002")?.perHundredGrams[.vitaminCMg] == 4)
        #expect(catalog.entry(for: "Z000009")?.perHundredGrams[.vitaminCMg] == nil)
    }

    @Test("Absent survives scaling, a sum and a round trip; a sum keeps the stated part's number")
    func absentTravels() throws {
        var bread = NutritionInfo.zero
        bread.kcal = 200
        bread.vitaminCMg = 0
        bread.absent = [.vitaminCMg]
        var pepper = NutritionInfo.zero
        pepper.kcal = 30
        pepper.vitaminCMg = 120

        let sum = bread.scaled(byGrams: 50) + pepper
        #expect(sum.vitaminCMg == 120)
        #expect(sum.absent == [.vitaminCMg])

        let decoded = try JSONDecoder().decode(NutritionInfo.self, from: JSONEncoder().encode(sum))
        #expect(decoded == sum)
        // A stored figure written before this phase states every value.
        let old = try JSONDecoder().decode(NutritionInfo.self, from: Data(#"{"kcal": 10, "fiberG": 0}"#.utf8))
        #expect(old.states(.fiberG))
        #expect(!old.states(.vitaminCMg))
    }

    @Test("Label values: a blank field and every micronutrient stay absent")
    func labelValues() {
        let label = NutritionInfo.label(
            kcal: 714, proteinG: 0.2, fatG: 80, saturatedFatG: 37,
            carbsG: 0.5, sugarG: 0.5, fiberG: nil, saltG: 1.2
        )
        #expect(label.sodiumMg == 480)
        #expect(label[.fiberG] == nil)
        #expect(label.absent == [.fiberG, .vitaminAMcg, .vitaminCMg, .vitaminDMcg, .vitaminEMg,
                                 .calciumMg, .ironMg, .magnesiumMg, .potassiumMg])
        let zero = NutritionInfo.label(
            kcal: 0, proteinG: nil, fatG: nil, saturatedFatG: nil, carbsG: nil, sugarG: nil, fiberG: 0, saltG: nil
        )
        #expect(zero[.fiberG] == 0)
    }

    // MARK: - Catalog products

    @Test("A catalog product carries its brand and EANs, and its row says what the label said")
    func catalogProduct() throws {
        let butter = try #require(Self.products.catalog.ingredient(for: "Testmarke Vegane Butter"))
        #expect(butter.product == CatalogProduct(brand: "Testmarke", eans: ["0012345678905"]))
        #expect(butter.catalogID == "testmarke-vegane-butter")
        #expect(Self.products.catalog.ingredient(for: "Zwiebel")?.product == nil)

        let basis = try #require(
            Self.products.nutrition.nutrition(forCanonicalName: "Testmarke Vegane Butter")?.basis(for: .unspecified)
        )
        #expect(basis.values.kcal == 714)
        #expect(!basis.values.states(.fiberG))
        #expect(!basis.values.states(.vitaminCMg))
        #expect(basis.source == "Nährwertdeklaration der Packung · gelesen 2026-10-02")
        let drained = Self.products.nutrition.nutrition(forCanonicalName: "Probe Vegane Butter")?
            .basis(for: .unspecified)
        #expect(drained?.source == "Nährwertdeklaration der Packung · pro 100 g abgetropft · gelesen 2026-10-02")
    }

    @Test("A discontinued product still computes, and is no longer suggested")
    func discontinued() throws {
        let catalog = Self.products.catalog
        #expect(catalog.ingredient(for: "Probe Haferdrink")?.product?.isDiscontinued == true)
        #expect(!catalog.suggestions(for: "Probe").contains { $0.name == "Probe Haferdrink" })
        #expect(catalog.suggestions(for: "Probe").contains { $0.name == "Probe Vegane Butter" })
        #expect(Self.aggregate("200 g Probe Haferdrink").total.kcal == 90)
    }

    @Test("A product without label values counts like its generic word, as an estimate")
    func productLikeAGenericWord() throws {
        let margarine = try #require(
            Self.products.nutrition.nutrition(forCanonicalName: "Margarine")?.basis(for: .unspecified)
        )
        let estimate = try #require(
            Self.products.nutrition.nutrition(forCanonicalName: "Beispiel Vegane Butter")?.basis(for: .unspecified)
        )
        #expect(estimate.values == margarine.values)
        #expect(estimate.estimatedLike == "Margarine")
        #expect(Self.products.catalog.ingredient(for: "Beispiel Vegane Butter")?.product?.like == "margarine")

        let line = try #require(Self.aggregate("100 g Beispiel Vegane Butter").coverage.contributions.first)
        #expect(line.estimatedLike == "Margarine")
        #expect(line.inheritedFrom == nil)
    }

    @Test("A product with neither label nor `like` is known, and not computed")
    func productWithoutValues() {
        let report = Self.aggregate("100 g Leer Vegane Butter")
        #expect(Self.products.catalog.ingredient(for: "Leer Vegane Butter")?.product?.brand == "Leer")
        #expect(report.total.kcal == 0)
        #expect(report.coverage.gaps.map(\.reason) == [.noNutritionValues])
        #expect(!report.coverage.isComplete)
    }

    @Test("EAN check digits")
    func eanCheckDigits() {
        #expect(CatalogProduct.isValidEAN("4006381333931"))
        #expect(CatalogProduct.isValidEAN("0012345678905"))
        #expect(CatalogProduct.isValidEAN("96385074"))
        #expect(!CatalogProduct.isValidEAN("4006381333932"))
        #expect(!CatalogProduct.isValidEAN("400638133393"))
        #expect(!CatalogProduct.isValidEAN("40063813339a1"))
    }

    // MARK: - Coverage per nutrient

    @Test("A label without vitamins leaves the NRF score undeterminable where it carries the energy")
    func nrfNeedsItsNutrients() throws {
        let heavy = Self.aggregate("100 g Testmarke Vegane Butter\n500 g Karotte").coverage
        #expect(heavy.isComplete)
        #expect(!heavy.nrfIsDeterminable)
        #expect(heavy.nrfUncovered.contains(.vitaminCMg))
        #expect(!heavy.nrfUncovered.contains(.proteinG))
        #expect(heavy.lines(lacking: .vitaminCMg).map(\.ingredientName) == ["Testmarke Vegane Butter"])
        let butterEnergy = try #require(heavy.contributions.first { $0.ingredientName == "Testmarke Vegane Butter" }).energy
        let total = heavy.contributions.reduce(0) { $0 + $1.energy }
        #expect(abs(heavy.share(of: .vitaminCMg) - (1 - butterEnergy / total)) < 1e-9)

        // A knob of it in a pot of carrots is under the tenth of the energy
        // the score can do without.
        let light = Self.aggregate("3 g Testmarke Vegane Butter\n1000 g Karotte").coverage
        #expect(light.share(of: .vitaminCMg) > NutritionCoverage.minimumNutrientShare)
        #expect(light.nrfUncovered.allSatisfy { nutrient in
            light.lines(lacking: nutrient).allSatisfy { $0.ingredientName != "Testmarke Vegane Butter" }
        })
    }

    @Test("ballaststoffreich needs fibre stated for the dish, not only enough of it")
    func fibreTagNeedsFibreStated() {
        func nutrition(fiberAbsentEnergy: Double) -> RecipeNutrition {
            var perPortion = NutritionInfo.zero
            perPortion.kcal = 400
            perPortion.fiberG = 20
            let stated = NutritionCoverage.Contribution(ingredientName: "Linsen", energy: 400 - fiberAbsentEnergy)
            let label = NutritionCoverage.Contribution(
                ingredientName: "Testmarke Vegane Butter", energy: fiberAbsentEnergy, absent: [.fiberG]
            )
            return RecipeNutrition(
                perPortion: perPortion, servings: 1, nrf93Score: 0,
                coverage: NutritionCoverage(includedCount: 2, gaps: [], contributions: [stated, label])
            )
        }
        #expect(NutritionTagging.tags(for: nutrition(fiberAbsentEnergy: 20)).map(\.kind).contains(.fiberRich))
        #expect(!NutritionTagging.tags(for: nutrition(fiberAbsentEnergy: 100)).map(\.kind).contains(.fiberRich))
    }

    @Test("A coverage cached before this phase decodes with nothing absent")
    func oldCoverageDecodes() throws {
        let json = #"{"includedCount": 1, "gaps": [], "contributions": [{"ingredientName": "Tomate"}]}"#
        let coverage = try JSONDecoder().decode(NutritionCoverage.self, from: Data(json.utf8))
        #expect(coverage.contributions.first?.energy == 0)
        #expect(coverage.contributions.first?.absent == [])
        #expect(coverage.share(of: .vitaminCMg) == 1)
    }

    // MARK: - Households

    @MainActor
    private static func libraries(
        _ answers: [LocalAnswer]
    ) throws -> (NutritionLibrary, IngredientCatalogLibrary) {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let catalog = IngredientCatalogLibrary(localAnswers: InMemoryLocalAnswerStore(answers), dataSet: products)
        let nutrition = NutritionLibrary(
            store: SwiftDataRecipeNutritionStore(modelContainer: container),
            recipeStore: SwiftDataRecipeStore(modelContainer: container),
            catalogLibrary: catalog, household: { nil }
        )
        return (nutrition, catalog)
    }

    @Test("Two households, two brands: one recipe, two figures, each with its brand")
    @MainActor
    func twoHouseholdsTwoCatalogBrands() async throws {
        let recipe = Recipe(title: "Kuchen", servings: 1, ingredientsText: "100 g vegane Butter")
        let choice = { (id: String) in LocalAnswer(name: "vegane Butter", kind: .product, targetID: id) }
        let (first, firstCatalog) = try Self.libraries([choice("testmarke-vegane-butter")])
        let (second, secondCatalog) = try Self.libraries([choice("probe-vegane-butter")])

        let one = try #require(await first.nutrition(for: recipe))
        let two = try #require(await second.nutrition(for: recipe))

        #expect(one.perPortion.kcal == 714)
        #expect(two.perPortion.kcal == 540)
        #expect(first.cacheContext != second.cacheContext)
        // The brand, not the product's whole name, beside the written word.
        #expect(firstCatalog.brand(for: "vegane Butter") == "Testmarke")
        #expect(secondCatalog.brand(for: "vegane Butter") == "Probe")
        // The label's gaps reach the recipe: no letter from a sum of it.
        #expect(one.coverage.isComplete)
        #expect(!one.coverage.nrfIsDeterminable)
    }

    @Test("A household's choice of a product without a label computes the estimate, under its brand")
    @MainActor
    func householdChoosesAnEstimatedProduct() async throws {
        let margarine = try #require(
            Self.products.nutrition.nutrition(forCanonicalName: "Margarine")?.basis(for: .unspecified)
        )
        let (nutrition, catalog) = try Self.libraries([
            LocalAnswer(name: "vegane Butter", kind: .product, targetID: "beispiel-vegane-butter"),
        ])
        let result = try #require(await nutrition.nutrition(
            for: Recipe(title: "Kuchen", servings: 1, ingredientsText: "100 g vegane Butter")
        ))
        #expect(abs(result.perPortion.kcal - margarine.values.kcal) < 1e-9)
        #expect(result.coverage.contributions.first?.estimatedLike == "Margarine")
        #expect(catalog.brand(for: "vegane Butter") == "Beispiel")
    }

    @Test("A local product's own values keep what its label leaves out absent")
    @MainActor
    func localProductStaysHonest() async throws {
        let values = NutritionInfo.label(
            kcal: 700, proteinG: 0, fatG: 78, saturatedFatG: 30, carbsG: 1, sugarG: 1, fiberG: nil, saltG: 1
        )
        let (nutrition, catalog) = try Self.libraries([
            LocalAnswer(name: "vegane Butter", kind: .product, values: values, brand: "Hausmarke", ean: "4006381333931"),
        ])
        let result = try #require(await nutrition.nutrition(
            for: Recipe(title: "Kuchen", servings: 1, ingredientsText: "100 g vegane Butter")
        ))
        #expect(result.perPortion.kcal == 700)
        #expect(result.coverage.share(of: .fiberG) == 0)
        #expect(catalog.brand(for: "vegane Butter") == "Hausmarke")
    }
}
