import CryptoKit
import Foundation

/// A household's local answers, and the precedence they are laid over the
/// catalog with.
///
/// - **"Zählt wie" is a fallback.** It applies only while the catalog does
///   not know the written name. Once a data update teaches the catalog the
///   name, the catalog's own entry answers and the local one falls silent,
///   leaving a quiet ``LocalAnswerTrace`` for the detail view and the
///   drilldown. Nothing prompts.
/// - **A product is an override.** A purchase choice stays, whether or not
///   the catalog knows the name.
/// - **Own values and weights beat the catalog field by field**: the values
///   replace the basis, a weight replaces the catalog's weight for its unit
///   and only that unit.
/// - **Recognition, never identity.** A name the catalog does not know
///   joins the household catalog as a word of its own — under the target's
///   aisle, with no aliases and no parent. So the strict reader knows it, the
///   numbers come from the target, and the shopping list still bundles
///   "Räuchertofu" as Räuchertofu, with its own pantry flag; Tofu's do not
///   reach it.
///
/// A target or key id renamed in a newer data set is resolved on read
/// (``IngredientCatalog/resolve(id:)``); one retired without a successor
/// leaves the name the visible gap it was.
public struct LocalAnswerSet: Sendable, Equatable {
    /// One answer per key: where two devices wrote the same one, the newer
    /// row wins (§3 B, "two rows for one key").
    public let answers: [LocalAnswer]

    public static let empty = LocalAnswerSet([])

    public init(_ answers: [LocalAnswer]) {
        var newest: [String: LocalAnswer] = [:]
        for answer in answers where !answer.isEmpty {
            if let held = newest[answer.key], held.updatedAt >= answer.updatedAt { continue }
            newest[answer.key] = answer
        }
        self.answers = newest.values.sorted { $0.key < $1.key }
    }

    public var isEmpty: Bool { answers.isEmpty }

    /// What the answers say, as a short stable digest — part of the nutrition
    /// cache's key, so a figure computed against one household's answers is
    /// never shown for another's, nor after an answer synced in. Ids and
    /// timestamps are left out: twins and re-saves change no number.
    public var fingerprint: String {
        guard !answers.isEmpty else { return "none" }
        let content = answers.map { answer -> FingerprintContent in
            FingerprintContent(
                key: answer.key, kind: answer.kind, targetID: answer.targetID,
                values: answer.values, valuesSource: answer.valuesSource,
                weights: answer.weights, brand: answer.brand, ean: answer.ean,
                parentID: answer.parentID, spellings: answer.spellings.isEmpty ? nil : answer.spellings
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(content)) ?? Data()
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private struct FingerprintContent: Encodable {
        var key: String
        var kind: LocalAnswer.Kind?
        var targetID: String?
        var values: NutritionInfo?
        var valuesSource: String?
        var weights: [String: LocalAnswer.Weight]
        var brand: String?
        var ean: String?
        /// Phase 7d: what changes how a recipe reads and inherits. Left out
        /// where unset, so an answer without overrides keeps its digest.
        var parentID: String?
        var spellings: [String]?
    }

    // MARK: - Applying

    /// The answers laid over `base`: the catalog the household reads its
    /// recipes with, and what each answer did.
    ///
    /// The household's overrides are laid on last, onto the catalog's words
    /// and the household's own alike: aisle, parent, spellings and display
    /// name. Local wins — but where the catalog has moved since the
    /// household decided (``CatalogBaseline``), the place is reported in
    /// ``Applied/conflicts``, and where the catalog has come to agree, in
    /// ``Applied/folded``, for the library to fold the override away.
    public func applied(to base: IngredientCatalog) -> Applied {
        guard !answers.isEmpty else { return Applied(catalog: base) }

        var additions: [CatalogIngredient] = []
        var addedKeys: Set<String> = []
        var traces: [String: LocalAnswerTrace] = [:]
        var steps: [Applied.Step] = []
        /// The household's own products by their answer's key, for a name's
        /// product choice to point at.
        var ownProducts: [String: CatalogIngredient] = [:]
        /// The answers with overrides, and the word each is about: a word of
        /// the base catalog, or one the answers added.
        var overriding: [(answer: LocalAnswer, subject: CatalogIngredient, isAddition: Bool)] = []
        /// Names that chose a product, and the product: the name stands in
        /// the product's aisle, since where a thing is shelved is a matter
        /// of what is bought, not of how the recipe calls it.
        var productChoices: [(subject: CatalogIngredient, isAddition: Bool, product: CatalogIngredient)] = []

        // Own products before the names that link to them.
        let ordered = answers.filter { !$0.targetsOwnProduct } + answers.filter(\.targetsOwnProduct)
        for answer in ordered {
            let target: CatalogIngredient? = answer.targetID.flatMap { targetID in
                LocalAnswer.isKey(targetID) ? ownProducts[targetID] : base.resolve(id: targetID).ingredient
            }
            // The word the answer is about, where the catalog knows it.
            let known: CatalogIngredient? = answer.catalogID
                .flatMap { base.resolve(id: $0).ingredient }
                ?? base.ingredient(writtenAs: answer.name)

            if let known, answer.kind?.isFallback == true {
                // The catalog learned the name: its answer stands, quietly.
                traces[known.key] = LocalAnswerTrace(
                    answer: answer, targetName: target?.name, status: .silenced(by: known.name)
                )
                traces[answer.writtenKey] = traces[known.key]
                // An override is no fallback: it stays, now over the
                // catalog's word, and asks where the catalog says otherwise.
                if answer.hasOverrides { overriding.append((answer, known, false)) }
                continue
            }

            if answer.kind != nil, answer.targetID != nil, target == nil,
               answer.values == nil, answer.weights.isEmpty, !answer.isLocalProduct {
                // Pointed at a word retired without a successor (or one only
                // a newer data set has), or at an own product since deleted:
                // nothing to count with, so the name stays the gap it was.
                let trace = LocalAnswerTrace(answer: answer, targetName: nil, status: .unresolvedTarget)
                traces[known?.key ?? answer.writtenKey] = trace
                if let known, answer.hasOverrides { overriding.append((answer, known, false)) }
                continue
            }

            let subject: CatalogIngredient
            let isAddition: Bool
            if let known {
                subject = known
                isAddition = false
            } else {
                // Overrides alone make no word: they are about one that is
                // there, the catalog's or one an answer adds.
                guard answer.hasAnswer else { continue }
                guard addedKeys.insert(answer.writtenKey).inserted else { continue }
                // A word of its own: the target's aisle, nothing else of it.
                var word = CatalogIngredient(name: answer.name, category: target?.category)
                if answer.isLocalProduct {
                    word.product = CatalogProduct(brand: answer.brand ?? "", eans: answer.ean.map { [$0] } ?? [])
                }
                additions.append(word)
                subject = word
                isAddition = true
            }
            if answer.isLocalProduct { ownProducts[answer.key] = subject }
            let trace = LocalAnswerTrace(answer: answer, targetName: target?.name, status: .applied)
            traces[subject.key] = trace
            traces[answer.writtenKey] = trace
            if answer.hasOverrides { overriding.append((answer, subject, isAddition)) }
            if answer.kind == .product, !answer.isLocalProduct, answer.category == nil, let target,
               answer.targetsOwnProduct || target.product != nil {
                productChoices.append((subject, isAddition, target))
            }

            let parent = Self.parent(of: answer, subject: subject, in: base)
            if answer.hasAnswer || parent != nil {
                steps.append(Applied.Step(
                    subject: subject.name, targetName: target?.name, answer: answer, parentName: parent?.name
                ))
            }
        }

        var overrides = Overrides(base: base, additions: additions)
        for (answer, subject, isAddition) in overriding {
            overrides.apply(answer, to: subject, isAddition: isAddition)
            // A silenced or unresolved answer's numbers do not speak, but its
            // parent still has to reach the table.
            guard !steps.contains(where: { $0.answer.key == answer.key }),
                  let parent = Self.parent(of: answer, subject: subject, in: base)
            else { continue }
            steps.append(Applied.Step(
                subject: subject.name, targetName: nil, answer: answer, parentName: parent.name,
                numbersSilent: true
            ))
        }

        // After the overrides, so a product's own aisle is the one taken.
        for choice in productChoices {
            overrides.takeAisle(of: choice.product, for: choice.subject, isAddition: choice.isAddition)
        }

        let catalog = overrides.additions.isEmpty && overrides.changed.isEmpty
            ? base
            : IngredientCatalog(
                ingredients: overrides.additions
                    + overrides.changed.values.sorted { $0.key < $1.key }
                    + base.ingredients,
                renames: base.renames
            )
        return Applied(
            catalog: catalog, traces: traces, steps: steps, addedNames: additions.map(\.name),
            conflicts: overrides.conflicts, folded: overrides.folded,
            overrideSignature: answers.filter(\.hasOverrides).map(\.readingSignature)
        )
    }

    /// The household's parent for `subject`, where it names a word the
    /// catalog has — and not the word itself.
    private static func parent(
        of answer: LocalAnswer, subject: CatalogIngredient, in base: IngredientCatalog
    ) -> CatalogIngredient? {
        guard let parentID = answer.parentID,
              let parent = base.resolve(id: parentID).ingredient,
              parent.key != subject.key
        else { return nil }
        return parent
    }

    /// Lays the overrides onto the words they are about, and says where the
    /// catalog disagrees or has come to agree.
    private struct Overrides {
        let base: IngredientCatalog
        var additions: [CatalogIngredient]
        /// Catalog words as the overrides leave them — in front of the base
        /// list, so they win their names and spellings.
        var changed: [String: CatalogIngredient] = [:]
        var conflicts: [CatalogConflict] = []
        var folded: [CatalogConflict] = []

        init(base: IngredientCatalog, additions: [CatalogIngredient]) {
            self.base = base
            self.additions = additions
        }

        /// The word under `key` as it stands now: changed, added, or the
        /// catalog's.
        private func current(_ key: String) -> CatalogIngredient? {
            changed[key] ?? additions.first { $0.key == key } ?? base.ingredient(spelledExactly: key)
                .flatMap { $0.key == key ? $0 : nil }
        }

        private mutating func store(_ word: CatalogIngredient, isAddition: Bool) {
            if isAddition, let index = additions.firstIndex(where: { $0.key == word.key }) {
                additions[index] = word
            } else {
                changed[word.key] = word
            }
        }

        /// `subject` stands in the aisle `product` stands in now — its own,
        /// or the one the household gave it. Derived, never an override: it
        /// follows the product and asks nothing.
        mutating func takeAisle(of product: CatalogIngredient, for subject: CatalogIngredient, isAddition: Bool) {
            // `ownCategory` first: a word changed here is resolved only when
            // the household catalog is built from it.
            let now = current(product.key) ?? product
            let aisle = now.ownCategory ?? now.category
            var word = current(subject.key) ?? subject
            guard (word.ownCategory ?? word.category) != aisle else { return }
            word.ownCategory = aisle
            store(word, isAddition: isAddition)
        }

        mutating func apply(_ answer: LocalAnswer, to subject: CatalogIngredient, isAddition: Bool) {
            var word = current(subject.key) ?? subject
            // What the catalog says about the word — nothing for one only
            // the household knows.
            let catalogWord: CatalogIngredient? = isAddition ? nil : subject
            let shown = answer.displayName ?? word.shownName
            func report(_ place: CatalogConflict.Place, value: String, says: String, local: String, folds: Bool) {
                let conflict = CatalogConflict(
                    answerKey: answer.key, word: shown, place: place,
                    catalogValue: value, catalogSays: says, localSays: local
                )
                if folds { folded.append(conflict) } else { conflicts.append(conflict) }
            }

            if let category = answer.category {
                if let catalogWord {
                    let now = catalogWord.category
                    if now == category {
                        report(.category, value: now.rawValue, says: now.title, local: category.title, folds: true)
                    } else if now != answer.baseline?.category {
                        report(.category, value: now.rawValue, says: now.title, local: category.title, folds: false)
                    }
                }
                word.ownCategory = category
            }

            if let parent = LocalAnswerSet.parent(of: answer, subject: subject, in: base) {
                if let catalogWord {
                    let nowParent = catalogWord.parentName.flatMap(base.ingredient(for:))
                    let now = nowParent?.catalogID ?? ""
                    let says = nowParent.map { "Sorte von \($0.name)" } ?? "keine Sorte"
                    let local = "Sorte von \(parent.name)"
                    if now == parent.catalogID {
                        report(.parent, value: now, says: says, local: local, folds: true)
                    } else if now != answer.baseline?.parentID {
                        report(.parent, value: now, says: says, local: local, folds: false)
                    }
                }
                word.parentName = parent.name
            }

            for spelling in answer.spellings {
                let key = IngredientCatalog.normalize(spelling)
                guard !key.isEmpty, key != word.key else { continue }
                let owner = base.ingredient(spelledExactly: spelling)
                let local = "„\(spelling)“ ist \(shown)"
                if let owner, owner.key == word.key {
                    // The catalog gives the spelling to this very word now.
                    report(.spelling(spelling), value: owner.catalogID ?? owner.key, says: local, local: local, folds: true)
                    continue
                }
                if let owner {
                    let value = owner.catalogID ?? owner.key
                    if answer.baseline?.spellingOwners[key] != value {
                        report(
                            .spelling(spelling), value: value,
                            says: "„\(spelling)“ ist \(owner.name)", local: local, folds: false
                        )
                    }
                    // Local wins: the other word lets go of the spelling. Its
                    // own name cannot be taken from it; there the household's
                    // word is simply found first.
                    if owner.key != key {
                        var other = current(owner.key) ?? owner
                        other.aliases.removeAll { IngredientCatalog.normalize($0) == key }
                        other.aliasUnits = other.aliasUnits.filter { IngredientCatalog.normalize($0.key) != key }
                        store(other, isAddition: false)
                    }
                }
                if !word.keys.contains(key) { word.aliases.append(spelling) }
            }

            if let displayName = answer.displayName,
               word.keys.contains(IngredientCatalog.normalize(displayName)) {
                word.displayName = displayName
            }
            store(word, isAddition: isAddition)
        }
    }

    /// The answers applied: the household catalog, the traces, and what the
    /// nutrition table has to take over.
    public struct Applied: Sendable {
        public let catalog: IngredientCatalog
        /// By normalized name — the written one and the one it resolves to.
        public let traces: [String: LocalAnswerTrace]
        let steps: [Step]
        /// The names the answers added to the catalog as words of their own,
        /// in the order the answers are kept — what decides whether the
        /// search index reads a recipe differently.
        public let addedNames: [String]
        /// Overrides the catalog has moved away from since the household
        /// decided — asked quietly in the ingredient's detail and on top of
        /// the catalog view ("Abweichungen"), never in a pop-up. Local still
        /// wins until the household takes the catalog's value.
        public let conflicts: [CatalogConflict]
        /// Overrides the catalog has come to agree with — redundant now, and
        /// folded away by the library without a question.
        public let folded: [CatalogConflict]
        /// What the overrides change about how recipes read — parents and
        /// spellings — for the library to tell whether the search index has
        /// to be rebuilt.
        public let overrideSignature: [String]

        init(
            catalog: IngredientCatalog,
            traces: [String: LocalAnswerTrace] = [:],
            steps: [Step] = [],
            addedNames: [String] = [],
            conflicts: [CatalogConflict] = [],
            folded: [CatalogConflict] = [],
            overrideSignature: [String] = []
        ) {
            self.catalog = catalog
            self.traces = traces
            self.steps = steps
            self.addedNames = addedNames
            self.conflicts = conflicts
            self.folded = folded
            self.overrideSignature = overrideSignature
        }

        struct Step: Sendable {
            /// The name the entry is filed under in the household catalog.
            let subject: String
            let targetName: String?
            let answer: LocalAnswer
            /// The household's parent for the subject, which a
            /// variety without values of its own inherits from.
            var parentName: String?
            /// Only the parent speaks: a "zählt wie" the catalog silenced
            /// keeps its override, not its numbers.
            var numbersSilent = false
        }

        public static let none = Applied(catalog: .current)

        /// What a local answer says about `name`, if one does — applied or
        /// fallen silent.
        public func trace(for name: String) -> LocalAnswerTrace? {
            traces[IngredientCatalog.normalize(name)]
                ?? catalog.ingredient(for: name).flatMap { traces[$0.key] }
        }

        /// The open conflicts of the answer under `key`.
        public func conflicts(forAnswerKey key: String) -> [CatalogConflict] {
            conflicts.filter { $0.answerKey == key }
        }

        /// `base` with the answers' numbers laid over it.
        ///
        /// A target lends its whole entry — values per state, weights, density
        /// — under the subject's name, so a name counted as Tofu is weighed
        /// and computed as Tofu. Own values then replace the basis, and each
        /// own weight replaces the weight for its unit.
        ///
        /// An own product without label values lends its target as an
        /// estimate ("Schätzung wie Hackfleisch"), like a catalog product's
        /// `like`; a name linked to an own product takes the product's entry
        /// as just computed, estimate and all.
        ///
        /// A household's parent is written onto the entry, so a
        /// variety without values of its own inherits its parent's — any
        /// depth, like a shipped one (``NutritionCatalog/nutrition(forCanonicalName:)``).
        public func nutrition(over base: NutritionCatalog) -> NutritionCatalog {
            guard !steps.isEmpty else { return base }
            var entries: [CatalogNutrition] = []
            var computed: [String: CatalogNutrition] = [:]
            for step in steps {
                let answer = step.answer
                let speaks = answer.hasAnswer && !step.numbersSilent
                var entry: CatalogNutrition
                if speaks, let targetName = step.targetName,
                   var lent = computed[IngredientCatalog.normalize(targetName)]
                       ?? base.nutrition(forCanonicalName: targetName) {
                    if answer.isLocalProduct, answer.values == nil {
                        entry = CatalogNutrition(name: step.subject, bases: [:], source: CatalogNutrition.ownSource)
                            .estimating(like: lent)
                    } else {
                        lent.name = step.subject
                        lent.parentName = nil
                        entry = lent
                    }
                } else if step.parentName != nil {
                    // The entry as written, not as inherited from the
                    // catalog's parent: the household's parent is the one to
                    // inherit from now.
                    entry = computed[IngredientCatalog.normalize(step.subject)]
                        ?? base.ownEntry(forCanonicalName: step.subject)
                        ?? CatalogNutrition(name: step.subject, bases: [:], source: CatalogNutrition.ownSource)
                } else {
                    entry = base.nutrition(forCanonicalName: step.subject)
                        ?? CatalogNutrition(name: step.subject, bases: [:], source: CatalogNutrition.ownSource)
                }
                if let parentName = step.parentName {
                    entry.parentName = parentName
                    if !entry.hasBases { entry.inheritedFrom = nil }
                }
                if speaks, let values = answer.values {
                    let source = answer.valuesSource ?? CatalogNutrition.ownSource
                    entry.bases = [IngredientState.unspecified.rawValue: NutritionBasis(
                        values: values, source: source
                    )]
                    entry.source = source
                    entry.inheritedFrom = nil
                }
                if speaks {
                    for (unit, weight) in answer.weights {
                        entry.unitWeightsGrams[unit] = weight.grams
                        entry.unitStates[unit] = weight.state
                    }
                }
                entries.append(entry)
                computed[IngredientCatalog.normalize(step.subject)] = entry
            }
            return base.replacing(entries)
        }
    }
}

/// One place where the catalog and a household's override part ways:
/// the catalog says something else than the household at the
/// same place, and has moved there since the household decided.
///
/// Asked quietly — "Der Katalog sagt jetzt … · deine Angabe …", with
/// "Katalog übernehmen" and "Meine behalten" — in the ingredient's detail
/// and under "Abweichungen" on top of the catalog view.
public struct CatalogConflict: Hashable, Sendable, Identifiable {
    public enum Place: Hashable, Sendable {
        case category
        case parent
        /// A spelling, as the household wrote it.
        case spelling(String)
    }

    /// The ``LocalAnswer/key`` of the answer holding the override.
    public let answerKey: String
    /// The word, as the household shows it.
    public let word: String
    public let place: Place
    /// What the catalog holds there now, as a baseline remembers it: a
    /// category's raw value, the parent's catalog id (`""` for none), or the
    /// id of the word the catalog gives the spelling to.
    public let catalogValue: String
    /// The same in words: "Brot & Backwaren", "Sorte von Weizenbrötchen",
    /// "„Schrippe“ ist Weizenbrötchen".
    public let catalogSays: String
    /// What the household says there.
    public let localSays: String

    public var id: String {
        switch place {
        case .category: "\(answerKey)|category"
        case .parent: "\(answerKey)|parent"
        case .spelling(let spelling): "\(answerKey)|spelling:\(IngredientCatalog.normalize(spelling))"
        }
    }

    /// "Der Katalog sagt jetzt: Brot & Backwaren · deine Angabe: Gemüse".
    public var message: String {
        "Der Katalog sagt jetzt: \(catalogSays) · deine Angabe: \(localSays)"
    }
}

extension LocalAnswer {
    /// What the answer's overrides change about how recipes read — its
    /// parent and its spellings.
    var readingSignature: String {
        let spellings = spellings.map(IngredientCatalog.normalize).sorted().joined(separator: ",")
        return "\(key)|\(parentID ?? "")|\(spellings)"
    }
}

/// What a local answer did to one name — what the detail view and the
/// drilldown say in a quiet line, never in a prompt.
public struct LocalAnswerTrace: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        /// The answer counts.
        case applied
        /// A "zählt wie" the catalog has since taken over, by the word named.
        case silenced(by: String)
        /// The target is gone without a successor; the name is a gap again.
        case unresolvedTarget
    }

    public let answer: LocalAnswer
    public let targetName: String?
    public let status: Status

    /// "lokal: zählt wie Tofu · jetzt vom Katalog beantwortet".
    public var label: String {
        var parts: [String] = []
        if answer.isLocalProduct {
            parts.append(answer.brand.map { "eigenes Produkt von \($0)" } ?? "eigenes Produkt")
            if let targetName, answer.values == nil { parts.append("Schätzung wie \(targetName)") }
        } else {
            switch answer.kind {
            case .countsAs: parts.append("zählt wie \(targetName ?? "?")")
            case .product: parts.append(targetName.map { "Produkt \($0)" } ?? "Produkt")
            case .word: parts.append("eigenes Wort, ohne Werte")
            case nil: break
            }
        }
        if answer.values != nil { parts.append("eigene Werte") }
        if !answer.weights.isEmpty { parts.append("eigene Gewichte") }
        if answer.category != nil { parts.append("eigene Kategorie") }
        if answer.parentID != nil { parts.append("eigene Sorte") }
        if !answer.spellings.isEmpty { parts.append("eigene Schreibweisen") }
        if answer.displayName != nil { parts.append("Anzeigename") }
        var label = "lokal: " + (parts.isEmpty ? "Angabe" : parts.joined(separator: ", "))
        switch status {
        case .applied: break
        case .silenced: label += " · jetzt vom Katalog beantwortet"
        case .unresolvedTarget: label += " · Ziel nicht mehr im Katalog"
        }
        return label
    }
}
