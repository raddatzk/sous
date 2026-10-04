import Foundation

/// Which of a household's local answers are worth sharing with the curator,
/// and in what form (INGREDIENTS-DATA §3 D).
///
/// An answer is offered while it is unshared or changed since it was shared,
/// and only for what the catalog does not already answer:
/// - a "zählt wie" or an own word, while the catalog does not know the name
///   (it falls silent then anyway, R3);
/// - own values or weights for a catalog word, where they differ from the
///   catalog's;
/// - an own product, while the catalog has no product of that name.
///
/// A product *choice* — a name pointing at a brand — is never offered: it is
/// the household's purchase, and a generic word never becomes a public alias
/// of a brand (§3 I).
public enum CatalogSharing {
    /// One offered adjustment: what is sent, and the answer it comes from.
    public struct Offer: Identifiable, Hashable, Sendable {
        /// The answer's key, or "unknown:<normalized name>".
        public var id: String
        public var item: CatalogSubmission.Item
        /// `nil` for an unknown name nobody answered.
        public var answer: LocalAnswer?

        public init(id: String, item: CatalogSubmission.Item, answer: LocalAnswer?) {
            self.id = id
            self.item = item
            self.answer = answer
        }
    }

    /// Whether an answer was never shared, or changed since.
    public static func isPending(_ answer: LocalAnswer) -> Bool {
        guard let sharedAt = answer.sharedAt else { return true }
        return answer.updatedAt > sharedAt
    }

    /// The pending answers as offers, in the order of the sheet's groups and
    /// by name within each.
    ///
    /// - Parameters:
    ///   - catalog: the data set's catalog, without the local answers.
    ///   - nutrition: the data set's nutrition table, without them either.
    ///   - usage: where the names occur in the household's recipes.
    ///   - targetName: what a target id is shown as (an own product's name
    ///     or a catalog word's).
    public static func offers(
        _ answers: LocalAnswerSet,
        catalog: IngredientCatalog,
        nutrition: NutritionCatalog,
        usage: CatalogUsage = .empty,
        targetName: (String) -> String? = { _ in nil }
    ) -> [Offer] {
        answers.answers.filter(isPending).compactMap { answer in
            offer(for: answer, catalog: catalog, nutrition: nutrition, usage: usage, targetName: targetName)
        }
        .sorted { lhs, rhs in
            let left = Group(lhs.item.kind), right = Group(rhs.item.kind)
            if left != right { return left < right }
            return lhs.item.name.localizedStandardCompare(rhs.item.name) == .orderedAscending
        }
    }

    /// An unknown name nobody answered, as an offer — "An den Katalog
    /// melden" on its line.
    public static func unknown(_ name: String, usage: CatalogUsage = .empty) -> Offer {
        let use = usage.use(forName: name)
        let item = CatalogSubmission.Item(kind: .unknown, name: name, recipes: use?.recipes ?? 0, line: use?.line)
        return Offer(id: "unknown:\(IngredientCatalog.normalize(name))", item: item, answer: nil)
    }

    static func offer(
        for answer: LocalAnswer,
        catalog: IngredientCatalog,
        nutrition: NutritionCatalog,
        usage: CatalogUsage,
        targetName: (String) -> String?
    ) -> Offer? {
        let use = usage.use(forKey: answer.key)
        func target(_ id: String?) -> CatalogSubmission.Item.Target? {
            guard let id, !LocalAnswer.isKey(id) else { return nil }
            return CatalogSubmission.Item.Target(id: id, name: targetName(id) ?? catalog.ingredient(forID: id)?.name ?? id)
        }
        func make(
            _ kind: CatalogSubmission.Item.Kind,
            name: String,
            values: NutritionInfo? = answer.values,
            weights: [String: LocalAnswer.Weight] = answer.weights
        ) -> Offer {
            let item = CatalogSubmission.Item(
                kind: kind,
                name: name,
                catalogID: kind == .values ? answer.catalogID : nil,
                target: kind == .values ? nil : target(answer.targetID),
                values: values,
                source: values == nil ? nil : answer.valuesSource,
                weights: weights,
                brand: kind == .product ? answer.brand : nil,
                ean: kind == .product ? answer.ean : nil,
                recipes: use?.recipes ?? 0,
                line: use?.line
            )
            return Offer(id: answer.key, item: item, answer: answer)
        }

        // An own product: entered from a label, offered while the catalog
        // has no product of that name.
        if answer.isLocalProduct {
            if let known = catalog.ingredient(writtenAs: answer.name), known.product != nil { return nil }
            return make(.product, name: answer.name)
        }
        // A product choice is the household's purchase, never shared.
        if answer.kind == .product { return nil }

        // About a word the catalog knows: only what differs from it.
        if let catalogID = answer.catalogID {
            guard let word = catalog.ingredient(forID: catalogID) else { return nil }
            let entry = nutrition.nutrition(forCanonicalName: word.name)
            let values = answer.values.flatMap { values in
                entry?.bases.values.contains { $0.values.matches(values) } == true ? nil : values
            }
            let weights = answer.weights.filter { unit, weight in
                guard let known = entry?.unitWeightsGrams[unit] else { return true }
                return abs(known - weight.grams) >= 0.5
            }
            guard values != nil || !weights.isEmpty else { return nil }
            return make(.values, name: word.name, values: values, weights: weights)
        }

        // About a name the catalog does not know: a fallback falls silent
        // once it does, and so stops being worth sharing.
        if catalog.ingredient(writtenAs: answer.name) != nil { return nil }
        if answer.kind == .countsAs, answer.targetID.map(LocalAnswer.isKey) == false {
            return make(.countsAs, name: answer.name)
        }
        return make(.word, name: answer.name)
    }

    /// The sheet's groups (decided with the cook, 2026-10-03).
    public enum Group: Int, CaseIterable, Comparable, Sendable {
        case new, countsAs, values, product

        public init(_ kind: CatalogSubmission.Item.Kind) {
            switch kind {
            case .word, .unknown: self = .new
            case .countsAs: self = .countsAs
            case .values: self = .values
            case .product: self = .product
            }
        }

        public var title: String {
            switch self {
            case .new: "Neu"
            case .countsAs: "Zählt wie"
            case .values: "Werte & Gewichte"
            case .product: "Produkte"
            }
        }

        /// What the group means, under its title.
        public var footer: String {
            switch self {
            case .new: "Namen, die der Katalog noch nicht kennt."
            case .countsAs: "Ob Schreibweise oder Sorte, entscheidet der Katalog."
            case .values: "Wo deine Angaben von denen des Katalogs abweichen."
            case .product: "Eigene Produkte, mit den Werten vom Etikett."
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }
}

extension NutritionInfo {
    /// Whether two sets of values are the same figures, give or take
    /// rounding — an own value copied from the very BLS row the catalog
    /// uses is not news.
    func matches(_ other: NutritionInfo) -> Bool {
        abs(kcal - other.kcal) < 0.5
            && abs(proteinG - other.proteinG) < 0.05
            && abs(fatG - other.fatG) < 0.05
            && abs(carbsG - other.carbsG) < 0.05
    }
}

/// Where names occur in a household's recipes: how many recipes, and one
/// line as written — the context a shared item carries.
public struct CatalogUsage: Sendable {
    public struct Use: Hashable, Sendable {
        public var recipes: Int
        public var line: String
    }

    /// By ``LocalAnswer/key``: "name:<normalized>" for every name read, and
    /// "id:<catalog id>" for the catalog words.
    private var uses: [String: Use]

    public static let empty = CatalogUsage(uses: [:])

    private init(uses: [String: Use]) {
        self.uses = uses
    }

    /// Reads every recipe's ingredient list against `catalog` — the
    /// household's, so a name only a local answer taught is read as one.
    public init(ingredientTexts: [String], catalog: IngredientCatalog) {
        var uses: [String: Use] = [:]
        for text in ingredientTexts {
            let lines = IngredientLineReader.writtenLines(in: text)
            let read = IngredientLineReader.read(text, catalog: catalog)
            var seen = Set<String>()
            for (ingredient, written) in zip(read, lines) {
                let name = ShoppingItem.displayName(for: ingredient.name)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard name.count >= 2 else { continue }
                var keys = ["name:\(IngredientCatalog.normalize(name))"]
                if let id = catalog.ingredient(for: name)?.catalogID { keys.append("id:\(id)") }
                for key in keys where seen.insert(key).inserted {
                    uses[key, default: Use(recipes: 0, line: written.text)].recipes += 1
                }
            }
        }
        self.uses = uses
    }

    public func use(forKey key: String) -> Use? { uses[key] }

    public func use(forName name: String) -> Use? {
        uses["name:\(IngredientCatalog.normalize(name))"]
    }
}

/// When the nudge card shows, per device (§3 D): at least five pending
/// answers, and at least 30 days since "Später" or the last share. "Nicht
/// mehr fragen" hides the card only; sharing from Settings stays.
public struct CatalogNudge: @unchecked Sendable {
    public static let minimumPending = 5
    public static let interval: TimeInterval = 30 * 24 * 3600

    public static let lastKey = "catalogNudge.last"
    public static let neverAskKey = "catalogNudge.neverAsk"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var neverAsk: Bool {
        get { defaults.bool(forKey: Self.neverAskKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.neverAskKey) }
    }

    public var last: Date? {
        let seconds = defaults.double(forKey: Self.lastKey)
        return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
    }

    public func shows(pending: Int, now: Date = .now) -> Bool {
        guard !neverAsk, pending >= Self.minimumPending else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last) >= Self.interval
    }

    /// "Später", or a share: the 30 days start again.
    public func restart(at now: Date = .now) {
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastKey)
    }
}

/// The client's cap on submissions (§3 D): at most three a day from one
/// device, so a record count stays small however the sheet is reached.
public struct CatalogSubmissionLog: @unchecked Sendable {
    public static let perDay = 3
    private static let key = "catalogSubmission.sent"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private func sent(since: Date) -> [Double] {
        ((defaults.array(forKey: Self.key) as? [Double]) ?? []).filter { $0 > since.timeIntervalSince1970 }
    }

    public func canSend(now: Date = .now) -> Bool {
        sent(since: now.addingTimeInterval(-24 * 3600)).count < Self.perDay
    }

    public func record(at now: Date = .now) {
        defaults.set(sent(since: now.addingTimeInterval(-24 * 3600)) + [now.timeIntervalSince1970], forKey: Self.key)
    }
}
