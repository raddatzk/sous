import CryptoKit
import Foundation

/// A household's local answers, and the precedence they are laid over the
/// catalog with (INGREDIENTS-DATA §3 B, R2, R3).
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
/// - **Recognition, never identity (R2).** A name the catalog does not know
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
                weights: answer.weights, brand: answer.brand, ean: answer.ean
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
    }

    // MARK: - Applying

    /// The answers laid over `base`: the catalog the household reads its
    /// recipes with, and what each answer did.
    public func applied(to base: IngredientCatalog) -> Applied {
        guard !answers.isEmpty else { return Applied(catalog: base, traces: [:], steps: [], addedNames: []) }

        var additions: [CatalogIngredient] = []
        var addedKeys: Set<String> = []
        var traces: [String: LocalAnswerTrace] = [:]
        var steps: [Applied.Step] = []
        /// The household's own products by their answer's key, for a name's
        /// product choice to point at (phase 7b).
        var ownProducts: [String: CatalogIngredient] = [:]

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
                continue
            }

            if answer.kind != nil, answer.targetID != nil, target == nil,
               answer.values == nil, answer.weights.isEmpty, !answer.isLocalProduct {
                // Pointed at a word retired without a successor (or one only
                // a newer data set has), or at an own product since deleted:
                // nothing to count with, so the name stays the gap it was.
                let trace = LocalAnswerTrace(answer: answer, targetName: nil, status: .unresolvedTarget)
                traces[known?.key ?? answer.writtenKey] = trace
                continue
            }

            let subject: CatalogIngredient
            if let known {
                subject = known
            } else {
                guard addedKeys.insert(answer.writtenKey).inserted else { continue }
                // A word of its own: the target's aisle, nothing else of it.
                var word = CatalogIngredient(name: answer.name, category: target?.category)
                if answer.isLocalProduct {
                    word.product = CatalogProduct(brand: answer.brand ?? "", eans: answer.ean.map { [$0] } ?? [])
                }
                additions.append(word)
                subject = word
            }
            if answer.isLocalProduct { ownProducts[answer.key] = subject }
            let trace = LocalAnswerTrace(answer: answer, targetName: target?.name, status: .applied)
            traces[subject.key] = trace
            traces[answer.writtenKey] = trace
            steps.append(Applied.Step(subject: subject.name, targetName: target?.name, answer: answer))
        }

        let catalog = additions.isEmpty
            ? base
            : IngredientCatalog(ingredients: additions + base.ingredients, renames: base.renames)
        return Applied(catalog: catalog, traces: traces, steps: steps, addedNames: additions.map(\.name))
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

        struct Step: Sendable {
            /// The name the entry is filed under in the household catalog.
            let subject: String
            let targetName: String?
            let answer: LocalAnswer
        }

        public static let none = Applied(catalog: .current, traces: [:], steps: [], addedNames: [])

        /// What a local answer says about `name`, if one does — applied or
        /// fallen silent.
        public func trace(for name: String) -> LocalAnswerTrace? {
            traces[IngredientCatalog.normalize(name)]
                ?? catalog.ingredient(for: name).flatMap { traces[$0.key] }
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
        public func nutrition(over base: NutritionCatalog) -> NutritionCatalog {
            guard !steps.isEmpty else { return base }
            var entries: [CatalogNutrition] = []
            var computed: [String: CatalogNutrition] = [:]
            for step in steps {
                let answer = step.answer
                var entry: CatalogNutrition
                if let targetName = step.targetName,
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
                } else {
                    entry = base.nutrition(forCanonicalName: step.subject)
                        ?? CatalogNutrition(name: step.subject, bases: [:], source: CatalogNutrition.ownSource)
                }
                if let values = answer.values {
                    let source = answer.valuesSource ?? CatalogNutrition.ownSource
                    entry.bases = [IngredientState.unspecified.rawValue: NutritionBasis(
                        values: values, source: source
                    )]
                    entry.source = source
                    entry.inheritedFrom = nil
                }
                for (unit, weight) in answer.weights {
                    entry.unitWeightsGrams[unit] = weight.grams
                    entry.unitStates[unit] = weight.state
                }
                entries.append(entry)
                computed[IngredientCatalog.normalize(step.subject)] = entry
            }
            return base.replacing(entries)
        }
    }
}

/// What a local answer did to one name — what the detail view and the
/// drilldown say in a quiet line, never in a prompt (R3).
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
        var label = "lokal: " + (parts.isEmpty ? "Angabe" : parts.joined(separator: ", "))
        switch status {
        case .applied: break
        case .silenced: label += " · jetzt vom Katalog beantwortet"
        case .unresolvedTarget: label += " · Ziel nicht mehr im Katalog"
        }
        return label
    }
}
