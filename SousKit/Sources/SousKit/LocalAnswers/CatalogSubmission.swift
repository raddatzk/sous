import Foundation

/// What a household sends the curator when it shares its adjustments of the
/// catalog (INGREDIENTS-DATA §3 D): one record in the CloudKit public
/// database, read by the nightly job in the private inbox repository and
/// filed there as issues (`Scripts/data/inbox.py`).
///
/// It holds what the share sheet showed, item by item, and nothing else: no
/// household, no recipe title, no pantry, store or note. The record's
/// creator is CloudKit's pseudonymous user id; the job uses it for its
/// nightly cap and never writes it into an issue.
public struct CatalogSubmission: Codable, Hashable, Sendable {
    /// The format of ``items``, which `inbox.py` checks before it reads them.
    public static let schema = 1
    /// At most this many items go into one submission.
    public static let maximumItems = 50

    public var items: [Item]
    /// "1.0 (12)": which app wrote it.
    public var app: String
    /// The data set the household's catalog was built on.
    public var dataVersion: Int

    public init(items: [Item], app: String, dataVersion: Int) {
        self.items = Array(items.prefix(Self.maximumItems))
        self.app = app
        self.dataVersion = dataVersion
    }

    /// One adjustment, as sent. The keys are the wire format `inbox.py`
    /// reads; a new one is added, an existing one never changes meaning.
    public struct Item: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
            /// An unknown name counts as a catalog word — an alias or a
            /// variety, which the curator decides.
            case countsAs
            /// An unknown name is a word of its own, with or without values.
            case word
            /// Own values or weights for a word the catalog knows.
            case values
            /// A product of the household's own, from its label.
            case product
            /// A name the catalog does not know and the household has not
            /// answered — "An den Katalog melden" on an unknown line.
            case unknown
            /// A catalog word the household files differently (phase 7d):
            /// another aisle (``category``), or a variety of another word
            /// (``parent``). Regional, perhaps; the curator decides.
            case catalogOverride = "override"
        }

        /// A catalog word, by its id and by the name it had when shared.
        public struct Target: Codable, Hashable, Sendable {
            public var id: String
            public var name: String

            public init(id: String, name: String) {
                self.id = id
                self.name = name
            }
        }

        public var kind: Kind
        /// As written in the household's recipes, or the catalog word's name
        /// for ``Kind/values``, or the product's name.
        public var name: String
        /// The word a ``Kind/values`` item is about.
        public var catalogID: String?
        /// What a name counts as; for a product, the word it counts like;
        /// for a household's own spelling, the word it spells.
        public var target: Target?
        /// Set where the household said the name is a *spelling* of
        /// ``target`` (phase 7d) — an alias, not a variety.
        public var spelling: Bool?
        /// The aisle the household files the word under, where it differs
        /// from the catalog's (phase 7d).
        public var category: IngredientCategory?
        /// The word the household files this one as a variety of, where it
        /// differs from the catalog's parent (phase 7d).
        public var parent: Target?
        /// Per 100 g.
        public var values: NutritionInfo?
        /// Where the values were read: "Packung, Marke X".
        public var source: String?
        /// By unit symbol.
        public var weights: [String: LocalAnswer.Weight]?
        public var brand: String?
        public var ean: String?
        /// In how many of the household's recipes the name occurs.
        public var recipes: Int
        /// One line naming it, as written — the context that tells an alias
        /// from a variety.
        public var line: String?

        public init(
            kind: Kind,
            name: String,
            catalogID: String? = nil,
            target: Target? = nil,
            spelling: Bool? = nil,
            category: IngredientCategory? = nil,
            parent: Target? = nil,
            values: NutritionInfo? = nil,
            source: String? = nil,
            weights: [String: LocalAnswer.Weight]? = nil,
            brand: String? = nil,
            ean: String? = nil,
            recipes: Int = 0,
            line: String? = nil
        ) {
            self.kind = kind
            self.name = Self.capped(name, 80)
            self.catalogID = catalogID
            self.target = target
            self.spelling = spelling == true ? true : nil
            self.category = category
            self.parent = parent
            self.values = values
            self.source = source.map { Self.capped($0, 200) }
            self.weights = weights?.isEmpty == true ? nil : weights
            self.brand = brand.map { Self.capped($0, 80) }
            self.ean = ean.map { Self.capped($0, 20) }
            self.recipes = recipes
            self.line = line.map { Self.capped($0, 200) }
        }

        /// Free text is cut, never refused: a long line still says enough.
        static func capped(_ text: String, _ limit: Int) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit))
        }
    }

    // MARK: - As text

    /// The items as JSON — the record's `items` field and the block of the
    /// text form.
    public var itemsJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(items)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The submission for a person to read and for a machine to take —
    /// "Als Text kopieren" and the GitHub issue form, where there is no
    /// iCloud account. The block carries the same JSON as the record.
    public var text: String {
        var text = "Sous – Vorschläge für den Zutatenkatalog\n"
        for item in items { text += "- \(item.summary)\n" }
        text += "\nSous \(app) · Daten \(dataVersion)\n\n"
        text += "```json sous-submission\n"
        text += "{\"schema\":\(Self.schema),\"app\":\(Self.jsonString(app)),\"dataVersion\":\(dataVersion),"
        text += "\"items\":\(itemsJSON)}\n```\n"
        return text
    }

    /// The public issue form of the `sous` repository, prefilled — the way
    /// without an iCloud account. Public, which the sheet says; `nil` when
    /// the text is too long for a link, and copying is the way then.
    public var issueFormURL: URL? {
        var components = URLComponents(string: "https://github.com/raddatzk/sous/issues/new")!
        let title = items.count == 1
            ? "Katalog: „\(items[0].name)“"
            : "Katalog: \(items.count) Vorschläge"
        components.queryItems = [
            URLQueryItem(name: "template", value: "katalog.yml"),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "meldung", value: text),
        ]
        guard let url = components.url, url.absoluteString.count <= 7_500 else { return nil }
        return url
    }

    private static func jsonString(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

extension CatalogSubmission.Item {
    /// One line, in the words the sheet uses: "„dünne Kokosmilch“ zählt wie
    /// Kokosmilch · in 2 Rezepten · „200 ml dünne Kokosmilch“".
    public var summary: String {
        ["„\(name)“ \(detail)", context].compactMap { $0 }.joined(separator: " · ")
    }

    /// What the item says about its name: "zählt wie Kokosmilch · 1 can =
    /// 240 g cooked".
    public var detail: String {
        var parts: [String] = []
        switch kind {
        case .countsAs where spelling == true: parts.append("Schreibweise von \(target?.name ?? "?")")
        case .countsAs: parts.append("zählt wie \(target?.name ?? "?")")
        case .word: parts.append("eigenes Wort")
        case .values: parts.append("eigene Angaben")
        case .product:
            var product = "Produkt"
            if let brand { product += ", Marke \(brand)" }
            if let ean { product += ", EAN \(ean)" }
            if let target { product += ", rechnet wie \(target.name)" }
            parts.append(product)
        case .unknown: parts.append("unbekannt")
        case .catalogOverride: parts.append("eigene Einordnung")
        }
        if let category { parts.append("Kategorie \(category.title)") }
        if let parent { parts.append("Sorte von \(parent.name)") }
        if let values {
            var text = "\(Self.number(values.kcal)) kcal/100 g"
            if let source { text += " (\(source))" }
            parts.append(text)
        }
        for (unit, weight) in (weights ?? [:]).sorted(by: { $0.key < $1.key }) {
            var text = "1 \(unit) = \(Self.number(weight.grams)) g"
            if let annotation = weight.state?.shoppingAnnotation { text += " \(annotation)" }
            parts.append(text)
        }
        return parts.joined(separator: " · ")
    }

    /// Where the name occurs: "in 2 Rezepten · „200 ml dünne Kokosmilch“".
    public var context: String? {
        var parts: [String] = []
        if recipes > 0 { parts.append("in \(recipes) \(recipes == 1 ? "Rezept" : "Rezepten")") }
        if let line { parts.append("„\(line)“") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
