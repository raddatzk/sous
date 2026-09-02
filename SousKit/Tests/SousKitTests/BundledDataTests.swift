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

    @Test("The bundled files load, and the vocabulary is the kitchen's size")
    func filesLoad() {
        #expect(bls.entries.count > 3000)
        // The two lists are kept apart: the table has thousands of rows, the
        // kitchen a few hundred words. When these two numbers approached each
        // other the app was offering a food table's vocabulary to a cook.
        #expect(KitchenWords.bundled.words.count > 250)
        #expect(KitchenWords.bundled.words.count < 1000)
        #expect(synonyms.entries.count == KitchenWords.bundled.words.count)
        #expect(!IngredientCuration.bundled.words.isEmpty)
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

    @Test("A different fruit is not a spelling of its neighbour")
    func lookalikeFruitsStayApart() throws {
        // Clementine, Nektarine and Zwetschge used to sit in the alias lists
        // of Mandarine, Pfirsich and Pflaume — so "Clementinen" quietly got
        // mandarin values although BLS carries the clementine as its own row.
        // They were also the only source of overlay conflicts: a word and its
        // own spelling fighting over one state. Both wrongs undo together.
        for (variety, neighbour) in [
            ("Clementine", "Mandarine"),
            ("Nektarine", "Pfirsich"),
            ("Zwetschge", "Pflaume"),
        ] {
            let word = try #require(synonyms.entry(for: variety))
            #expect(word.word == variety, "\(variety) resolves into \(word.word)")
            let own = try #require(word.target(for: .raw) ?? word.target(for: .unspecified))
            let other = try #require(synonyms.entry(for: neighbour))
            #expect(!other.targets.map(\.code).contains(own.code))
        }
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
        let density = try #require(measures.density(forIngredient: "Olivenöl"))
        #expect(density > 0.85 && density < 0.95)
        // …and it reaches the table the app computes against, which is the
        // half that used to be missing: `NutritionCatalog.make` hardcoded
        // `densityGramsPerMl: nil` and threw every one of these away.
        let entry = try #require(NutritionCatalog.bundled.nutrition(forCanonicalName: "Olivenöl"))
        #expect(entry.densityGramsPerMl == density)
    }

    @Test("Leinöl reaches its own BLS row, under both of its names")
    func linseedOilIsInTheKitchensList() throws {
        // A word the kitchen uses and the table has: the mapping is the only
        // thing between the two, and without it the app answers "nicht im
        // Katalog" for a bottle the BLS has analysed.
        let oil = try #require(synonyms.entry(for: "Leinsamenöl"))
        #expect(oil.word == "Leinöl")
        #expect(oil.category == .oils)
        let target = try #require(oil.target(for: .unspecified))
        let row = try #require(bls.entry(for: target.code))
        #expect(row.name == "Leinöl")
        // No density of its own — group Q answers a spoonful of it, which is
        // the point of the per-group row.
        let entry = try #require(NutritionCatalog.bundled.nutrition(forCanonicalName: "Leinöl"))
        #expect(entry.densityGramsPerMl == measures.density(forGroup: "Q"))
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

    @Test("The cup is a measure-table entry, not a volume")
    func theCupGoesThroughTheTable() throws {
        // "Tasse" is `.imprecise` on purpose — what a cup holds depends on
        // what is in it — so it is answered by weights, per ingredient first
        // and per food group after. Nothing pinned this before.
        #expect(measures.genericGrams(forUnit: IngredientUnit.cup.symbol) == 150)
        #expect(measures.grams(forIngredient: "Mehl")[IngredientUnit.cup.symbol] == 120)
        let flour = try #require(NutritionCatalog.bundled.nutrition(forCanonicalName: "Mehl"))
        #expect(flour.unitWeightsGrams[IngredientUnit.cup.symbol] == 120)
    }

    @Test("Only units that convert to no volume are answered by weight")
    func groupWeightsCoverOnlyUnconvertibleUnits() {
        // Phase 5's decision, pinned in the data: a unit with a volume factor
        // (ml, l, TL, EL) goes through a density, so a `byGroup` row naming
        // one would be a second, contradicting answer. There were four.
        for entry in measures.byGroup {
            #expect(
                IngredientUnit(symbol: entry.unit).baseUnitFactor == nil,
                "\(entry.group)/\(entry.unit) has a volume factor and belongs in a density"
            )
        }
        #expect(measures.grams(forGroup: "C")[IngredientUnit.cup.symbol] == 120)
        #expect(measures.grams(forGroup: "R")[IngredientUnit.pinch.symbol] == 0.4)
    }

    @Test("Every measure row names something the vocabulary knows")
    func everyMeasureRowIsReachable() {
        // A row nobody can reach is curation that silently does nothing —
        // which is what "Suppengrün" and four densities were, because the
        // build only ever looks a measure up by a synonym word or one of its
        // spellings.
        var spellings = Set<String>()
        for entry in synonyms.entries {
            for spelling in [entry.word] + entry.aliases {
                spellings.insert(IngredientCatalog.normalize(spelling))
            }
        }
        var unreachable: [String] = []
        for entry in measures.byIngredient
        where !spellings.contains(IngredientCatalog.normalize(entry.name)) {
            unreachable.append("\(entry.name) (\(entry.unit))")
        }
        for entry in measures.densities {
            guard let name = entry.name else { continue }
            if !spellings.contains(IngredientCatalog.normalize(name)) {
                unreachable.append("\(name) (Dichte)")
            }
        }
        #expect(unreachable.isEmpty, "\(unreachable)")
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

    @Test("The words that carry identity without values still do — and now say so")
    func spicesStayIdentityOnly() throws {
        // These resolve an ingredient but have no defensible BLS row. That is
        // the difference between "nicht im Katalog" and "keine Nährwerte
        // hinterlegt", and the app leans on it for the gap reason it reports.
        //
        // What changed with decision D: such a word no longer arrives as an
        // *absence* in the nutrition catalog - it arrives as an answer. It
        // still has no target, but it has an entry, and that entry's basis
        // is the settled "bewusst ohne", which is what stops it counting as a
        // defect and stops the picker offering it breakfast cereal.
        //
        // Chili left this list on the same day: the fresh chilli is in the
        // table as "Pfefferschote", and is curated - see
        // ``chiliIsCuratedRatherThanDeclaredMissing``.
        for word in ["Kurkuma", "Zimt", "Cayennepfeffer"] {
            let entry = try #require(synonyms.entry(for: word), "\(word) is missing")
            #expect(entry.targets.isEmpty, "\(word) suddenly has values")
            #expect(entry.hasNoValues, "\(word) has no values and does not say so")
            #expect(IngredientCatalog.bundled.ingredient(for: word) != nil)
            let basis = NutritionCatalog.bundled.nutrition(forCanonicalName: word)?.basis(for: .unspecified)
            #expect(basis?.status == .deliberatelyWithout, "\(word) should arrive answered, not empty")
            #expect(basis?.contributes == false)
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

    @Test("The kitchen's list is written in the kitchen's language")
    func theVocabularyReadsLikeACook() {
        // This is the whole point of keeping the two lists apart, stated as a
        // rule: a cook writes "Schmand", not "Sauerrahm/Schmand, mind. 20 %
        // Fett", and every one of those names used to sit in the list the
        // editor offered while typing. A comma or a bracket in a word here
        // means a food table's name has leaked back in.
        let tableSpeak = KitchenWords.bundled.words
            .map(\.name)
            .filter { $0.contains(",") || $0.contains("(") }
        #expect(tableSpeak.isEmpty, "\(tableSpeak)")

        // The table's own name is still reachable — by looking it up, which
        // is a different act from being offered it.
        #expect(bls.entries.contains { $0.name.contains(",") })
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
        // Spelled out rather than read off `bundledDataResources`: comparing
        // the list against itself would pass however short it got.
        #expect(sizes.count == 6)
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
        // `community.json` hides inside `BLSCatalog.entries`, so the check
        // above would pass on an app that never opened it. Its own source
        // block is the thing only that file can produce.
        #expect(BLSCatalog.bundled.supplementSource != nil)
    }
}

/// The rows that are not BLS.
///
/// `community.json` is the one file of shipped food rows a person edits
/// directly — no pipeline writes it, no spreadsheet backs it. That makes it
/// both the easiest file to contribute to and the easiest to get wrong, and
/// these are the four ways it can be wrong that nothing else would catch.
@Suite("Bundled supplements")
struct BundledSupplementTests {
    private let bls = BLSCatalog.bundled
    private let synonyms = SynonymTable.bundled

    private var supplements: [BLSEntry] { bls.entries.filter { $0.group == "Z" } }

    @Test("Every supplement names the body that measured it")
    func everySupplementCitesItsSource() throws {
        #expect(!supplements.isEmpty)
        for entry in supplements {
            // The per-row half of CC BY. A supplements file has no single
            // attribution to fall back on — that is the whole difference
            // between it and `bls.json`.
            let source = try #require(entry.source, "\(entry.code) \(entry.name) has no source")
            #expect(!source.isEmpty)
        }
        let stated = try #require(bls.supplementSource)
        #expect(stated.license == "CC BY 4.0")
        #expect(stated.attribution.contains("Ciqual"))
    }

    @Test("A supplement can never take a code the catalog already uses")
    func codesCannotCollide() {
        // Z is a letter the BLS has never issued: 3.0 and 4.0 both run B–Y.
        // That is what makes the space safe to allocate in, and it is worth a
        // test because the day it stops being true is the day a cook's
        // confirmed basis silently starts meaning a different food.
        for entry in supplements {
            #expect(entry.code.hasPrefix("Z"))
        }
        let blsCodes = Set(bls.entries.filter { $0.group != "Z" }.map(\.code))
        for entry in supplements {
            #expect(!blsCodes.contains(entry.code))
        }
    }

    @Test("A supplement's name never becomes a kitchen word of its own")
    func supplementNamesStayOutOfTheCatalog() {
        // They are named in whatever language their source publishes in, so
        // letting the builder turn one into a word would put "Nutritional
        // yeast" into a German catalog. The bridge is curated, like every
        // other one across the two languages.
        let words = Set(synonyms.entries.map { IngredientCatalog.normalize($0.word) })
        for entry in supplements {
            #expect(!words.contains(IngredientCatalog.normalize(entry.name)))
        }
    }

    @Test("Hefeflocken rest on the supplement, not on the baker's yeast")
    func yeastFlakesRestOnTheSupplement() throws {
        // The case the file was created for, and a case worth stating
        // precisely: Trockenbackhefe agrees with nutritional yeast on energy
        // and protein to the decimal (334 kcal, 40.4 g) and parts company on
        // the minerals — 150 vs 54 mg magnesium, 1700 vs 955 mg potassium,
        // 4.1 vs 9.1 mg iron. Close enough that resolving to it would look
        // right on the figure a recipe shows, and wrong everywhere the app
        // computes a verdict from it.
        let word = try #require(synonyms.entry(for: "Hefeflocken"))
        let target = try #require(word.target(for: .unspecified))
        let row = try #require(bls.entry(for: target.code))
        #expect(row.group == "Z")
        #expect(row.name == "Nutritional yeast")
        #expect(try #require(row.source).contains("Ciqual"))
        // Reachable by the word a cook writes, which is the only reason the
        // row is in the app at all.
        #expect(synonyms.entry(for: "Nährhefe")?.word == "Hefeflocken")
        // And still told apart from the yeast you bake with.
        #expect(synonyms.entry(for: "Trockenhefe")?.word != "Hefeflocken")
    }

    @Test("No supplement sits in the catalog that no kitchen word can reach")
    func everySupplementIsReachable() {
        // The rule that makes the language question moot. `BLSCatalog.search`
        // matches on the row's own name, so a row called "Nutritional yeast"
        // is invisible to anyone typing German — searching for "Hefeflocken"
        // returns nothing at all. A supplement is therefore only ever added
        // *because* a kitchen word needs it, and the word is what a cook
        // actually reaches it by; a row nothing points at would be curation
        // that silently does nothing, the same failure `measures.json` rows
        // are held to.
        let reachable = Set(
            synonyms.entries
                .flatMap { $0.targets.map(\.code) + $0.candidates }
        )
        for entry in supplements {
            #expect(
                reachable.contains(entry.code),
                "\(entry.code) \(entry.name) is in community.json but no kitchen word names it"
            )
        }
    }

    @Test("The citation reaches the ingredient, not just the file")
    func sourceReachesTheIngredient() throws {
        // „Quelle: …" under the ingredient is where CC BY is actually
        // discharged for a supplement — the sources screen names the bodies,
        // this names the row. A word resting on a supplement must not be
        // shown as resting on the BLS.
        let catalog = NutritionCatalog.make(
            synonyms: synonyms, bls: bls, measures: MeasureTable.bundled
        )
        let flakes = try #require(catalog.nutrition(forCanonicalName: "Hefeflocken"))
        #expect(flakes.source.contains("Ciqual"))
        #expect(try #require(flakes.basis(for: IngredientState.unspecified)).source.contains("Ciqual"))
        // The other 2,737 words are unaffected and still say what they said.
        let onion = try #require(catalog.nutrition(forCanonicalName: "Zwiebel"))
        #expect(onion.source == bls.source.datasetVersion)
    }
}

/// The slash in a BLS name.
///
/// BLS writes synonyms as `"Batate/Süßkartoffel"`, and the whole string used
/// to be one word — so 329 perfectly ordinary names resolved to nothing at
/// all while sitting in the table. Splitting them is worth these five checks
/// because a wrong split does not fail loudly: it invents a word, or hands
/// one food's numbers to another.
@Suite("The two lists and what links them")
struct ListSeparationTests {
    private let kitchen = KitchenWords.bundled
    private let curation = IngredientCuration.bundled
    private let bls = BLSCatalog.bundled

    /// These replace a suite that guarded the *merge*: that a BLS row name
    /// still resolved, that a slashed name reached its row, that no second
    /// word stood beside the one already meaning it. All of those were
    /// questions about one vocabulary built from two sources. There is no
    /// such vocabulary now — the kitchen's list is offered, the table is
    /// looked up, and what needs guarding is that the link between them holds.

    @Test("Every word the link names is a word the kitchen has")
    func curationNamesOnlyKitchenWords() {
        let known = Set(kitchen.words.map(\.name))
        let strays = curation.words.keys.filter { !known.contains($0) }.sorted()
        #expect(strays.isEmpty, "\(strays)")
    }

    @Test("Every code the link names is a row that exists")
    func curationPointsAtRealRows() {
        var dangling: [String] = []
        for (word, entry) in curation.words {
            for code in entry.targets.values.flatMap({ $0 }) + entry.candidates
            where bls.entry(for: code) == nil {
                dangling.append("\(word) → \(code)")
            }
        }
        #expect(dangling.isEmpty, "\(dangling)")
    }

    @Test("Every state the link names is one the app knows")
    func curationNamesRealStates() {
        let states = Set(curation.words.values.flatMap(\.targets.keys))
        let unknown = states.filter { IngredientState(rawValue: $0) == nil }.sorted()
        #expect(unknown.isEmpty, "\(unknown)")
    }

    @Test("A variety names a parent the kitchen also has")
    func parentsAreKitchenWords() {
        let known = Set(kitchen.words.map(\.name))
        let orphans = kitchen.words.compactMap(\.parent).filter { !known.contains($0) }.sorted()
        #expect(orphans.isEmpty, "\(orphans)")
    }

    @Test("No two kitchen words answer to the same spelling")
    func spellingsAreUnique() {
        var owner: [String: String] = [:]
        var collisions: [String] = []
        for word in kitchen.words {
            for spelling in [word.name] + word.aliases {
                let key = IngredientCatalog.normalize(spelling)
                if let taken = owner[key], taken != word.name {
                    collisions.append("\(spelling): \(taken) / \(word.name)")
                }
                owner[key] = word.name
            }
        }
        #expect(collisions.isEmpty, "\(collisions)")
    }

    @Test("A word carrying no values is one nobody wrote a link for")
    func wordsWithoutValuesAreDeliberate() {
        // The spices and the varieties: known ingredients whose gap has a
        // name. The rule is that the gap is always a *missing link*, never a
        // link that points nowhere — the two look the same on screen and are
        // not the same mistake.
        for word in kitchen.words where curation.entry(for: word.name) == nil {
            #expect(SynonymTable.bundled.entry(for: word.name)?.targets.isEmpty == true)
        }
    }

    @Test("A word without a basis has either an answer or a reason to be asked")
    func everyEmptyWordIsAccountedFor() {
        // Decision D's rule, and the thing that keeps it from becoming a
        // dumping ground: a word may carry no values only if it *says* so,
        // with the reasoning written down where the next curator will read
        // it. Silence is what this forbids.
        let table = SynonymTable.bundled
        for word in kitchen.words {
            guard let entry = table.entry(for: word.name), entry.targets.isEmpty else { continue }
            // A variety inherits from its parent and needs nothing of its own.
            if word.parent != nil { continue }
            #expect(entry.hasNoValues, "\(word.name) has no basis and does not say why")
            let via = curation.entry(for: word.name)?.via ?? ""
            #expect(via.count > 20, "\(word.name) is marked without values but gives no reason")
        }
    }

    @Test("A word that says it has no values proposes nothing")
    func settledWordsOfferNoCandidates() {
        // The Zimt case. The BLS has no cinnamon, so every route that guesses
        // at what the word might mean was reaching for whatever the name
        // search scraped up - breakfast cereal at 424 kcal, offered as if it
        // were an answer. A settled word has no question left to fill.
        let zimt = SynonymTable.bundled.entry(for: "Zimt")
        #expect(zimt?.hasNoValues == true)
        #expect(zimt?.candidateCodes.isEmpty == true)
        let basis = NutritionCatalog.bundled.nutrition(forCanonicalName: "Zimt")?
            .basis(for: .unspecified)
        #expect(basis?.status == .deliberatelyWithout)
    }

    @Test("Chili is in the source, under a word no kitchen writes")
    func chiliIsCuratedRatherThanDeclaredMissing() {
        // Found while marking the spices, and the reason that pass was worth
        // making by hand: the fresh chilli *is* in the table, filed as
        // "Pfefferschote". No cook writes that, so neither the name search nor
        // any proposal ever reached it, and it was one keystroke away from
        // being declared absent along with the real gaps.
        let chili = SynonymTable.bundled.entry(for: "Chili")
        #expect(chili?.hasNoValues == false)
        let raw = chili?.target(for: .raw)
        #expect(raw?.code == "G554100")
        #expect(BLSCatalog.bundled.entry(for: "G554100")?.name.contains("Pfefferschote") == true)
    }

    @Test("The three varieties whose inheritance was worst carry their own row")
    func theWorstInheritancesAreCurated() throws {
        // The head start for inheritance-as-proposal (catalog plan, phase 3):
        // without these, the three cases that argued for the whole change
        // would arrive as questions the cook has to answer for the app.
        let table = SynonymTable.bundled
        let bls = BLSCatalog.bundled
        #expect(table.entry(for: "Räucherlachs")?.target(for: .unspecified)?.code == "T410600")
        #expect(bls.entry(for: "T410600")?.perHundredGrams.sodiumMg ?? 0 > 1000)
        #expect(table.entry(for: "Trockenhefe")?.target(for: .unspecified)?.code == "R458000")
        #expect(bls.entry(for: "R458000")?.perHundredGrams.kcal ?? 0 > 300)
        #expect(table.entry(for: "Staudensellerie")?.target(for: .raw)?.code == "G220100")
        #expect(bls.entry(for: "G220100")?.name.contains("Bleichsellerie") == true)
    }

    @Test("A root word carries a category; a variety inherits one")
    func categoriesAreWrittenOnceUpTheChain() {
        // Decision B, held in the data: a variety writes a category only to
        // differ from its parent, and today none does. A root word has
        // nothing to inherit from and must say what it is.
        let byName = Dictionary(kitchen.words.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for word in kitchen.words {
            if word.parent == nil {
                #expect(word.category != nil, "\(word.name) is a root word without a category")
            } else if let own = word.category, let parent = word.parent.flatMap({ byName[$0] }) {
                #expect(own != parent.category, "\(word.name) repeats its parent's category")
            }
        }
        // And every word resolves to *something*: the chain never ends in
        // .other for a shipped word.
        for ingredient in IngredientCatalog.bundled.ingredients {
            #expect(ingredient.category != .other || ingredient.ownCategory == .other, "\(ingredient.name) fell through to .other")
        }
    }

    @Test("Cocktailtomate is a vegetable because Tomate is")
    func varietyResolvesToParentCategory() throws {
        let variety = try #require(IngredientCatalog.bundled.ingredient(for: "Cocktailtomate"))
        #expect(variety.ownCategory == nil)
        #expect(variety.category == .vegetables)
        #expect(kitchen.words.first { $0.name == "Cocktailtomate" }?.category == nil)
    }

    @Test("The table's own names are not in the kitchen's list")
    func theTableStaysOutOfTheVocabulary() {
        // Sampled rather than exhaustive: plenty of BLS rows are named exactly
        // as a cook would say it, and those belong in both. What must not
        // happen is the food table's phrasing turning up as a suggestion.
        let known = Set(kitchen.words.map { IngredientCatalog.normalize($0.name) })
        for name in [
            "Speisezwiebel tiefgefroren, geschmort ohne Fett",
            "Sauerrahm/Schmand, mind. 20 % Fett",
            "Kürbis Hokkaido (C. maxima)",
            "Fleischsalat-Grundmasse",
        ] {
            #expect(!known.contains(IngredientCatalog.normalize(name)), "\(name)")
        }
    }
}
