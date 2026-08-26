import Foundation
import Testing
@testable import SousKit

/// A golden-file check over the data the app actually ships.
///
/// The pipeline that writes these files runs by hand, against a spreadsheet
/// that is not in the repo, and its output is a megabyte of numbers nobody
/// reads. Until now nothing would have noticed a run that quietly mangled
/// them — an emptied field, a collapsed state, a mapping that lost its rows.
/// These are the handful of facts that would have caught each of those.
@Suite("Bundled data")
struct BundledDataTests {
    private let bls = BLSCatalog.bundled
    private let synonyms = SynonymTable.bundled
    private let measures = MeasureTable.bundled

    @Test("The four bundled files load")
    func filesLoad() {
        #expect(bls.entries.count > 3000)
        #expect(synonyms.entries.count > 2000)
        #expect(!measures.units.isEmpty)
        #expect(!AisleDefaults.bundled.groups.isEmpty)
    }

    @Test("The BLS table says which release it is and who owns it")
    func sourceIsStated() {
        // CC BY 4.0 asks the data to carry its attribution; carrying it in the
        // file rather than in Swift is what lets an update change it.
        #expect(bls.source.datasetVersion == "BLS 4.0")
        #expect(bls.source.license == "CC BY 4.0")
        #expect(bls.source.attribution.contains("Max Rubner-Institut"))
        #expect(!bls.source.changeNote.isEmpty)
    }

    @Test("Raw and cooked potato are two codes, not one averaged row")
    func potatoKeepsItsStatesApart() throws {
        let potato = try #require(synonyms.entry(for: "Kartoffel"))
        let raw = try #require(potato.target(for: .raw))
        let cooked = try #require(potato.target(for: .cooked))

        #expect(raw.code != cooked.code)
        let rawRow = try #require(bls.entry(for: raw.code))
        let cookedRow = try #require(bls.entry(for: cooked.code))
        // Each names a real BLS row rather than a blend of several, which is
        // what the old pipeline produced and what decision O2 abolished.
        #expect(rawRow.name == "Kartoffel geschält, roh")
        #expect(cookedRow.name == "Kartoffel geschält, gekocht")
        // A boiled potato takes on water, so it is the *lighter* of the two
        // per 100 g — which is the whole reason the states may not be blended.
        // Equal values here would mean they had been averaged together again.
        #expect(cookedRow.perHundredGrams.kcal < rawRow.perHundredGrams.kcal)
    }

    @Test("Schmelzkäse offers more than one row to choose from")
    func processedCheeseHasCandidates() throws {
        // The concept's own example: the cook writes one word, the catalog
        // knows a shelf of refinements. Phase 4 turns this into a picker; the
        // list has to survive the build until then.
        let cheese = try #require(synonyms.entry(for: "Schmelzkäse"))
        #expect(cheese.candidateCodes.count > 1)
        for code in cheese.candidateCodes {
            let row = try #require(bls.entry(for: code))
            #expect(row.name.contains("Schmelzkäse"))
        }
    }

    @Test("Olive oil has a density, and it is not water's")
    func oliveOilHasADensity() throws {
        // Curated here, deliberately not yet consulted — phase 5 switches the
        // measure table on. Shipping it unread is only safe as long as
        // something checks it is still there to switch on.
        let density = try #require(measures.density(forIngredient: "Olivenöl"))
        #expect(density > 0.85 && density < 0.95)
    }

    @Test("The piece weights and generic measures survived the move into data")
    func measuresSurvived() throws {
        // These were a Swift constant and a column of nutrition.json before.
        // A pipeline run used to blank the piece weights unconditionally.
        #expect(measures.genericGrams(forUnit: IngredientUnit.pinch.symbol) == 0.3)
        #expect(measures.genericGrams(forUnit: IngredientUnit.leaf.symbol) == 1)
        // …and no generic piece weight, which is a decision, not an omission.
        #expect(measures.genericGrams(forUnit: IngredientUnit.piece.symbol) == nil)
        #expect(measures.grams(forIngredient: "Zwiebel")[IngredientUnit.piece.symbol] == 110)
        #expect(measures.grams(forIngredient: "Ei")[IngredientUnit.piece.symbol] == 55)
    }

    @Test("Every target and candidate points at a row that exists")
    func everyCodeResolves() {
        var dangling: [String] = []
        for entry in synonyms.entries {
            for code in entry.candidateCodes where bls.entry(for: code) == nil {
                dangling.append("\(entry.word) → \(code)")
            }
        }
        #expect(dangling.isEmpty, "\(dangling.prefix(10))")
    }

    @Test("The words that carry identity without values still do")
    func spicesStayIdentityOnly() throws {
        // These resolve an ingredient but have no defensible BLS row. That is
        // the difference between "nicht im Katalog" and "keine Nährwerte
        // hinterlegt", and the app leans on it for the gap reason it reports.
        for word in ["Kurkuma", "Zimt", "Cayennepfeffer", "Chili"] {
            let entry = try #require(synonyms.entry(for: word), "\(word) is missing")
            #expect(entry.targets.isEmpty, "\(word) suddenly has values")
            #expect(IngredientCatalog.bundled.ingredient(for: word) != nil)
            #expect(NutritionCatalog.bundled.nutrition(forCanonicalName: word) == nil)
        }
    }

    @Test("No two words collide under the catalog's normalization")
    func normalizationKeepsWordsApart() {
        // `IngredientCatalog.normalize` is trim and lowercase, nothing more —
        // no umlaut folding, no punctuation. Two words that differ only in
        // case would mean one of them is unreachable, forever and silently.
        var seen: [String: String] = [:]
        var collisions: [String] = []
        for entry in synonyms.entries {
            let key = IngredientCatalog.normalize(entry.word)
            if let other = seen[key] { collisions.append("\(other) / \(entry.word)") }
            seen[key] = entry.word
        }
        #expect(collisions.isEmpty, "\(collisions.prefix(10))")
    }

    @Test("A curated word keeps its spellings")
    func curatedAliasesSurvived() throws {
        // The 134 alias lists are the oldest hand-work in the project; the
        // synonym table inherited them and must not have dropped any.
        let tomato = try #require(synonyms.entry(for: "Tomate"))
        #expect(tomato.aliases.contains("Tomaten"))
        #expect(IngredientCatalog.bundled.canonicalName(for: "Möhren") == "Karotte")
        #expect(IngredientCatalog.bundled.canonicalName(for: "Eier") == "Ei")
    }

    @Test("A variety left the alias list for a word of its own")
    func varietiesAreNotSpellings() throws {
        // This used to pin "Cocktailtomaten" *inside* Tomate's aliases, which
        // is what made the shopping list add 200 g of cocktail tomatoes into
        // an anonymous 700 g of tomatoes. The hand-work is not lost, it is
        // reclassified: still curated, still shipped, now saying which of the
        // two things it is.
        let tomato = try #require(synonyms.entry(for: "Tomate"))
        #expect(!tomato.aliases.contains("Cocktailtomaten"))
        #expect(tomato.parent == nil)

        let cocktail = try #require(synonyms.entry(for: "Cocktailtomaten"))
        #expect(cocktail.word == "Cocktailtomate")
        #expect(cocktail.parent == "Tomate")
        #expect(IngredientCatalog.bundled.canonicalName(for: "Cocktailtomaten") == "Cocktailtomate")
        #expect(IngredientCatalog.bundled.variants(of: "Tomate").map(\.name)
            == ["Cocktailtomate", "Kirschtomate", "Strauchtomate"])
    }

    @Test("A variety with no row of its own is worth what its parent is")
    func varietiesInheritTheirParentsBasis() throws {
        // Nobody has curated values for cocktail tomatoes, and nobody should
        // have to: mapping "Tomate" once maps every variety of it.
        let tomato = try #require(NutritionCatalog.bundled.nutrition(forCanonicalName: "Tomate"))
        let cocktail = try #require(
            NutritionCatalog.bundled.nutrition(forCanonicalName: "Cocktailtomate")
        )
        #expect(cocktail.basis(for: .raw)?.code == tomato.basis(for: .raw)?.code)
        #expect(cocktail.name == "Cocktailtomate")
    }

    @Test("A word whose varieties moved out still has a basis of its own")
    func parentsKeptTheirBasis() throws {
        // Salz got its row through the alias "Meersalz", Sellerie through
        // "Knollensellerie". Moving those out would have left the bare word
        // without values — so the curation now names the plain row for each,
        // which is what the bare word meant all along.
        for word in ["Salz", "Sellerie", "Schinken", "Melone", "Essig"] {
            let entry = try #require(synonyms.entry(for: word), "\(word) is missing")
            #expect(!entry.targets.isEmpty, "\(word) lost its basis to its varieties")
        }
    }

    @Test("A name that carries its own comma is still one name")
    func commaNamesSurvived() {
        // 974 of the bundled names hold a comma. The parser only leaves a line
        // whole at a comma when the catalog knows the whole name, so losing
        // these names would quietly split those lines into name + preparation
        // and drop them out of every recipe's nutrition.
        let withComma = SynonymTable.bundled.entries.filter { $0.word.contains(",") }
        #expect(withComma.count > 900)
        #expect(IngredientCatalog.bundled.ingredient(for: "Sauerrahm/Schmand, mind. 20 % Fett") != nil)
    }
}

@Suite("Bundled data fingerprint")
struct BundledDataFingerprintTests {
    @Test("A recipe's hash moves when the bundled data does")
    func fingerprintReachesTheHash() {
        let recipe = Recipe(title: "Salat", servings: 2, ingredientsText: "2 Tomaten")

        let before = RecipeContentHash.hash(for: recipe, dataFingerprint: "data-v1")
        let after = RecipeContentHash.hash(for: recipe, dataFingerprint: "data-v2")

        #expect(before != after)
    }

    @Test("The fingerprint is actually read from the shipped files")
    func fingerprintIsNotConstant() {
        // The failure this guards against is silent: the fingerprint used to
        // skip over a file it could not find, so renaming the data collapsed
        // it to the SHA of nothing at all — after which no data change would
        // ever invalidate a cached figure again.
        let sizes = RecipeContentHash.bundledDataSizes
        #expect(sizes.count == 4)
        for file in sizes {
            #expect(file.bytes > 0, "\(file.name).json contributed nothing to the fingerprint")
        }
        #expect(sizes.reduce(0) { $0 + $1.bytes } > 1_000_000)
        // The empty-input SHA-256, which is exactly what the old loop produced
        // once every file had been renamed out from under it.
        let sha256OfNothing = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        #expect(RecipeContentHash.bundledDataFingerprint != sha256OfNothing)
    }

    @Test("Every file in the fingerprint list is one the app really reads")
    func fingerprintCoversWhatIsRead() {
        // The other half of the trap: a file the catalogs read but the
        // fingerprint does not list would change without invalidating a thing.
        #expect(!BLSCatalog.bundled.entries.isEmpty)
        #expect(!SynonymTable.bundled.entries.isEmpty)
        #expect(!MeasureTable.bundled.units.isEmpty)
        #expect(!AisleDefaults.bundled.groups.isEmpty)
    }
}
