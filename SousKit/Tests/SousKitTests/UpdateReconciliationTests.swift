import Foundation
import SwiftData
import Testing
@testable import SousKit

/// What happens to the cook's decisions when the shipped data underneath them
/// is replaced — concept §7, and phase 6's whole subject.
///
/// The two worlds meet at exactly one seam: a mapping stores a *code*, and
/// the values are read through `BLSCatalog` on every read. Everything here
/// tests that seam from one side or the other — a code that still resolves
/// but points at different numbers, a code that no longer resolves, and a
/// code that resolves again after not having.
@Suite("Reconciling after a data update")
struct UpdateReconciliationTests {
    private func info(kcal: Double) -> NutritionInfo {
        NutritionInfo(
            kcal: kcal, proteinG: 0, fatG: 0, saturatedFatG: 0, carbsG: 0, sugarG: 0,
            fiberG: 0, sodiumMg: 0, vitaminAMcg: 0, vitaminCMg: 0, vitaminDMcg: 0,
            vitaminEMg: 0, calciumMg: 0, ironMg: 0, magnesiumMg: 0, potassiumMg: 0
        )
    }

    /// A shipped table of exactly the rows a test names — the "release" a run
    /// happens to be holding.
    private func bls(
        _ rows: [(code: String, name: String, kcal: Double)], version: String = "BLS 4.0"
    ) -> BLSCatalog {
        BLSCatalog(
            source: .init(
                datasetVersion: version, release: "2025", license: "CC BY 4.0",
                attribution: "Test", changeNote: "Test"
            ),
            entries: rows.map {
                BLSEntry(
                    code: $0.code, name: $0.name, group: "M", category: .other,
                    perHundredGrams: info(kcal: $0.kcal)
                )
            }
        )
    }

    private func container() throws -> ModelContainer { try .sousContainer(inMemory: true) }

    // MARK: - What a mapping remembers

    @Test("The name and the release a mapping was confirmed against survive the store")
    func stampsSurviveARoundTrip() async throws {
        let store = SwiftDataVocabularyStore(modelContainer: try container())
        try await store.save(IngredientVocabularyEntry(
            name: "Kartoffeln",
            bases: [IngredientState.cooked.rawValue: .confirmed(
                code: "K110132", catalogName: "Kartoffel geschält, gekocht",
                datasetVersion: "BLS 4.0"
            )]
        ))

        let entry = try #require(try await store.entries().first { $0.key == "kartoffeln" })
        let basis = try #require(entry.bases[IngredientState.cooked.rawValue])
        // Without these two an orphaned mapping can say only that something
        // is gone, never what — which is the half concept §7 asks for.
        #expect(basis.catalogName == "Kartoffel geschält, gekocht")
        #expect(basis.datasetVersion == "BLS 4.0")
        #expect(basis.code == "K110132")
    }

    @Test("Own values remember the row they stand in for, and which release that was")
    func ownValuesCarryTheSameStamps() async throws {
        let store = SwiftDataVocabularyStore(modelContainer: try container())
        try await store.save(IngredientVocabularyEntry(
            name: "Omas Schmalztopf",
            bases: [IngredientState.unspecified.rawValue: .ownValues(
                info(kcal: 700), code: "F123", catalogName: "Schweineschmalz",
                datasetVersion: "BLS 4.0"
            )]
        ))

        let entry = try #require(try await store.entries().first)
        let basis = try #require(entry.bases[IngredientState.unspecified.rawValue])
        #expect(basis.values?.kcal == 700)
        #expect(basis.catalogName == "Schweineschmalz")
        #expect(basis.datasetVersion == "BLS 4.0")
    }

    // MARK: - Decision D: changed values, silently

    @Test("A release that moves a number moves it without anyone being told")
    func changedValuesFlowInSilently() async throws {
        let container = try container()
        let store = SwiftDataVocabularyStore(modelContainer: container)
        try await store.save(IngredientVocabularyEntry(
            name: "Kartoffeln",
            bases: [IngredientState.unspecified.rawValue: .confirmed(
                code: "K110132", catalogName: "Kartoffel geschält, gekocht",
                datasetVersion: "BLS 4.0"
            )]
        ))

        let before = try #require(try await store.entries().first)
        let old = bls([("K110132", "Kartoffel geschält, gekocht", 70)])
        let new = bls([("K110132", "Kartoffel geschält, gekocht", 82)], version: "BLS 4.1")

        // Nothing was written between the two reads; only the table changed.
        #expect(before.bases.values.first?.basis(bls: old, source: "BLS 4.0").values.kcal == 70)
        #expect(before.bases.values.first?.basis(bls: new, source: "BLS 4.1").values.kcal == 82)

        // And decision D's other half: the reconciliation has nothing to say
        // about it. Only vanished codes are ever reported.
        let report = try await SwiftDataOrphanReconciliation(modelContainer: container).run(bls: new)
        #expect(report.orphanedNames.isEmpty)
        #expect(!report.didChangeAnything)
    }

    // MARK: - The orphan pass

    /// One word whose code survives, one whose code is gone, and one whose
    /// numbers are the cook's own and only *note* a code that is gone.
    private func storeWithOneOrphan() async throws -> ModelContainer {
        let container = try container()
        let store = SwiftDataVocabularyStore(modelContainer: container)
        try await store.save(IngredientVocabularyEntry(
            name: "Kartoffeln",
            bases: [IngredientState.unspecified.rawValue: .confirmed(
                code: "SURVIVES", catalogName: "Kartoffel geschält, gekocht",
                datasetVersion: "BLS 4.0"
            )]
        ))
        try await store.save(IngredientVocabularyEntry(
            name: "Schmelzkäse",
            bases: [IngredientState.cooked.rawValue: .confirmed(
                code: "VANISHED", catalogName: "Schmelzkäse, mind. 45 % Fett i. Tr.",
                datasetVersion: "BLS 4.0"
            )]
        ))
        try await store.save(IngredientVocabularyEntry(
            name: "Omas Schmalztopf",
            bases: [IngredientState.unspecified.rawValue: .ownValues(
                info(kcal: 700), code: "VANISHED", catalogName: "Schweineschmalz",
                datasetVersion: "BLS 4.0"
            )]
        ))
        return container
    }

    @Test("The pass marks exactly the words whose row is gone")
    func flagsExactlyTheOrphans() async throws {
        let container = try await storeWithOneOrphan()
        let table = bls([("SURVIVES", "Kartoffel geschält, gekocht", 70)])

        let report = try await SwiftDataOrphanReconciliation(modelContainer: container).run(bls: table)

        #expect(report.orphanedNames == ["Schmelzkäse"])
        #expect(report.flagged == 1)

        let flagged = try await SwiftDataVocabularyStore(modelContainer: container).entries()
            .filter(\.needsBasisReview).map(\.name)
        // Not the word whose code still resolves, and — the point of the
        // rule — not the one whose numbers are the cook's: those do not hang
        // on the BLS, so a release that drops the row takes the note, not the
        // numbers.
        #expect(flagged == ["Schmelzkäse"])
    }

    @Test("Running it a second time over the same data changes nothing")
    func secondRunIsANoOp() async throws {
        let container = try await storeWithOneOrphan()
        let table = bls([("SURVIVES", "Kartoffel geschält, gekocht", 70)])
        let pass = SwiftDataOrphanReconciliation(modelContainer: container)

        _ = try await pass.run(bls: table)
        let second = try await pass.run(bls: table)

        // Still found — the question is still open — but nothing written.
        #expect(second.orphanedNames == ["Schmelzkäse"])
        #expect(second.flagged == 0)
        #expect(!second.didChangeAnything)
    }

    @Test("A shipped table that still has everything leaves the store alone")
    func nothingOrphanedNothingWritten() async throws {
        let container = try await storeWithOneOrphan()
        let table = bls([
            ("SURVIVES", "Kartoffel geschält, gekocht", 70),
            ("VANISHED", "Schmelzkäse, mind. 45 % Fett i. Tr.", 280),
        ])

        let report = try await SwiftDataOrphanReconciliation(modelContainer: container).run(bls: table)

        #expect(report.orphanedNames.isEmpty)
        #expect(report.flagged == 0)
        let flagged = try await SwiftDataVocabularyStore(modelContainer: container).entries()
            .filter(\.needsBasisReview)
        #expect(flagged.isEmpty)
    }

    @Test("The pass finds what the share extension wrote after the update")
    func mergesRatherThanAssumingItIsFirst() async throws {
        let container = try await storeWithOneOrphan()
        let table = bls([("SURVIVES", "Kartoffel geschält, gekocht", 70)])
        let pass = SwiftDataOrphanReconciliation(modelContainer: container)
        _ = try await pass.run(bls: table)

        // The extension runs no migration and can be the first writer after
        // an update. A row it added afterwards is picked up on the next run
        // rather than being shadowed by "already reconciled".
        try await SwiftDataVocabularyStore(modelContainer: container).save(
            IngredientVocabularyEntry(
                name: "Ajvar",
                bases: [IngredientState.unspecified.rawValue: .confirmed(
                    code: "ALSO_VANISHED", catalogName: "Paprikamark",
                    datasetVersion: "BLS 4.0"
                )]
            )
        )

        let report = try await pass.run(bls: table)
        #expect(report.orphanedNames == ["Ajvar", "Schmelzkäse"])
        #expect(report.flagged == 1)
    }

    // MARK: - Healing at read time

    @Test("A code that comes back heals itself, with values and without")
    func aReturningCodeHeals() {
        let table = bls([("K110132", "Kartoffel geschält, gekocht", 70)])

        // Stored as orphaned — by a device that read an older release, or by
        // any writer that saw the code fail. The read is the truth, so the
        // moment the row resolves again the mapping counts again, with no
        // repair step and nothing for the cook to do.
        var stored = BasisAssignment.confirmed(
            code: "K110132", catalogName: "Kartoffel geschält, gekocht",
            datasetVersion: "BLS 4.0"
        )
        stored.status = .orphaned
        let healed = stored.basis(bls: table, source: "BLS 4.0")
        #expect(healed.status == .confirmed)
        #expect(healed.values.kcal == 70)
        // And it names the row as the *current* release calls it, not as the
        // confirmation remembered it.
        #expect(healed.catalogName == "Kartoffel geschält, gekocht")

        var ownStored = BasisAssignment.ownValues(info(kcal: 700), code: "K110132")
        ownStored.status = .orphaned
        #expect(ownStored.basis(bls: table, source: "BLS 4.0").status == .confirmed)
    }

    @Test("Own values keep counting even when the row they stood in for is gone")
    func ownValuesNeverOrphan() {
        let assignment = BasisAssignment.ownValues(
            info(kcal: 700), code: "VANISHED", catalogName: "Schweineschmalz"
        )
        let basis = assignment.basis(bls: bls([]), source: "BLS 4.0")

        #expect(basis.status == .confirmed)
        #expect(basis.values.kcal == 700)
        #expect(!assignment.isOrphaned(in: bls([])))
    }

    // MARK: - The marker

    @Test("The marker notices a data change once, and says nothing on the next start")
    func markerReportsAChangeOnlyOnce() throws {
        let suiteName = "sous.tests.marker.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let marker = BundledDataMarker(defaults: defaults)

        let first = BundledDataStamp(
            fingerprint: "aaa", datasetVersion: "BLS 4.0", seenAt: Date(timeIntervalSince1970: 1)
        )
        // A device that has never recorded one has never reconciled — and may
        // carry entries synced from a device on another release.
        #expect(marker.hasChanged(from: first))

        marker.record(first)
        #expect(!marker.hasChanged(from: first))
        #expect(marker.lastSeen?.datasetVersion == "BLS 4.0")
        #expect(marker.lastSeen?.seenAt == Date(timeIntervalSince1970: 1))

        // A new bundle moves the fingerprint whether or not the version
        // string moved with it, which is why the hash is what is compared.
        let second = BundledDataStamp(
            fingerprint: "bbb", datasetVersion: "BLS 4.0", seenAt: Date(timeIntervalSince1970: 2)
        )
        #expect(marker.hasChanged(from: second))
    }

    @Test("What the app currently ships is a stamp with both halves filled in")
    func theCurrentStampIsReadable() {
        let stamp = BundledDataMarker.current()
        // The whole point of the marker: this used to be a `static let` with
        // the lifetime of the process and no way to read it back.
        #expect(!stamp.fingerprint.isEmpty)
        #expect(stamp.datasetVersion == BLSCatalog.bundled.source.datasetVersion)
    }

    // MARK: - The blob that swallows its errors

    @Test("A basis blob written before there was a status still decodes")
    func aBasisWithoutAStatusStillDecodes() throws {
        // `StoredIngredientVocabulary.bases` reads with `(try? …) ?? [:]`, so
        // a decode that fails does not surface — it silently erases every
        // basis decision on that entry. `status` is the one non-optional
        // field and would take the whole dictionary with it.
        let json = Data("""
        {"unspecified":{"code":"K110132","catalogName":"Kartoffel geschält, gekocht"}}
        """.utf8)

        let decoded = try SousCoding.decoder.decode([String: BasisAssignment].self, from: json)

        #expect(decoded.count == 1)
        #expect(decoded["unspecified"]?.status == .confirmed)
        #expect(decoded["unspecified"]?.code == "K110132")
        #expect(decoded["unspecified"]?.datasetVersion == nil)
    }

    @Test("A stored entry's bases round-trip through the blob unharmed")
    func basesRoundTripThroughTheBlob() {
        let row = StoredIngredientVocabulary(key: "kartoffeln", name: "Kartoffeln")
        row.bases = [
            IngredientState.cooked.rawValue: .confirmed(
                code: "K110132", catalogName: "Kartoffel geschält, gekocht",
                datasetVersion: "BLS 4.0"
            ),
            IngredientState.raw.rawValue: .deliberatelyWithout,
        ]

        #expect(row.bases.count == 2)
        #expect(row.bases[IngredientState.cooked.rawValue]?.datasetVersion == "BLS 4.0")
        #expect(row.bases[IngredientState.raw.rawValue]?.status == .deliberatelyWithout)
    }
}

/// The parts of the reconciliation that need the app's own libraries: what
/// the picker offers after a row has gone, and where an answer is written.
@MainActor
@Suite("Repairing an orphaned mapping")
struct OrphanRepairTests {
    private func info(kcal: Double) -> NutritionInfo {
        NutritionInfo(
            kcal: kcal, proteinG: 0, fatG: 0, saturatedFatG: 0, carbsG: 0, sugarG: 0,
            fiberG: 0, sodiumMg: 0, vitaminAMcg: 0, vitaminCMg: 0, vitaminDMcg: 0,
            vitaminEMg: 0, calciumMg: 0, ironMg: 0, magnesiumMg: 0, potassiumMg: 0
        )
    }

    private func table(_ rows: [(code: String, name: String)]) -> BLSCatalog {
        BLSCatalog(
            source: .init(
                datasetVersion: "BLS 4.1", release: "2026", license: "CC BY 4.0",
                attribution: "Test", changeNote: "Test"
            ),
            entries: rows.map {
                BLSEntry(
                    code: $0.code, name: $0.name, group: "F", category: .other,
                    perHundredGrams: info(kcal: 100)
                )
            }
        )
    }

    private func library(bls: BLSCatalog) throws -> (NutritionLibrary, IngredientCatalogLibrary) {
        let container = try ModelContainer.sousContainer(inMemory: true)
        let catalogLibrary = IngredientCatalogLibrary(
            store: SwiftDataVocabularyStore(modelContainer: container)
        )
        let nutrition = NutritionLibrary(
            store: SwiftDataRecipeNutritionStore(modelContainer: container),
            recipeStore: SwiftDataRecipeStore(modelContainer: container),
            catalogLibrary: catalogLibrary,
            bls: bls
        )
        return (nutrition, catalogLibrary)
    }

    @Test("The vanished row's name finds a successor the kitchen word never would")
    func theRememberedNameProposesASuccessor() async throws {
        // "Omas Schmalztopf" is nobody's catalog name — searching the shipped
        // table for it returns nothing, now and forever. What the mapping
        // remembered is catalog language, and that is what finds neighbours.
        let bls = table([("F200", "Paprikamark mild"), ("F201", "Paprikamark scharf")])
        let (nutrition, catalog) = try library(bls: bls)
        await catalog.save(CatalogIngredient(name: "Omas Schmalztopf", category: .other))
        await catalog.setBasis(
            .confirmed(code: "GONE", catalogName: "Paprikamark", datasetVersion: "BLS 4.0"),
            state: .unspecified, of: "Omas Schmalztopf"
        )
        await nutrition.reload()

        #expect(nutrition.orphanedCatalogNames(forName: "Omas Schmalztopf") == ["Paprikamark"])
        #expect(bls.search("Omas Schmalztopf").isEmpty)

        let candidates = nutrition.candidates(forName: "Omas Schmalztopf").map(\.code)
        #expect(candidates.contains("F200"))
        #expect(candidates.contains("F201"))
    }

    @Test("An answer is written where the broken mapping lives, not where the line stands")
    func repairTargetsTheStateTheBasisIsFiledUnder() async throws {
        // A picker pinned to `unspecified` wrote a second, general basis and
        // left the orphaned cooked one exactly as broken as it was — which is
        // why phase 5's per-state bases were unrepairable until now.
        let bls = table([("F200", "Paprikamark mild")])
        let (nutrition, catalog) = try library(bls: bls)
        await catalog.save(CatalogIngredient(name: "Omas Schmalztopf", category: .other))
        await catalog.setBasis(
            .confirmed(code: "GONE", catalogName: "Paprikamark", datasetVersion: "BLS 4.0"),
            state: .cooked, of: "Omas Schmalztopf"
        )
        await nutrition.reload()

        #expect(nutrition.basisState(forName: "Omas Schmalztopf", asking: .unspecified) == .cooked)

        await nutrition.confirmBasis(code: "F200", state: .cooked, forName: "Omas Schmalztopf")

        let entry = try #require(catalog.entry(for: "Omas Schmalztopf"))
        #expect(entry.bases.count == 1)
        #expect(entry.bases[IngredientState.cooked.rawValue]?.code == "F200")
        // Repaired means repaired: the mapping resolves again, and it carries
        // the release it was re-confirmed against.
        #expect(entry.bases[IngredientState.cooked.rawValue]?.catalogName == "Paprikamark mild")
        #expect(entry.bases[IngredientState.cooked.rawValue]?.datasetVersion == "BLS 4.1")
        #expect(nutrition.orphanedIngredients.isEmpty)
    }

    @Test("A line whose own state has a basis edits that one")
    func aStateWithItsOwnBasisIsAnsweredDirectly() async throws {
        let bls = table([("F200", "Paprikamark mild"), ("F201", "Paprikamark scharf")])
        let (nutrition, catalog) = try library(bls: bls)
        await catalog.save(CatalogIngredient(name: "Omas Schmalztopf", category: .other))
        await catalog.setBasis(
            .confirmed(code: "F200", catalogName: "Paprikamark mild", datasetVersion: "BLS 4.1"),
            state: .raw, of: "Omas Schmalztopf"
        )
        await catalog.setBasis(
            .confirmed(code: "F201", catalogName: "Paprikamark scharf", datasetVersion: "BLS 4.1"),
            state: .cooked, of: "Omas Schmalztopf"
        )
        await nutrition.reload()

        #expect(nutrition.basisState(forName: "Omas Schmalztopf", asking: .cooked) == .cooked)
        #expect(nutrition.basisState(forName: "Omas Schmalztopf", asking: .raw) == .raw)
        // Nothing stored at all: the line's own state stands, because that is
        // what the cook is looking at.
        #expect(nutrition.basisState(forName: "Kurkuma", asking: .cooked) == .cooked)
    }

    @Test("Everything orphaned is listed with the state it has to be answered in")
    func orphansAreListedPerState() async throws {
        let (nutrition, catalog) = try library(bls: table([]))
        await catalog.save(CatalogIngredient(name: "Omas Schmalztopf", category: .other))
        await catalog.setBasis(
            .confirmed(code: "GONE", catalogName: "Paprikamark", datasetVersion: "BLS 4.0"),
            state: .cooked, of: "Omas Schmalztopf"
        )
        await nutrition.reload()

        let open = nutrition.orphanedIngredients
        #expect(open.count == 1)
        #expect(open.first?.name == "Omas Schmalztopf")
        #expect(open.first?.state == .cooked)
    }
}
