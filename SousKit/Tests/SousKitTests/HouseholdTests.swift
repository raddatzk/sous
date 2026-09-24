import CoreData
import Foundation
import Testing
@testable import SousKit

/// No household active in any of these — the state of a fresh install
/// before its first import, and of every other suite. Tests that choose a
/// household live in `HouseholdSwitchingTests`, which runs serialized.
@Suite("The household every row belongs to")
struct HouseholdTests {
    private func makeContainer() throws -> NSPersistentContainer {
        try SousPersistentContainer.make(inMemory: true)
    }

    /// A household as plain values — the managed object would outlive its
    /// context here and read back empty.
    private struct Row {
        let id: UUID?
        let name: String
        let isDeliberate: Bool
    }

    private func households(in container: NSPersistentContainer) throws -> [Row] {
        let context = container.newBackgroundContext()
        return try context.performAndWait {
            let request = NSFetchRequest<CDHousehold>(
                entityName: SousManagedObjectModel.householdEntityName
            )
            request.sortDescriptors = CoreDataHouseholds.oldestFirst
            return try context.fetch(request).map {
                Row(id: $0.id, name: $0.name, isDeliberate: $0.isDeliberate)
            }
        }
    }

    /// Recipe, plan entry, shopping line and taught ingredient — one row of
    /// every kind a person writes by hand.
    private func writeOneOfEverything(into container: NSPersistentContainer) async throws {
        let recipe = try await CoreDataRecipeStore(container: container).save(Recipe(title: "Brot"))
        try await CoreDataMealPlanStore(container: container)
            .save(MealPlanEntry(day: nil, slot: .dinner, recipeID: recipe.id))
        try await CoreDataShoppingListStore(container: container)
            .addManual(key: "mehl", name: "Mehl", category: .grains, quantities: [])
        _ = try await CoreDataVocabularyStore(container: container)
            .save(IngredientVocabularyEntry(name: "Ajvar", isOwnIngredient: true))
    }

    /// Long enough for the next household's millisecond timestamp to differ,
    /// so "oldest first" is the order they were made in.
    private func pause() async throws {
        try await Task.sleep(for: .milliseconds(5))
    }

    private func rowsWithoutHousehold(in container: NSPersistentContainer) throws -> Int {
        let context = container.newBackgroundContext()
        return try context.performAndWait {
            var count = 0
            for entity in SousManagedObjectModel.memberEntityNames {
                let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                request.predicate = NSPredicate(format: "household == nil")
                count += try context.count(for: request)
            }
            return count
        }
    }

    @Test("With no household known, what is saved waits without one")
    func contentBeforeTheImportWaits() async throws {
        let container = try makeContainer()

        try await writeOneOfEverything(into: container)

        // A reinstall before its first import: whatever is saved now must
        // not found a household, or a stray one reaches every device the
        // moment the real ones arrive.
        #expect(try households(in: container).isEmpty)
        #expect(try rowsWithoutHousehold(in: container) > 0)
        // Still there to be seen and used.
        let titles = try await CoreDataRecipeStore(container: container).recipes(matching: .all).map(\.title)
        #expect(titles == ["Brot"])
    }

    @Test("Settling an account without a household founds one and takes in what waited")
    func settlingFoundsTheHousehold() async throws {
        let container = try makeContainer()
        try await writeOneOfEverything(into: container)
        let waiting = try rowsWithoutHousehold(in: container)

        let settlement = try await CoreDataHouseholds(container: container).settle()

        #expect(settlement == HouseholdSettlement(founded: true, assigned: waiting, unassigned: 0))
        let all = try households(in: container)
        #expect(all.count == 1)
        #expect(all.first?.name == CoreDataHouseholds.defaultName)
        // Made by the app, not by a person: foldable if a second device made
        // one at the same moment.
        #expect(all.first?.isDeliberate == false)
        #expect(try rowsWithoutHousehold(in: container) == 0)
    }

    @Test("Settling founds a household even with nothing waiting")
    func settlingAnEmptyAccount() async throws {
        // Once the first import has arrived there is never no household —
        // the share extension needs somewhere to write.
        let container = try makeContainer()

        let settlement = try await CoreDataHouseholds(container: container).settle()

        #expect(settlement == HouseholdSettlement(founded: true, assigned: 0, unassigned: 0))
        #expect(try households(in: container).count == 1)
    }

    @Test("Settling again changes nothing")
    func settlingIsIdempotent() async throws {
        let container = try makeContainer()
        let households = CoreDataHouseholds(container: container)
        try await writeOneOfEverything(into: container)
        try await households.settle()

        let again = try await households.settle()

        #expect(again == HouseholdSettlement(founded: false, assigned: 0, unassigned: 0))
        #expect(try self.households(in: container).count == 1)
    }

    @Test("With several own households, what waited stays unassigned")
    func severalHouseholdsLeaveTheChoice() async throws {
        let container = try makeContainer()
        let households = CoreDataHouseholds(container: container)
        // The iPhone's "Familie" and "WG", arrived on a reinstalled iPad
        // after it had already saved a recipe.
        try await CoreDataRecipeStore(container: container).save(Recipe(title: "Brot"))
        try await households.create(named: "Familie")
        try await households.create(named: "WG")

        let settlement = try await households.settle()

        #expect(settlement == HouseholdSettlement(founded: false, assigned: 0, unassigned: 1))
        #expect(try self.households(in: container).count == 2)
    }

    @Test("What waited goes where the person says")
    func assigningWaitingRows() async throws {
        let container = try makeContainer()
        let households = CoreDataHouseholds(container: container)
        try await writeOneOfEverything(into: container)
        try await households.create(named: "Familie")
        let wg = try await households.create(named: "WG")
        try await households.settle()
        let waiting = try await households.waitingRowCount()
        #expect(waiting > 0)

        let assigned = try await households.assignWaitingRows(to: wg)

        #expect(assigned == waiting)
        #expect(try await households.waitingRowCount() == 0)
        let context = container.newBackgroundContext()
        try await context.perform {
            let row = try #require(try context.fetch(CDRecipe.fetchRequest()).first)
            #expect(row.household?.id == wg)
        }
    }

    @Test("Waiting rows are never given to a household that is not one's own")
    func assigningToAnUnknownHousehold() async throws {
        let container = try makeContainer()
        let households = CoreDataHouseholds(container: container)
        try await writeOneOfEverything(into: container)

        #expect(try await households.assignWaitingRows(to: UUID()) == 0)
        #expect(try await households.waitingRowCount() > 0)
    }

    @Test("A created household is named, deliberate, and never folded away")
    func createdHouseholdsStay() async throws {
        let container = try makeContainer()
        let households = CoreDataHouseholds(container: container)
        // The one the app made for this account, then two the person made.
        try await households.settle()
        try await pause()
        try await households.create(named: "  Familie \n")
        try await pause()
        try await households.create(named: "WG")

        let folded = try await households.mergeDuplicates()

        #expect(folded == 0)
        let all = try self.households(in: container)
        #expect(all.map(\.name) == [CoreDataHouseholds.defaultName, "Familie", "WG"])
        #expect(all.map(\.isDeliberate) == [false, true, true])
        #expect(try await households.choices().map(\.name) == all.map(\.name))
    }

    @Test("A second household the app made is folded into the first, with its rows")
    func mergesImplicitDuplicates() async throws {
        let container = try makeContainer()
        let store = CoreDataRecipeStore(container: container)
        try await store.save(Recipe(title: "Brot"))
        try await CoreDataHouseholds(container: container).settle()

        // What two devices set up at the same moment on a new account leave
        // behind: a second "Mein Haushalt", with a recipe of its own.
        let context = container.newBackgroundContext()
        try await context.perform {
            let second = CDHousehold(context: context)
            second.id = UUID()
            second.name = CoreDataHouseholds.defaultName
            // Made a moment later, on the other device.
            second.createdAt = Date.nowInSyncPrecision.addingTimeInterval(1)
            second.updatedAt = .nowInSyncPrecision
            let stray = CDRecipe(context: context)
            stray.id = UUID()
            stray.title = "Suppe"
            stray.createdAt = .nowInSyncPrecision
            stray.updatedAt = .nowInSyncPrecision
            stray.household = second
            try context.save()
        }

        let folded = try await CoreDataHouseholds(container: container).mergeDuplicates()

        #expect(folded == 1)
        let survivor = try #require(try households(in: container).first)
        #expect(try households(in: container).count == 1)
        // A fresh context: the one above still holds the rows as it wrote them.
        let reading = container.newBackgroundContext()
        try await reading.perform {
            let rows = try reading.fetch(CDRecipe.fetchRequest())
            #expect(rows.count == 2)
            for row in rows {
                #expect(row.household?.id == survivor.id)
            }
        }
    }

    @Test("The oldest own household is where a device without a choice starts")
    func oldestOwnID() async throws {
        let container = try makeContainer()
        let households = CoreDataHouseholds(container: container)
        #expect(households.oldestOwnID() == nil)

        let first = try await households.create(named: "Familie")
        try await pause()
        try await households.create(named: "WG")

        #expect(households.oldestOwnID() == first)
    }

    @Test("Deleting a household takes its rows along and leaves the others alone")
    func deletingAHousehold() async throws {
        let container = try makeContainer()
        let households = CoreDataHouseholds(container: container)
        try await households.create(named: "Familie")
        try await pause()
        let wg = try await households.create(named: "WG")
        let context = container.newBackgroundContext()
        // One recipe in each, written straight onto the household so the
        // test needs no active one.
        try await context.perform {
            let all = try context.fetch(NSFetchRequest<CDHousehold>(entityName: SousManagedObjectModel.householdEntityName))
            for household in all {
                let recipe = CDRecipe(context: context)
                recipe.id = UUID()
                recipe.title = household.name
                recipe.createdAt = .nowInSyncPrecision
                recipe.updatedAt = .nowInSyncPrecision
                recipe.household = household
            }
            try context.save()
        }

        try await households.delete(wg)

        #expect(try self.households(in: container).map(\.name) == ["Familie"])
        let reading = container.newBackgroundContext()
        let titles = try await reading.perform {
            try reading.fetch(CDRecipe.fetchRequest()).map(\.title)
        }
        #expect(titles == ["Familie"])
    }

    @Test("Deleting the last own household leaves a fresh one")
    func deletingTheLastHousehold() async throws {
        let container = try makeContainer()
        let households = CoreDataHouseholds(container: container)
        let only = try await households.create(named: "Familie")

        try await households.delete(only)

        let left = try self.households(in: container)
        #expect(left.map(\.name) == [CoreDataHouseholds.defaultName])
        #expect(left.first?.id != only)
        #expect(left.first?.isDeliberate == false)
    }

    @Test("A household's standing says whose it is and whether it is shared")
    func standing() async throws {
        let container = try makeContainer()
        let households = CoreDataHouseholds(container: container)
        let id = try await households.create(named: "Familie")

        let standing = await households.standing(of: id)

        #expect(standing == HouseholdStanding(name: "Familie", isOwn: true, isShared: false, otherParticipants: 0))
        #expect(await households.standing(of: UUID()) == nil)
    }

    @Test("Renaming names the own household, trimmed")
    func renamesOwnHousehold() async throws {
        let container = try makeContainer()
        let households = CoreDataHouseholds(container: container)
        try await households.settle()
        #expect(try await households.ownName() == CoreDataHouseholds.defaultName)

        try await households.rename(to: "  Familie Raddatz \n")
        #expect(try await households.ownName() == "Familie Raddatz")

        // An empty field is not a name; the household keeps the one it had.
        try await households.rename(to: "   ")
        #expect(try await households.ownName() == "Familie Raddatz")
    }

    @Test("A particular household is renamed, and only an own one")
    func renamingByID() async throws {
        let container = try makeContainer()
        let households = CoreDataHouseholds(container: container)
        try await households.create(named: "Familie")
        try await pause()
        let wg = try await households.create(named: "WG")

        try await households.rename(wg, to: " Küche Lindenstraße ")
        try await households.rename(UUID(), to: "Niemand")

        #expect(try self.households(in: container).map(\.name) == ["Familie", "Küche Lindenstraße"])
        // Nothing mirrored, nothing shared: nobody else is in it.
        #expect(await households.members(of: wg).isEmpty)
    }

    @Test("Renaming before there is a household founds none")
    func renamingFoundsNothing() async throws {
        // A reinstall's library is still on its way from iCloud; a household
        // made now would be a second one once the first arrives.
        let container = try makeContainer()
        let store = CoreDataHouseholds(container: container)

        try await store.rename(to: "Familie Raddatz")

        #expect(try households(in: container).isEmpty)
        #expect(try await store.ownName() == nil)
    }

    @Test("Asking to invite without CloudKit fails with a sentence, not silence")
    func invitingWithoutCloudKitSaysWhy() async throws {
        // The in-memory container is a plain NSPersistentContainer — the same
        // shape a device without the entitlement gets. A person who taps
        // "Haushalt teilen" there has asked for something, and the answer has
        // to be an error they can read, not a button that does nothing.
        await #expect(throws: HouseholdSharingError.self) {
            _ = try await CoreDataHouseholds(container: try makeContainer()).shareForInviting(named: "Küche")
        }
    }
}

/// Serialized, because the active household is process-wide state — the same
/// way it is in the app. Other suites are not disturbed: an id set here names
/// a household only in this suite's containers, and everywhere else reads as
/// no household at all.
@Suite("Switching households", .serialized)
struct HouseholdSwitchingTests {
    private struct Stores {
        let recipes: CoreDataRecipeStore
        let plan: CoreDataMealPlanStore
        let shopping: CoreDataShoppingListStore
        let vocabulary: CoreDataVocabularyStore

        init(_ container: NSPersistentContainer) {
            recipes = CoreDataRecipeStore(container: container)
            plan = CoreDataMealPlanStore(container: container)
            shopping = CoreDataShoppingListStore(container: container)
            vocabulary = CoreDataVocabularyStore(container: container)
        }

        /// A recipe, its plan entry, a shopping line and a taught ingredient,
        /// all carrying `name`.
        func write(_ name: String) async throws {
            let recipe = try await recipes.save(Recipe(title: name))
            try await plan.save(MealPlanEntry(day: nil, slot: .dinner, recipeID: recipe.id))
            try await shopping.addManual(key: name.lowercased(), name: name, category: nil, quantities: [])
            _ = try await vocabulary.save(IngredientVocabularyEntry(name: name, isOwnIngredient: true))
        }

        /// What the four stores show, one list per kind.
        func read() async throws -> [[String]] {
            let titles = try await recipes.recipes(matching: .all).map(\.title).sorted()
            let planned = try await plan.poolEntries().count
            let lines = try await shopping.snapshot().items.map(\.name).sorted()
            let taught = try await vocabulary.entries().map(\.name).sorted()
            return [titles, ["\(planned)"], lines, taught]
        }
    }

    @Test("Two own households never see each other's rows")
    func ownHouseholdsAreApart() async throws {
        let before = ActiveHousehold.id
        defer { ActiveHousehold.id = before }
        let container = try SousPersistentContainer.make(inMemory: true)
        let households = CoreDataHouseholds(container: container)
        let stores = Stores(container)
        let familie = try await households.create(named: "Familie")
        let wg = try await households.create(named: "WG")

        ActiveHousehold.id = familie
        try await stores.write("Brot")
        ActiveHousehold.id = wg
        try await stores.write("Suppe")

        #expect(try await stores.read() == [["Suppe"], ["1"], ["Suppe"], ["Suppe"]])
        ActiveHousehold.id = familie
        #expect(try await stores.read() == [["Brot"], ["1"], ["Brot"], ["Brot"]])
    }

    @Test("What waits for a household shows in every own household")
    func waitingRowsShowEverywhere() async throws {
        let before = ActiveHousehold.id
        defer { ActiveHousehold.id = before }
        let container = try SousPersistentContainer.make(inMemory: true)
        let households = CoreDataHouseholds(container: container)
        let recipes = CoreDataRecipeStore(container: container)

        // Saved during a reinstall, before any household had arrived.
        ActiveHousehold.id = nil
        try await recipes.save(Recipe(title: "Brot"))
        let familie = try await households.create(named: "Familie")
        let wg = try await households.create(named: "WG")
        #expect(try await households.settle().unassigned == 1)

        // Unassigned, but not gone: whichever of the two is showing has it,
        // until the person says where it belongs.
        for id in [familie, wg] {
            ActiveHousehold.id = id
            #expect(try await recipes.recipes(matching: .all).map(\.title) == ["Brot"])
        }
    }

    @Test("A new row joins the active household")
    func insertsJoinTheActiveHousehold() async throws {
        let before = ActiveHousehold.id
        defer { ActiveHousehold.id = before }
        let container = try SousPersistentContainer.make(inMemory: true)
        let households = CoreDataHouseholds(container: container)
        try await households.create(named: "Familie")
        let wg = try await households.create(named: "WG")

        ActiveHousehold.id = wg
        try await CoreDataRecipeStore(container: container).save(Recipe(title: "Brot"))

        let context = container.newBackgroundContext()
        try await context.perform {
            let row = try #require(try context.fetch(CDRecipe.fetchRequest()).first)
            // Nothing in CoreDataRecipeStore mentions a household. If this
            // holds, no future insert path can forget it either.
            #expect(row.household?.id == wg)
        }
    }

    @Test("An active household nothing holds loses nothing that is written")
    func unknownActiveHousehold() async throws {
        let before = ActiveHousehold.id
        defer { ActiveHousehold.id = before }
        // Names a household no store on this device has — the state after
        // being removed from one, or after the account changed.
        ActiveHousehold.id = UUID()

        let container = try SousPersistentContainer.make(inMemory: true)
        let store = CoreDataRecipeStore(container: container)
        try await store.save(Recipe(title: "Brot"))

        // Both the write and the read land among the rows waiting for a
        // household rather than vanishing into a scope that does not exist.
        #expect(try await store.recipes(matching: .all).map(\.title) == ["Brot"])
    }
}
