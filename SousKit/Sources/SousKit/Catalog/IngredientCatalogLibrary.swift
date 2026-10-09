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

    /// The data set the answers are laid over: the process's, unless a test
    /// brings its own (two products that `Community/` does not hold).
    public let dataSet: DataSet

    public init(
        localAnswers: any LocalAnswerStore = InMemoryLocalAnswerStore(),
        household: any HouseholdIngredientStore = InMemoryHouseholdIngredientStore(),
        readsRecipes: Bool = false,
        dataSet: DataSet = .current
    ) {
        self.dataSet = dataSet
        self.catalog = dataSet.catalog
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
            await foldAgreedOverrides()
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
        let readingBefore = appliedAnswers.addedNames + appliedAnswers.overrideSignature
        appliedAnswers = localAnswers.applied(to: catalogWithoutLocalAnswers)
        catalog = appliedAnswers.catalog
        revision += 1
        return hasLoaded && appliedAnswers.addedNames + appliedAnswers.overrideSignature != readingBefore
    }

    /// Counts the rebuilds, so what is derived from this library — the
    /// nutrition table, the search index — knows when it has to be derived
    /// again.
    public private(set) var revision = 0

    // MARK: - Reading

    /// The catalog before the local answers: the data set's. What "does the
    /// catalog know this name" is asked of, since a name only a local answer
    /// taught is not one it knows.
    public var catalogWithoutLocalAnswers: IngredientCatalog { dataSet.catalog }

    /// What a local answer says about `name` — applied, or fallen silent
    /// since the catalog learned the name. `nil` where none speaks.
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
    /// A chosen product is named by its brand ("ja!", "Greenforce"); a
    /// target without one, a plain word chosen as a purchase, by its whole
    /// name.
    public func brand(for name: String) -> String? {
        let written = IngredientCatalog.normalize(name)
        let id = catalogWithoutLocalAnswers.ingredient(for: name)?.catalogID
        guard let answer = localAnswers.answers.first(where: {
            $0.writtenKey == written || ($0.catalogID != nil && $0.catalogID == id)
        }) else { return nil }
        if let brand = answer.brand { return brand }
        guard answer.kind == .product, let targetID = answer.targetID else { return nil }
        if LocalAnswer.isKey(targetID) {
            guard let product = ownProduct(forKey: targetID) else { return nil }
            return product.brand ?? product.name
        }
        guard let target = catalog.ingredient(forID: targetID) else { return nil }
        return target.product?.brand ?? target.name
    }

    /// The household's own products: entries of its catalog with
    /// a brand or EAN, which a name links to with a product choice.
    public var ownProducts: [LocalAnswer] {
        localAnswers.answers.filter(\.isLocalProduct)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The own product an answer's target names by its key.
    public func ownProduct(forKey key: String) -> LocalAnswer? {
        localAnswers.answers.first { $0.key == key && $0.isLocalProduct }
    }

    /// What a target id is shown as: an own product's name, or the catalog
    /// word's.
    public func targetName(for targetID: String) -> String? {
        LocalAnswer.isKey(targetID)
            ? ownProduct(forKey: targetID)?.name
            : catalog.ingredient(forID: targetID)?.name
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
        if answer.catalogID == nil, answer.kind?.isFallback != true,
           let known = catalogWithoutLocalAnswers.ingredient(writtenAs: answer.name) {
            answer.catalogID = known.catalogID
        }
        answer.catalogID = answer.catalogID.map(catalog.currentID(for:))
        answer.targetID = answer.targetID.map(catalog.currentID(for:))
        answer.parentID = answer.parentID.map(catalog.currentID(for:))
        answer.spellings = Self.distinctSpellings(answer.spellings)
        answer.displayName = answer.displayName.flatMap(Self.nonEmpty)
        answer.brand = answer.brand.flatMap(Self.nonEmpty)
        answer.ean = answer.ean.flatMap(Self.nonEmpty)
        answer.valuesSource = answer.valuesSource.flatMap(Self.nonEmpty)
        do {
            // An answer re-keyed by this save leaves its old row behind
            // otherwise: delete under the key it was read with, then write.
            if let held = localAnswers.answers.first(where: { $0.id == answer.id }), held.key != answer.key {
                try await localAnswerStore.delete(held)
                // A renamed own product takes the names linked to it along.
                for var link in localAnswers.answers where link.targetID == held.key {
                    link.targetID = answer.key
                    link.updatedAt = .nowInSyncPrecision
                    _ = try await localAnswerStore.save(link)
                }
            }
            _ = try await localAnswerStore.save(answer)
            await reloadAnswers()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// "Lokale Angabe entfernen" on a word the household also overrides:
    /// what the answer says about numbers, products and "zählt
    /// wie" goes; the aisle, parent, spellings and display name of a
    /// catalog word stay, since they were said in another place. A word
    /// only the household knows goes whole — without its answer it is not
    /// there to override.
    public func removeLocalAnswer(_ answer: LocalAnswer) async {
        guard answer.catalogID != nil, answer.hasOverrides else {
            await deleteLocalAnswer(answer)
            return
        }
        var kept = answer
        kept.kind = nil
        kept.targetID = nil
        kept.values = nil
        kept.valuesSource = nil
        kept.weights = [:]
        kept.brand = nil
        kept.ean = nil
        await saveLocalAnswer(kept)
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

    /// "`name` ist ein eigenes Wort, ohne Werte" — what the optimization
    /// proposes for a name nothing in the catalog fairly stands in for. Keeps
    /// whatever else the household already said about the name.
    @discardableResult
    public func addWord(_ name: String) async -> Bool {
        let written = IngredientCatalog.normalize(name)
        var answer = localAnswers.answers.first { $0.writtenKey == written } ?? LocalAnswer(name: name)
        guard answer.kind == nil else { return true }
        answer.kind = .word
        return await saveLocalAnswer(answer)
    }

    // MARK: - Sharing

    /// The answers worth sharing with the curator now (§3 D): pending, and
    /// about something the data set does not answer already.
    public func shareOffers(usage: CatalogUsage = .empty) -> [CatalogSharing.Offer] {
        CatalogSharing.offers(
            localAnswers,
            catalog: catalogWithoutLocalAnswers,
            nutrition: dataSet.nutrition,
            usage: usage,
            targetName: targetName(for:)
        )
    }

    /// How many answers the nudge card counts — the offers without their
    /// recipe context, which counting does not need.
    public var pendingShareCount: Int { shareOffers().count }

    /// Marks the answers behind `offers` as shared, so they are not offered
    /// again until they change. `sharedAt` syncs with the household, so a
    /// second member is not asked about the same answer.
    public func markShared(_ offers: [CatalogSharing.Offer], at date: Date = .nowInSyncPrecision) async {
        let keys = Set(offers.compactMap { $0.answer?.key })
        guard !keys.isEmpty else { return }
        do {
            try await localAnswerStore.markShared(keys: keys, at: date)
            await reloadAnswers()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Re-reads only the answers — the household rows are keyed by ids,
    /// which an answer does not change.
    private func reloadAnswers(foldingAgreed: Bool = true) async {
        do {
            localAnswers = LocalAnswerSet(try await localAnswerStore.answers())
            if rebuild() { await wordsDidChange?() }
        } catch {
            errorMessage = error.localizedDescription
        }
        if foldingAgreed { await foldAgreedOverrides() }
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

    // MARK: - Overrides

    /// Where the catalog has moved away from the household's overrides since
    /// it decided — "Abweichungen" on top of the catalog view, and a quiet
    /// hint in each ingredient's detail.
    public var catalogConflicts: [CatalogConflict] { appliedAnswers.conflicts }

    /// The open conflicts about `word`.
    public func conflicts(of word: CatalogIngredient) -> [CatalogConflict] {
        appliedAnswers.conflicts(forAnswerKey: overrideKey(of: word))
    }

    /// The answer holding the household's overrides of `word`: the one about
    /// its catalog id, or — for a word only the household knows — the one
    /// about its name.
    public func overrideAnswer(of word: CatalogIngredient) -> LocalAnswer? {
        let key = overrideKey(of: word)
        return localAnswers.answers.first { $0.key == key }
    }

    private func overrideKey(of word: CatalogIngredient) -> String {
        if let id = word.catalogID { return "id:\(catalog.currentID(for: id))" }
        return "name:\(word.key)"
    }

    /// What `word` is in the data set's catalog, before any override — `nil`
    /// for a word only the household knows.
    public func catalogWord(of word: CatalogIngredient) -> CatalogIngredient? {
        word.catalogID.flatMap { catalogWithoutLocalAnswers.ingredient(forID: $0) }
    }

    /// What a spelling would be, added to `word` — asked before it is.
    public enum SpellingCheck: Equatable, Sendable {
        /// Nothing to add.
        case empty
        /// The word answers to it already.
        case alreadyKnown
        /// Nobody has it: a local spelling, plain identity.
        case new
        /// The catalog gives it to another word, named here: claiming it
        /// re-reads that spelling for the household — said once, now ("Im
        /// Katalog ist „Pfannkuchen“ Eierkuchen — für deinen Haushalt
        /// umdeuten?"), and never asked again as a conflict.
        case claims(String)
        /// It is another word's own name, or a spelling the household gave
        /// another word — not to be taken.
        case taken(String)
    }

    /// What adding `spelling` to `word` would mean.
    public func checkSpelling(_ spelling: String, for word: CatalogIngredient) -> SpellingCheck {
        let key = IngredientCatalog.normalize(spelling)
        guard !key.isEmpty else { return .empty }
        let household = catalog.ingredient(spelledExactly: spelling)
        if household?.key == word.key { return .alreadyKnown }
        if let owner = catalogWithoutLocalAnswers.ingredient(spelledExactly: spelling), owner.key != word.key {
            return owner.key == key ? .taken(owner.name) : .claims(owner.name)
        }
        if let household { return .taken(household.shownName) }
        return .new
    }

    /// Writes the household's overrides of `word` — the edit mode of the
    /// ingredient's detail. `nil` or empty takes a field back to the
    /// catalog's; so does the catalog's own value.
    ///
    /// Where a place changes, what the catalog says there now is remembered
    /// (``CatalogBaseline``): that is what the household saw when it
    /// decided, so only a later move of the catalog is asked about. A claimed
    /// spelling remembers the word the catalog gave it to — the one
    /// confirmation it gets.
    @discardableResult
    public func saveOverrides(
        of word: CatalogIngredient,
        category: IngredientCategory?,
        parentID: String?,
        spellings: [String],
        displayName: String?
    ) async -> Bool {
        let base = catalogWord(of: word)
        var answer = overrideAnswer(of: word)
            ?? LocalAnswer(catalogID: word.catalogID.map(catalog.currentID(for:)), name: base?.name ?? word.name)
        let held = answer
        var baseline = answer.baseline ?? CatalogBaseline()

        let baseParentID = base?.parentName
            .flatMap(catalogWithoutLocalAnswers.ingredient(for:))?.catalogID
        answer.category = base != nil && category == base?.category ? nil : category
        answer.parentID = parentID.flatMap { base != nil && $0 == baseParentID ? nil : $0 }
        answer.spellings = Self.distinctSpellings(spellings).filter { spelling in
            let key = IngredientCatalog.normalize(spelling)
            return key != word.key && !(base?.keys.contains(key) ?? false)
        }
        answer.displayName = displayName.flatMap(Self.nonEmpty)
            .flatMap { IngredientCatalog.normalize($0) == word.key ? nil : $0 }

        if answer.category != held.category {
            baseline.category = answer.category == nil ? nil : base?.category
        }
        if answer.parentID != held.parentID {
            baseline.parentID = answer.parentID == nil || base == nil ? nil : baseParentID ?? ""
        }
        let heldKeys = Set(held.spellings.map(IngredientCatalog.normalize))
        var owners: [String: String] = [:]
        for spelling in answer.spellings {
            let key = IngredientCatalog.normalize(spelling)
            if heldKeys.contains(key) {
                owners[key] = baseline.spellingOwners[key]
            } else if let owner = catalogWithoutLocalAnswers.ingredient(spelledExactly: spelling),
                      owner.key != word.key {
                owners[key] = owner.catalogID ?? owner.key
            }
        }
        baseline.spellingOwners = owners
        answer.baseline = baseline.isEmpty ? nil : baseline
        guard answer != held else { return true }
        if answer.isEmpty {
            await deleteLocalAnswer(answer)
            return true
        }
        return await saveLocalAnswer(answer)
    }

    /// "Katalog übernehmen": the override at the conflict's place goes, and
    /// the catalog's value stands.
    @discardableResult
    public func adoptCatalog(_ conflict: CatalogConflict) async -> Bool {
        await change(conflict.answerKey) { answer in
            Self.drop(conflict.place, from: &answer)
        }
    }

    /// "Meine behalten": the override stays, and the catalog's new value is
    /// remembered — the conflict is not asked again until the catalog moves
    /// that place once more.
    @discardableResult
    public func keepLocal(_ conflict: CatalogConflict) async -> Bool {
        await change(conflict.answerKey) { answer in
            var baseline = answer.baseline ?? CatalogBaseline()
            switch conflict.place {
            case .category: baseline.category = IngredientCategory(rawValue: conflict.catalogValue)
            case .parent: baseline.parentID = conflict.catalogValue
            case .spelling(let spelling):
                baseline.spellingOwners[IngredientCatalog.normalize(spelling)] = conflict.catalogValue
            }
            answer.baseline = baseline
        }
    }

    private func change(_ key: String, _ edit: (inout LocalAnswer) -> Void) async -> Bool {
        guard var answer = localAnswers.answers.first(where: { $0.key == key }) else { return false }
        edit(&answer)
        if answer.isEmpty {
            await deleteLocalAnswer(answer)
            return true
        }
        return await saveLocalAnswer(answer)
    }

    private static func drop(_ place: CatalogConflict.Place, from answer: inout LocalAnswer) {
        switch place {
        case .category:
            answer.category = nil
            answer.baseline?.category = nil
        case .parent:
            answer.parentID = nil
            answer.baseline?.parentID = nil
        case .spelling(let spelling):
            let key = IngredientCatalog.normalize(spelling)
            answer.spellings.removeAll { IngredientCatalog.normalize($0) == key }
            answer.baseline?.spellingOwners[key] = nil
        }
        if answer.baseline?.isEmpty == true { answer.baseline = nil }
    }

    /// Overrides the catalog has come to agree with fold away without a
    /// question: the household said it first, and now the catalog says it
    /// too. Written by whichever device loads first; the others find
    /// nothing left to fold.
    private func foldAgreedOverrides() async {
        let folded = appliedAnswers.folded
        guard !folded.isEmpty else { return }
        do {
            for key in Set(folded.map(\.answerKey)) {
                guard var answer = localAnswers.answers.first(where: { $0.key == key }) else { continue }
                for conflict in folded where conflict.answerKey == key {
                    Self.drop(conflict.place, from: &answer)
                }
                if answer.isEmpty {
                    try await localAnswerStore.delete(answer)
                } else {
                    try await localAnswerStore.save(answer)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        await reloadAnswers(foldingAgreed: false)
    }

    /// Trimmed, empty ones dropped, each spelling once.
    private static func distinctSpellings(_ spellings: [String]) -> [String] {
        var seen: Set<String> = []
        return spellings.compactMap(nonEmpty).filter { seen.insert(IngredientCatalog.normalize($0)).inserted }
    }
}
