import CoreData
import Foundation
import Testing
@testable import SousKit

/// The Core Data store of local answers, and the step that added its entity
/// to stores written before phase 6a.
@Suite("Local answer store")
struct LocalAnswerStoreTests {
    private static func info(kcal: Double) -> NutritionInfo {
        var info = NutritionInfo.zero
        info.kcal = kcal
        return info
    }

    @Test("Every field survives the round trip")
    func roundTrip() async throws {
        let store = CoreDataLocalAnswerStore(container: try SousPersistentContainer.make(inMemory: true))
        let answer = LocalAnswer(
            name: "Hafer-Drink-Pulver", kind: .product, targetID: "haferflocken",
            values: Self.info(kcal: 400), valuesSource: "Packung",
            weights: ["Dose": LocalAnswer.Weight(grams: 240, state: .cooked), "EL": LocalAnswer.Weight(grams: 8)],
            brand: "Marke A", ean: "4000000000000"
        )

        try await store.save(answer)
        let read = try #require(try await store.answers().first)

        #expect(read.id == answer.id)
        #expect(read.key == "name:haferdrinkpulver")
        #expect(read.kind == .product)
        #expect(read.targetID == "haferflocken")
        #expect(read.values?.kcal == 400)
        #expect(read.valuesSource == "Packung")
        #expect(read.weights == answer.weights)
        #expect(read.brand == "Marke A")
        #expect(read.ean == "4000000000000")
        #expect(read.sharedAt == nil)
    }

    @Test("A second save under one key folds into the first row")
    func upsertByKey() async throws {
        let store = CoreDataLocalAnswerStore(container: try SousPersistentContainer.make(inMemory: true))
        try await store.save(LocalAnswer(name: "Rauchtofu", kind: .countsAs, targetID: "tofu"))
        try await store.save(LocalAnswer(name: "rauchtofu", kind: .countsAs, targetID: "tempeh"))

        let rows = try await store.answers()
        #expect(rows.count == 1)
        #expect(rows.first?.targetID == "tempeh")
    }

    @Test("An answer that says nothing is deleted, not kept")
    func emptyAnswerIsDeleted() async throws {
        let store = CoreDataLocalAnswerStore(container: try SousPersistentContainer.make(inMemory: true))
        var answer = LocalAnswer(name: "Rauchtofu", kind: .countsAs, targetID: "tofu")
        try await store.save(answer)

        answer.kind = nil
        answer.targetID = nil
        #expect(try await store.save(answer) == nil)
        #expect(try await store.answers().isEmpty)
    }

    @Test("A re-keyed answer moves rather than leaving a twin")
    func reKeyedAnswerMoves() async throws {
        let store = CoreDataLocalAnswerStore(container: try SousPersistentContainer.make(inMemory: true))
        var answer = LocalAnswer(name: "Tofu", values: Self.info(kcal: 150))
        try await store.save(answer)

        answer.catalogID = "tofu"
        try await store.save(answer)

        let rows = try await store.answers()
        #expect(rows.map(\.key) == ["id:tofu"])
    }
}

/// A store written before phase 6a — without `CDLocalAnswer`, with the
/// entities 6b retired — opens under the current model, keeps its recipes,
/// and takes local answers. Run twice, the second opening changes nothing.
///
/// No take-over of vocabulary rows runs (decided 2026-10-01: Sous is still in
/// development, data can be reset), so "the new entity fills" is a write
/// through the store after the migration.
@Suite("Local answers migrate in")
struct LocalAnswerMigrationTests {
    private func temporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sous-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Sous.sqlite")
    }

    private func open(_ url: URL, with model: NSManagedObjectModel) throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "Sous", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: url)
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in
            if loadError == nil { loadError = error }
        }
        if let loadError { throw loadError }
        return container
    }

    private func close(_ container: NSPersistentContainer) throws {
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }

    @Test("An old store opens, keeps its recipes, and local answers can be written")
    func oldStoreOpensAndTakesLocalAnswers() async throws {
        let url = try temporaryStoreURL()
        let old = SousManagedObjectModel.makeModel(
            includingRetiredEntities: true, includingLocalAnswers: false, includingHouseholdIngredients: false
        )
        #expect(old.entitiesByName[SousManagedObjectModel.localAnswerEntityName] == nil)

        let before = try open(url, with: old)
        let saved = try await CoreDataRecipeStore(container: before)
            .save(Recipe(title: "Brot", servings: 4, ingredientsText: "500 g Mehl"))
        try close(before)

        for _ in 0..<2 {
            let after = try open(url, with: SousManagedObjectModel.shared)
            #expect(try await CoreDataRecipeStore(container: after).recipe(id: saved.id)?.title == "Brot")
            try close(after)
        }

        let after = try open(url, with: SousManagedObjectModel.shared)
        let answers = CoreDataLocalAnswerStore(container: after)
        #expect(try await answers.answers().isEmpty)
        try await answers.save(LocalAnswer(name: "Rauchtofu", kind: .countsAs, targetID: "tofu"))
        #expect(try await answers.answers().map(\.name) == ["Rauchtofu"])
        try close(after)
    }
}
