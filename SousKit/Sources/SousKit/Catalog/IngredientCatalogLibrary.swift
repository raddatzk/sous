import Foundation
import Observation

/// The catalog as the app uses it: the data set's catalog with the
/// household's local answers laid over it (INGREDIENTS-DATA §3 B), and the
/// household's own fields per ingredient (§3 C: pantry, store, note).
///
/// The catalog answers; the cook does not maintain it. Spellings, varieties,
/// aisles and bases come from the data set alone — what the household says
/// is either a local answer, for a name the catalog cannot answer yet, or a
/// fact about the household. This is the one place that writes either, so
/// there is a single place that knows what an ingredient is.
@MainActor
@Observable
public final class IngredientCatalogLibrary {
    private let localAnswerStore: any LocalAnswerStore
    private let householdStore: any HouseholdIngredientStore

    /// Everything the app knows, ready to look up.
    public private(set) var catalog: IngredientCatalog = .current {
        didSet {
            if readsRecipes { IngredientLineReader.catalog = catalog }
        }
    }
    /// Whether this is the app's catalog, the one every recipe's lines are
    /// read against (``IngredientLineReader/catalog``). Off for the many
    /// libraries tests build side by side.
    private let readsRecipes: Bool
    /// The household's local answers (INGREDIENTS-DATA §3 B), twins folded.
    public private(set) var localAnswers: LocalAnswerSet = .empty
    /// The answers as laid over the catalog: what each did, and what the
    /// nutrition table takes over from them.
    public private(set) var appliedAnswers: LocalAnswerSet.Applied = .none
    /// The household's ingredient fields, by ``HouseholdIngredient/key`` —
    /// ids as the current data set names them, twins folded, newest first.
    public private(set) var householdIngredients: [String: HouseholdIngredient] = [:]
    public var errorMessage: String?
    /// Called after a rebuild changed which words the catalog knows — a local
    /// answer that adds a name, one taken back, or a household switch. The
    /// stored search index was read against the catalog before, so whoever
    /// holds it reindexes (the app wires ``RecipeLibrary/reindexSearch()``).
    /// Not called for the first load, nor for an answer that only changes
    /// numbers.
    public var wordsDidChange: (@MainActor () async -> Void)?

    public init(
        localAnswers: any LocalAnswerStore = InMemoryLocalAnswerStore(),
        household: any HouseholdIngredientStore = InMemoryHouseholdIngredientStore(),
        readsRecipes: Bool = false
    ) {
        self.localAnswerStore = localAnswers
        self.householdStore = household
        self.readsRecipes = readsRecipes
    }

    /// Whether the household's data has been read at least once. Until it
    /// has, `catalog` is the data set's list alone — which is not what anything
    /// asking a question about a recipe should be answered from.
    private var hasLoaded = false

    public func reload() async {
        do {
            localAnswers = LocalAnswerSet(try await localAnswerStore.answers())
            let entries = try await householdStore.entries()
            let wordsChanged = rebuild()
            householdIngredients = fold(entries)
            hasLoaded = true
            if wordsChanged { await wordsDidChange?() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reads the household's data if nobody has yet.
    ///
    /// Everything that resolves an ingredient — the shopping list, the
    /// unknown-ingredient badge, nutrition — needs the full catalog, not only
    /// the two screens that happen to `reload()` on appearing. Cheap to call
    /// from any of them, since it does nothing once the data is in.
    public func ensureLoaded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    /// The local answers laid over the data set's catalog. Whether a
    /// "zählt wie" still speaks depends on what the catalog knows
    /// (``LocalAnswerSet``). Says whether the words the answers add changed
    /// since an earlier load.
    private func rebuild() -> Bool {
        let addedBefore = appliedAnswers.addedNames
        appliedAnswers = localAnswers.applied(to: catalogWithoutLocalAnswers)
        catalog = appliedAnswers.catalog
        revision += 1
        return hasLoaded && appliedAnswers.addedNames != addedBefore
    }

    /// Counts the rebuilds, so what is derived from this library — the
    /// nutrition table, the search index — knows when it has to be derived
    /// again.
    public private(set) var revision = 0

    // MARK: - Reading

    /// The catalog before the local answers: the data set's. What "does the
    /// catalog know this name" is asked of, since a name only a local answer
    /// taught is not one it knows.
    public var catalogWithoutLocalAnswers: IngredientCatalog { .current }

    /// What a local answer says about `name` — applied, or fallen silent
    /// since the catalog learned the name (R3). `nil` where none speaks.
    public func localTrace(for name: String) -> LocalAnswerTrace? {
        appliedAnswers.trace(for: name)
    }

    /// The household's answer about `name`, by its written form or the
    /// catalog word it resolves to.
    public func localAnswer(for name: String) -> LocalAnswer? {
        if let trace = localTrace(for: name) { return trace.answer }
        let written = IngredientCatalog.normalize(name)
        return localAnswers.answers.first { $0.writtenKey == written }
    }

    /// The brand the household buys `name` as, for the shopping list: the
    /// brand of its local product, or the product it chose for the name.
    /// `nil` for a name it only counts as something else — a "zählt wie" is
    /// recognition, not a purchase, and says nothing about a brand.
    ///
    /// Until catalog products carry a brand of their own (phase 7), a chosen
    /// catalog product is named by its whole name.
    public func brand(for name: String) -> String? {
        let written = IngredientCatalog.normalize(name)
        let id = catalogWithoutLocalAnswers.ingredient(for: name)?.catalogID
        guard let answer = localAnswers.answers.first(where: {
            $0.writtenKey == written || ($0.catalogID != nil && $0.catalogID == id)
        }) else { return nil }
        if let brand = answer.brand { return brand }
        guard answer.kind == .product, let target = answer.targetID.flatMap(catalog.ingredient(forID:)) else {
            return nil
        }
        return target.name
    }

    /// Whether the data set's catalog, without the local answers, knows
    /// `name` as written. A "zählt wie" is only offered for a name it does
    /// not (§3 B).
    public func catalogKnows(_ name: String) -> Bool {
        catalogWithoutLocalAnswers.ingredient(writtenAs: name) != nil
    }

    /// The ingredients named in a recipe's text that the catalog does not
    /// know — what the editor marks.
    public func unknownIngredients(in text: String) -> [String] {
        catalog.unknownIngredients(in: text)
    }

    // MARK: - Household fields

    /// The household's fields for `name` as the catalog reads it — the word
    /// it resolves to, or the name itself where nothing knows it. Only the
    /// word's own row; what a variety takes over from its ancestors is the
    /// shopping list's walk (``householdIngredient(of:)``).
    public func householdIngredient(for name: String) -> HouseholdIngredient? {
        householdIngredients[householdKey(for: name).key]
    }

    /// The household's fields for one catalog word.
    public func householdIngredient(of ingredient: CatalogIngredient) -> HouseholdIngredient? {
        householdIngredients[householdKey(of: ingredient).key]
    }

    /// Where `name`'s fields are filed: the catalog id of the word it
    /// resolves to, or its normalized name. A word a local answer added has
    /// no id, so it is filed by its written name and keeps its own fields.
    private func householdKey(for name: String) -> HouseholdIngredient {
        if let ingredient = catalog.ingredient(for: name) { return householdKey(of: ingredient) }
        return HouseholdIngredient(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func householdKey(of ingredient: CatalogIngredient) -> HouseholdIngredient {
        HouseholdIngredient(catalogID: ingredient.catalogID.map(catalog.currentID(for:)), name: ingredient.name)
    }

    /// The rows by key, ids followed through renames and twins folded —
    /// per key the newest row wins, as two devices may write one at once.
    private func fold(_ entries: [HouseholdIngredient]) -> [String: HouseholdIngredient] {
        var newest: [String: HouseholdIngredient] = [:]
        for var entry in entries where !entry.isEmpty {
            entry.catalogID = entry.catalogID.map(catalog.currentID(for:))
            if let held = newest[entry.key], held.updatedAt >= entry.updatedAt { continue }
            newest[entry.key] = entry
        }
        return newest
    }

    // MARK: - Writing

    /// The household's call that an ingredient is a shelf staple.
    public func setPantry(_ flagged: Bool, name: String) async {
        await updateHousehold(name) { $0.isPantry = flagged }
    }

    /// Where an ingredient is bought and what to know at the shelf. Empty
    /// strings clear — and a row with nothing left to say is deleted.
    public func setShoppingPreferences(store: String?, note: String?, name: String) async {
        let store = store.flatMap(Self.nonEmpty)
        let note = note.flatMap(Self.nonEmpty)
        await updateHousehold(name) { entry in
            entry.preferredStore = store
            entry.shoppingNote = note
        }
    }

    /// How many things the household has said about ingredients: local
    /// answers and rows of pantry, store and note — what emptying a
    /// household takes along.
    public var householdRowCount: Int {
        localAnswers.answers.count + householdIngredients.count
    }

    /// Takes back everything the household said about ingredients — part of
    /// emptying it. The catalog itself is not the household's to delete.
    public func removeHouseholdAnswers() async {
        do {
            for answer in localAnswers.answers {
                try await localAnswerStore.delete(answer)
            }
            for var entry in householdIngredients.values {
                entry.isPantry = false
                entry.preferredStore = nil
                entry.shoppingNote = nil
                try await householdStore.save(entry)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }

    /// Reads, changes and writes one household row. None of it moves a
    /// number, so nothing derived is rebuilt.
    private func updateHousehold(_ name: String, _ change: (inout HouseholdIngredient) -> Void) async {
        let keyed = householdKey(for: name)
        guard !IngredientCatalog.normalize(keyed.name).isEmpty else { return }
        var entry = householdIngredients[keyed.key] ?? keyed
        entry.catalogID = keyed.catalogID
        change(&entry)
        do {
            let saved = try await householdStore.save(entry)
            householdIngredients[keyed.key] = saved
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Local answers

    /// Writes one local answer, keyed the way ``LocalAnswer/key`` says: by
    /// the catalog id where the catalog knows the name and the answer is not
    /// a "zählt wie" (which is only ever about a name it does not know), by
    /// the written name otherwise.
    ///
    /// Ids are written as the current data set names them: a target renamed
    /// since the answer was first saved is resolved on read and rewritten
    /// here, on the save the answer sees anyway — never in bulk.
    @discardableResult
    public func saveLocalAnswer(_ answer: LocalAnswer) async -> Bool {
        var answer = answer
        answer.name = answer.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.name.isEmpty else { return false }
        if answer.catalogID == nil, answer.kind != .countsAs,
           let known = catalogWithoutLocalAnswers.ingredient(writtenAs: answer.name) {
            answer.catalogID = known.catalogID
        }
        answer.catalogID = answer.catalogID.map(catalog.currentID(for:))
        answer.targetID = answer.targetID.map(catalog.currentID(for:))
        answer.brand = answer.brand.flatMap(Self.nonEmpty)
        answer.ean = answer.ean.flatMap(Self.nonEmpty)
        answer.valuesSource = answer.valuesSource.flatMap(Self.nonEmpty)
        do {
            // An answer re-keyed by this save leaves its old row behind
            // otherwise: delete under the key it was read with, then write.
            if let held = localAnswers.answers.first(where: { $0.id == answer.id }), held.key != answer.key {
                try await localAnswerStore.delete(held)
            }
            _ = try await localAnswerStore.save(answer)
            await reloadAnswers()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Takes a local answer back — "Lokale Angabe entfernen".
    public func deleteLocalAnswer(_ answer: LocalAnswer) async {
        do {
            try await localAnswerStore.delete(answer)
            await reloadAnswers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// "`name` zählt wie `target`" — the one-tap answer for a name the
    /// catalog does not know. Keeps whatever else the household already
    /// said about the name.
    @discardableResult
    public func count(_ name: String, as target: CatalogIngredient, kind: LocalAnswer.Kind = .countsAs) async -> Bool {
        guard let targetID = target.catalogID else { return false }
        let written = IngredientCatalog.normalize(name)
        var answer = localAnswers.answers.first { $0.writtenKey == written } ?? LocalAnswer(name: name)
        answer.kind = kind
        answer.targetID = targetID
        return await saveLocalAnswer(answer)
    }

    /// Re-reads only the answers — the household rows are keyed by ids,
    /// which an answer does not change.
    private func reloadAnswers() async {
        do {
            localAnswers = LocalAnswerSet(try await localAnswerStore.answers())
            if rebuild() { await wordsDidChange?() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What one of `unit` weighs for `name`, as the household weighed it —
    /// an own weight of its local answer (§3 B), which beats the catalog's for
    /// that unit and only that unit. `nil` takes it back.
    @discardableResult
    public func setLocalWeight(_ grams: Double?, unit: IngredientUnit, of name: String) async -> Bool {
        var answer = localAnswer(for: name) ?? LocalAnswer(name: catalog.canonicalName(for: name))
        if let grams {
            answer.weights[unit.symbol] = LocalAnswer.Weight(grams: grams, state: answer.weights[unit.symbol]?.state)
        } else {
            answer.weights[unit.symbol] = nil
        }
        if answer.isEmpty {
            await deleteLocalAnswer(answer)
            return true
        }
        return await saveLocalAnswer(answer)
    }
}
