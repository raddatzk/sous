import CoreData
import Foundation

/// A ``RecipeStore`` backed by Core Data.
///
/// The store the household's library will actually live in. SwiftData cannot
/// reach CloudKit's shared database — `ModelConfiguration.CloudKitDatabase`
/// offers `.private(_:)` and nothing else — so an invitation of the kind Mela
/// sends requires `NSPersistentCloudKitContainer`, and that means Core Data
/// for everything that syncs.
///
/// A class around a private-queue context rather than an actor: a managed
/// object context already serializes its own work, and wrapping it in a
/// second serialization would buy nothing and hide `perform` from the places
/// that need it. Nothing managed crosses the boundary — every method returns
/// domain values, the same contract ``SwiftDataRecipeStore`` keeps.
public final class CoreDataRecipeStore: RecipeStore, @unchecked Sendable {
    private let context: NSManagedObjectContext

    public init(container: NSPersistentContainer) {
        context = SousPersistentContainer.backgroundContext(for: container)
    }

    // MARK: - Recipes

    public func recipes(matching query: RecipeQuery) async throws -> [Recipe] {
        try await context.perform {
            let request = CDRecipe.fetchRequest()
            request.predicate = Self.predicate(for: query)
            request.sortDescriptors = switch query.sort {
            case .titleAscending:
                [NSSortDescriptor(key: "title", ascending: true, selector: #selector(NSString.localizedStandardCompare(_:)))]
            case .recentlyUpdated:
                [NSSortDescriptor(key: "updatedAt", ascending: false)]
            }

            var results = try self.context.fetchInActiveHousehold(request)
            // The list filters stay in memory because the fields they read are
            // JSON in a string column — a shape chosen so that lists survive
            // CloudKit without a value transformer, and one SQLite cannot
            // search into. A library of recipes is small enough that it does
            // not matter; the search that has to be fast is `searchText`, and
            // that one is indexed and goes through the predicate above.
            for filter in query.filters {
                switch filter.kind {
                case .ingredient:
                    results = results.filter { $0.ingredientKeys.contains(filter.key) }
                case .category:
                    results = results.filter { recipe in
                        recipe.categories.contains { $0.lowercased() == filter.key }
                    }
                case .slot:
                    // What the recipe itself says. The guess that fills in
                    // "Automatisch" lives in the enrichment cache, which is
                    // a floor above this one — see ``RecipeLibrary``.
                    results = results.filter { recipe in
                        recipe.statedSlots.contains(filter.key)
                    }
                }
            }
            return results.compactMap(\.domainValue)
        }
    }

    public func recipe(id: UUID) async throws -> Recipe? {
        try await context.perform { try self.stored(id: id)?.domainValue }
    }

    @discardableResult
    public func save(_ recipe: Recipe) async throws -> Recipe {
        var updated = recipe
        updated.updatedAt = .nowInSyncPrecision

        try await context.perform {
            let groupTitle = try recipe.variantGroupID.flatMap { try self.storedGroup(id: $0) }?.title
            let row = try self.stored(id: recipe.id) ?? CDRecipe(context: self.context)
            row.apply(updated, variantGroupTitle: groupTitle)
            try self.context.save()
        }
        return updated
    }

    public func delete(id: UUID) async throws {
        try await context.perform {
            guard let existing = try self.stored(id: id) else { return }
            let now = Date.nowInSyncPrecision
            existing.deletedAt = now
            existing.updatedAt = now
            try self.context.save()
        }
    }

    public func restore(id: UUID) async throws {
        try await context.perform {
            guard let existing = try self.stored(id: id) else { return }
            existing.deletedAt = nil
            existing.updatedAt = .nowInSyncPrecision
            try self.context.save()
        }
    }

    public func erase(id: UUID) async throws {
        try await context.perform {
            guard let existing = try self.stored(id: id) else { return }
            let groupID = existing.variantGroupID
            self.context.delete(existing)
            if let groupID { try self.collectVariantGroup(id: groupID) }
            try self.context.save()
        }
    }

    public func categories() async throws -> [String] {
        try await context.perform {
            let all = try self.liveRecipes().flatMap(\.categories)
            return Array(Set(all)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    public func categoryCounts() async throws -> [(name: String, count: Int)] {
        try await context.perform {
            var counts: [String: (name: String, count: Int)] = [:]
            for recipe in try self.liveRecipes() {
                for category in recipe.categories {
                    let key = category.lowercased()
                    counts[key, default: (category, 0)].count += 1
                }
            }
            return counts.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    public func renameCategory(_ name: String, to newName: String) async throws {
        let target = newName.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return }
        let key = name.lowercased()

        try await context.perform {
            for row in try self.liveRecipes()
            where row.categories.contains(where: { $0.lowercased() == key }) {
                guard var updated = row.domainValue else { continue }
                // Renaming onto a name a recipe already has merges the two
                // rather than listing it twice.
                var renamed = updated.categories.map { $0.lowercased() == key ? target : $0 }
                var seen = Set<String>()
                renamed = renamed.filter { seen.insert($0.lowercased()).inserted }

                updated.categories = renamed
                updated.updatedAt = .nowInSyncPrecision
                // Only the categories change here. Going through `apply` would
                // also rebuild the ingredient index, and this store has no
                // access to the cook's own catalog to do that faithfully.
                row.categoriesJSON = JSONField.encode(updated.categories)
                row.updatedAt = updated.updatedAt
                row.searchText = RecipeIndex.searchText(
                    for: updated,
                    variantGroupTitle: try self.variantGroupTitle(of: row)
                )
            }
            try self.context.save()
        }
    }

    public func deleteCategory(_ name: String) async throws {
        let key = name.lowercased()

        try await context.perform {
            for row in try self.liveRecipes()
            where row.categories.contains(where: { $0.lowercased() == key }) {
                guard var updated = row.domainValue else { continue }
                updated.categories.removeAll { $0.lowercased() == key }
                updated.updatedAt = .nowInSyncPrecision
                row.categoriesJSON = JSONField.encode(updated.categories)
                row.updatedAt = updated.updatedAt
                row.searchText = RecipeIndex.searchText(
                    for: updated,
                    variantGroupTitle: try self.variantGroupTitle(of: row)
                )
            }
            try self.context.save()
        }
    }

    public func reindexSearch(catalog: IngredientCatalog = .bundled) async throws {
        try await context.perform {
            // Every row, tombstoned ones included: a recipe restored from the
            // trash must come back searchable by today's reading, not by the
            // one it happened to be deleted under.
            for row in try self.context.fetchInActiveHousehold(CDRecipe.fetchRequest()) {
                guard let domain = row.domainValue else { continue }
                row.searchText = RecipeIndex.searchText(
                    for: domain,
                    variantGroupTitle: try self.variantGroupTitle(of: row),
                    catalog: catalog
                )
                row.ingredientKeysJSON = JSONField.encode(
                    RecipeIndex.ingredientKeys(for: domain, catalog: catalog)
                )
            }
            try self.context.save()
        }
    }

    // MARK: - Migration

    /// Writes a recipe exactly as it stands, timestamps and all.
    ///
    /// The one way into this store that does not stamp `updatedAt`, and it
    /// exists for the migration alone. `save` owns that field on purpose —
    /// "set by the store, never by the caller" — but a migration is not an
    /// edit: a library copied across with every row marked as changed just
    /// now would, on the first sync, upload itself wholesale from whichever
    /// device migrated first, and `updatedAt` is the field that decides which
    /// of two devices wins. So it is carried over untouched.
    ///
    /// What is *not* carried over is `searchText`, which is derived and gets
    /// rebuilt here — which is why groups have to be adopted before their
    /// members, or the members go in without the group's name in their index.
    public func adopt(_ recipe: Recipe) async throws {
        try await context.perform {
            let groupTitle = try recipe.variantGroupID.flatMap { try self.storedGroup(id: $0) }?.title
            let row = try self.stored(id: recipe.id) ?? CDRecipe(context: self.context)
            row.apply(recipe, variantGroupTitle: groupTitle)
            try self.context.save()
        }
    }

    /// The same for a group. See ``adopt(_:)``.
    public func adoptVariantGroup(_ group: VariantGroup) async throws {
        try await context.perform {
            let row = try self.storedGroup(id: group.id) ?? CDVariantGroup(context: self.context)
            row.apply(group)
            try self.context.save()
        }
    }

    // MARK: - Variant groups

    public func variantGroups() async throws -> [(group: VariantGroup, liveMembers: Int)] {
        try await context.perform {
            var counts: [UUID: Int] = [:]
            for recipe in try self.liveRecipes() {
                guard let groupID = recipe.variantGroupID else { continue }
                counts[groupID, default: 0] += 1
            }
            return try self.context.fetchInActiveHousehold(CDVariantGroup.fetchRequest())
                .compactMap { row in
                    guard let group = row.domainValue else { return nil }
                    return (group, counts[group.id] ?? 0)
                }
        }
    }

    public func variantGroup(id: UUID) async throws -> VariantGroup? {
        try await context.perform { try self.storedGroup(id: id)?.domainValue }
    }

    public func variantGroupMembers(id: UUID) async throws -> [Recipe] {
        try await context.perform {
            try self.members(ofGroup: id)
                .filter { $0.deletedAt == nil }
                .compactMap(\.domainValue)
                .sorted { $0.createdAt < $1.createdAt }
        }
    }

    @discardableResult
    public func saveVariantGroup(_ group: VariantGroup) async throws -> VariantGroup {
        var updated = group
        updated.updatedAt = .nowInSyncPrecision

        try await context.perform {
            if let existing = try self.storedGroup(id: group.id) {
                let wasRenamed = existing.title != updated.title
                existing.apply(updated)
                // The title lives in every member's search index too. Rewriting
                // it here rather than asking the members to notice is the same
                // bargain `renameCategory` makes.
                if wasRenamed {
                    for member in try self.members(ofGroup: group.id) {
                        guard let domain = member.domainValue else { continue }
                        member.searchText = RecipeIndex.searchText(
                            for: domain,
                            variantGroupTitle: updated.title
                        )
                    }
                }
            } else {
                CDVariantGroup(context: self.context).apply(updated)
            }
            try self.context.save()
        }
        return updated
    }

    public func removeFromVariantGroup(recipeID: UUID) async throws {
        try await context.perform {
            guard let recipe = try self.stored(id: recipeID),
                  let groupID = recipe.variantGroupID
            else { return }
            recipe.variantGroupID = nil
            recipe.updatedAt = .nowInSyncPrecision
            if let domain = recipe.domainValue {
                recipe.searchText = RecipeIndex.searchText(for: domain)
            }
            // Unlike a deletion, this one cannot be taken back from the trash:
            // the recipe is still there and simply is not a version of that dish
            // any more. So a group left with a single member is collected here
            // rather than kept waiting for a sibling that is not coming.
            try self.collectVariantGroup(id: groupID)
            try self.context.save()
        }
    }

    public func dissolveVariantGroup(id: UUID) async throws {
        try await context.perform {
            let now = Date.nowInSyncPrecision
            for member in try self.members(ofGroup: id) {
                member.variantGroupID = nil
                member.updatedAt = now
                if let domain = member.domainValue {
                    member.searchText = RecipeIndex.searchText(for: domain)
                }
            }
            if let group = try self.storedGroup(id: id) {
                self.context.delete(group)
            }
            try self.context.save()
        }
    }

    /// Drops a group nothing is left in.
    ///
    /// Only ever called where a member stops existing rather than being
    /// marked. A group whose members are merely in the trash keeps its row:
    /// restoring one of them puts the pair back together, which clearing the
    /// survivor's field eagerly would have made impossible.
    ///
    /// A group down to a single member is left alone here too — one member
    /// simply does not draw as a group, and the row costs nothing while it
    /// waits for a second variant.
    private func collectVariantGroup(id: UUID) throws {
        let remaining = try members(ofGroup: id)
        guard remaining.count <= 1 else { return }
        for member in remaining {
            member.variantGroupID = nil
            member.updatedAt = .nowInSyncPrecision
            if let domain = member.domainValue {
                member.searchText = RecipeIndex.searchText(for: domain)
            }
        }
        if let group = try storedGroup(id: id) {
            context.delete(group)
        }
    }

    // MARK: - Fetching

    /// Every recipe in the group, tombstoned ones included — a deletion that
    /// can still be undone is still a member.
    private func members(ofGroup id: UUID) throws -> [CDRecipe] {
        let request = CDRecipe.fetchRequest()
        request.predicate = NSPredicate(format: "variantGroupID == %@", id as NSUUID)
        return try context.fetchInActiveHousehold(request)
    }

    private func liveRecipes() throws -> [CDRecipe] {
        let request = CDRecipe.fetchRequest()
        request.predicate = NSPredicate(format: "deletedAt == nil")
        return try context.fetchInActiveHousehold(request)
    }

    private func stored(id: UUID) throws -> CDRecipe? {
        let request = CDRecipe.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        request.fetchLimit = 1
        return try context.fetchInActiveHousehold(request).first
    }

    private func storedGroup(id: UUID) throws -> CDVariantGroup? {
        let request = CDVariantGroup.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        request.fetchLimit = 1
        return try context.fetchInActiveHousehold(request).first
    }

    private func variantGroupTitle(of recipe: CDRecipe) throws -> String? {
        try recipe.variantGroupID.flatMap { try storedGroup(id: $0) }?.title
    }

    private static func predicate(for query: RecipeQuery) -> NSPredicate? {
        var terms: [NSPredicate] = []
        if !query.includeDeleted {
            terms.append(NSPredicate(format: "deletedAt == nil"))
        }
        let search = query.searchText?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if !search.isEmpty {
            // `searchText` is written lowercased, so this is a plain
            // containment rather than a case-insensitive comparison the
            // index could not serve.
            terms.append(NSPredicate(format: "searchText CONTAINS %@", search))
        }
        // Unlike the list filters above, these two are columns of their own
        // and SQLite can answer them.
        if query.onlyFavorites {
            terms.append(NSPredicate(format: "isFavorite == YES"))
        }
        if query.onlyWantToCook {
            terms.append(NSPredicate(format: "wantToCook == YES"))
        }

        guard !terms.isEmpty else { return nil }
        return terms.count == 1 ? terms[0] : NSCompoundPredicate(andPredicateWithSubpredicates: terms)
    }
}

extension CDRecipe {
    static func fetchRequest() -> NSFetchRequest<CDRecipe> {
        NSFetchRequest<CDRecipe>(entityName: SousManagedObjectModel.recipeEntityName)
    }
}

extension CDVariantGroup {
    static func fetchRequest() -> NSFetchRequest<CDVariantGroup> {
        NSFetchRequest<CDVariantGroup>(entityName: SousManagedObjectModel.variantGroupEntityName)
    }
}
