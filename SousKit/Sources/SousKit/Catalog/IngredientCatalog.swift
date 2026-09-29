import Foundation

/// Known ingredients, with the spellings they answer to.
///
/// Free-text recipes write the same thing many ways — "Tomate", "Tomaten",
/// "Cocktailtomaten". Resolving them to one entry is what lets a shopping
/// list add them up, group them by aisle, and later match them against a
/// nutrition database.
public struct IngredientCatalog: Sendable {
    private var byKey: [String: CatalogIngredient]
    public private(set) var ingredients: [CatalogIngredient]

    /// Both the index and the list are deduplicated by key, first occurrence
    /// winning — the caller puts the entries that should win in front (the
    /// cook's own before the bundled ones), and a name defined twice has to
    /// resolve to one entry *and* show up once in a list of them.
    ///
    /// Categories are resolved here, once, for the whole list: a variety that
    /// writes none takes the nearest ancestor's, and every reader downstream
    /// sees a plain `category` without knowing where it came from. Done at
    /// build time rather than at lookup because the shopping list, the
    /// filter and the browser all read it in loops.
    ///
    /// Indexed twice: once as written, so the chain can be walked through
    /// every spelling a parent might be named by, and once more with the
    /// categories filled in, which is what every reader sees. The walk is
    /// ``categorySource(for:)`` — the same one the ingredient form uses to
    /// say "wie Tomate (Gemüse)", so the two can never disagree.
    public init(ingredients: [CatalogIngredient]) {
        var representatives: [CatalogIngredient] = []
        var takenKeys = Set<String>()
        for ingredient in ingredients where takenKeys.insert(ingredient.key).inserted {
            representatives.append(ingredient)
        }
        byKey = Self.index(representatives)
        self.ingredients = representatives
        let resolved = representatives.map { ingredient -> CatalogIngredient in
            var copy = ingredient
            copy.category = categorySource(of: ingredient)?.category ?? .other
            return copy
        }
        byKey = Self.index(resolved)
        self.ingredients = resolved.sorted { $0.name < $1.name }
    }

    /// Every spelling pointing at its ingredient, first definition winning.
    private static func index(_ ingredients: [CatalogIngredient]) -> [String: CatalogIngredient] {
        var byKey: [String: CatalogIngredient] = [:]
        for ingredient in ingredients {
            for key in ingredient.keys where byKey[key] == nil {
                byKey[key] = ingredient
            }
        }
        return byKey
    }

    /// The catalog shipped with the app — the identity half of the synonym
    /// table, which is where the names and their spellings now live. One file
    /// for one thing: a word, what it answers to, what it means.
    public static let bundled: IngredientCatalog = {
        IngredientCatalog(ingredients: SynonymTable.bundled.catalogIngredients)
    }()

    /// Looks up an ingredient by any of its spellings.
    ///
    /// Falls back to a naive German plural: dropping a trailing "n" or "en"
    /// catches the regular cases the catalog does not list by hand. And to a
    /// variety written the list way round — "Zwiebel, rot" is "Rote
    /// Zwiebel" — which is also what keeps the parser from splitting such a
    /// line into an onion prepared "rot".
    public func ingredient(for name: String) -> CatalogIngredient? {
        if let match = spelled(name) { return match }

        guard let commaIndex = name.lastIndex(of: ",") else { return nil }
        let head = String(name[..<commaIndex]).trimmingCharacters(in: .whitespaces)
        let tail = String(name[name.index(after: commaIndex)...])
        guard !head.isEmpty else { return nil }
        return ingredient(for: head, qualifiedBy: tail)
    }

    /// The ingredient a name with a trailing qualifier means, when the
    /// catalog files it the other way round: "Zwiebel" and "rot" are "Rote
    /// Zwiebel", "Kartoffeln" and "festkochend" are "Festkochende
    /// Kartoffeln".
    ///
    /// Only a one-word qualifier is turned around, bare and with the German
    /// adjective ending — that covers how people shorten a variety, and
    /// anything longer is a phrase, not a word to put in front. Never a
    /// state or qualifier word ("gegart", "TK"): those stay the preparation
    /// they are, so the line keeps its state and the shopping list keeps
    /// bundling canned tomatoes under "Tomate". `nil` when no reading is a
    /// known ingredient.
    public func ingredient(for name: String, qualifiedBy qualifier: String) -> CatalogIngredient? {
        let word = qualifier.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !word.contains(" "), !word.contains(","),
              !IngredientStateVocabulary.isVocabulary(word)
        else { return nil }
        for candidate in ["\(word) \(name)", "\(word)e \(name)", "\(name) \(word)"] {
            if let match = spelled(candidate) { return match }
        }
        return nil
    }

    /// A spelling or its naive plural — the lookup without the comma rule.
    private func spelled(_ name: String) -> CatalogIngredient? {
        let key = Self.normalize(name)
        if let match = byKey[key] { return match }

        for suffix in ["en", "n", "e", "s"] where key.hasSuffix(suffix) {
            let stem = String(key.dropLast(suffix.count))
            if stem.count >= 3, let match = byKey[stem] { return match }
        }
        return nil
    }

    /// The canonical name for a written one, or the written one unchanged.
    public func canonicalName(for name: String) -> String {
        ingredient(for: name)?.name ?? name
    }

    public func category(for name: String) -> IngredientCategory? {
        ingredient(for: name)?.category
    }

    /// Where an ingredient's category comes from: itself, when it writes one,
    /// or the nearest ancestor that does — named, so a form can say "wie
    /// Tomate (Gemüse)" rather than only show the aisle. `nil` when nothing
    /// up the chain writes one; the resolved category is then `.other`.
    public func categorySource(for name: String) -> (name: String, category: IngredientCategory)? {
        guard let match = ingredient(for: name) else { return nil }
        return categorySource(of: match)
    }

    private func categorySource(of ingredient: CatalogIngredient) -> (name: String, category: IngredientCategory)? {
        if let own = ingredient.ownCategory { return (ingredient.name, own) }
        for ancestor in ancestors(of: ingredient) {
            if let own = ancestor.ownCategory { return (ancestor.name, own) }
        }
        return nil
    }

    /// The name a line's *numbers* are looked up under, which is not always
    /// the name it is bought under.
    ///
    /// "Tomaten, Konserve" is one line about one thing, but the food catalog
    /// keeps canned tomatoes as their own row with their own values — see
    /// ``IngredientStateVocabulary``. So a qualifier is tried as part of the
    /// name here, and only here: the shopping list goes on bundling the line
    /// under plain "Tomate", because what the cook thought and what they buy
    /// did not change.
    ///
    /// Falls back to the plain canonical name whenever the qualified word is
    /// not one the catalog has — "Erbsen, TK" then counts as peas, which is
    /// closer than counting as nothing.
    public func nutritionName(for ingredient: RecipeIngredient) -> String {
        let base = canonicalName(for: ingredient.name)
        guard let qualifier = IngredientStateVocabulary.qualifier(in: ingredient.preparation)
        else { return base }
        // Both shapes the shipped names use: "Tomate Konserve" and
        // "Apfelkompott/Apfelmark, ungesüßt, Konserve".
        for candidate in ["\(base) \(qualifier)", "\(base), \(qualifier)"] {
            if let match = self.ingredient(for: candidate) { return match.name }
        }
        return base
    }

    /// The ingredient a written name shares a group with — the top of its
    /// variety chain, or itself where it is not a variety of anything.
    ///
    /// "Pilze" and "braune Champignons" share a group, so they are the same
    /// thing for search. Any depth, like every walk here (catalog target, decision A); a
    /// dangling relation falls back to the ingredient itself, because a
    /// parent nobody defined must not make a variety disappear. The shopping
    /// list no longer bundles under this — decision E — and takes what a
    /// variety inherits from ``ancestors(of:)`` instead, nearest first.
    public func groupIngredient(for name: String) -> CatalogIngredient? {
        guard let match = ingredient(for: name) else { return nil }
        return ancestors(of: match).last ?? match
    }

    /// Everything `name` is a variety of, nearest first: Brauner Champignon →
    /// [Champignon, Pilz].
    ///
    /// The chain may be any depth (catalog target, decision A), so this is
    /// what walks it — for the search index, which wants a recipe with braune
    /// Champignons to answer to "Pilz", and for the parent picker, which must
    /// not offer a descendant as a parent. A cycle cannot be written (the
    /// stores refuse one), but the walk still stops if it meets a key twice:
    /// a data file edited by hand is not a store.
    public func ancestors(of name: String) -> [CatalogIngredient] {
        guard let match = ingredient(for: name) else { return [] }
        return ancestors(of: match)
    }

    private func ancestors(of ingredient: CatalogIngredient) -> [CatalogIngredient] {
        var chain: [CatalogIngredient] = []
        var seen: Set<String> = [ingredient.key]
        var current = ingredient
        while let parentName = current.parentName,
              let parent = self.ingredient(for: parentName),
              seen.insert(parent.key).inserted {
            chain.append(parent)
            current = parent
        }
        return chain
    }

    /// The varieties of an ingredient, in name order — what an ingredient
    /// form lists under "Sorten".
    public func variants(of name: String) -> [CatalogIngredient] {
        let key = Self.normalize(name)
        return ingredients
            .filter { $0.parentName.map(Self.normalize) == key }
            .sorted { $0.name < $1.name }
    }

    /// Ingredients whose name or spellings start with, or contain, `text` —
    /// for suggesting while typing. Prefix matches come first.
    public func suggestions(for text: String, limit: Int = 8) -> [CatalogIngredient] {
        let query = Self.normalize(text)
        guard query.count >= 2 else { return [] }

        /// Lower sorts first: the name itself beats an alias, a short name
        /// beats a long one. "toma" should offer Tomate before Tomatenmark,
        /// and both before Gehackte Tomaten, which only matches on an alias.
        func rank(_ ingredient: CatalogIngredient) -> (Int, Int) {
            let name = Self.normalize(ingredient.name)
            if name.hasPrefix(query) { return (0, name.count) }
            if ingredient.keys.contains(where: { $0.hasPrefix(query) }) { return (1, name.count) }
            if name.contains(query) { return (2, name.count) }
            return (3, name.count)
        }

        return ingredients
            .filter { ingredient in
                ingredient.keys.contains { $0.contains(query) }
            }
            .sorted { first, second in
                rank(first) == rank(second)
                    ? first.name < second.name
                    : rank(first) < rank(second)
            }
            .prefix(limit)
            .map { $0 }
    }

    /// What an unknown name might already be, best first. This powers the sheet
    /// that opens when the cook taps a name the catalog does not know.
    ///
    /// The search goes word by word, because ``suggestions(for:limit:)``
    /// only looks at the whole string. That is right while the cook types one
    /// word, but a name copied from a recipe carries qualifiers.
    /// "dünne Kokosmilch" appears in no key at all, yet the catalog knows
    /// Kokosmilch and Kokosmilch fettarm. Those two are what the cook needs to
    /// see before deciding whether the name is a spelling of one, a variety of
    /// one, or something new.
    ///
    /// A query word matches a word of a key in one of three ways:
    /// - exactly;
    /// - as the start of the key's word, or with a plural ending the key lacks
    ///   ("Tomaten" matches "Tomate");
    /// - as a compound ending in the key's word, the way
    ///   ``VariantHeuristic`` reads German head nouns ("Kokosmilch" matches
    ///   "Milch").
    ///
    /// Candidates are ranked in this order:
    /// 1. the whole query starts a key;
    /// 2. the whole query appears somewhere in a key;
    /// 3. every query word is matched;
    /// 4. only some query words are matched.
    ///
    /// Within a rank, more and closer word matches come first, then the
    /// shorter name. Folding makes "kurbis" match "Kürbis", as in recipe
    /// search.
    ///
    /// Set `requiresEveryWord` to drop the looser matches. Only entries that
    /// answer every typed word exactly, by prefix or by plural are kept. The
    /// catalog list needs this: it sorts its hits by aisle and name, so a
    /// loose match would not stay at the end but land between the good ones.
    /// It still gains folding and free word order ("fettarm Kokosmilch").
    /// Short words count in strict mode because none of them can be
    /// dropped: "rote be" still finds Rote Bete.
    public func search(
        _ text: String, limit: Int = 60, requiresEveryWord: Bool = false
    ) -> [CatalogIngredient] {
        let query = RecipeSearchTerms.fold(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard query.count >= 2 else { return [] }
        let words = Self.words(of: query).filter { $0.count >= (requiresEveryWord ? 2 : 3) }
        // A compound's head noun (strength 1) is a loose match.
        let minimumStrength = requiresEveryWord ? 2 : 1

        /// Lower sorts first. The second value is negated closeness.
        func rank(_ ingredient: CatalogIngredient) -> (Int, Int)? {
            var best: (Int, Int)?
            for key in ingredient.keys.map(RecipeSearchTerms.fold) {
                let candidate: (Int, Int)
                if key.hasPrefix(query) {
                    candidate = (0, 0)
                } else if key.contains(query) {
                    candidate = (1, 0)
                } else {
                    let keyWords = Self.words(of: key)
                    let strengths = words.map { word in
                        keyWords.map { Self.strength(of: word, against: $0) }.max() ?? 0
                    }
                    let matched = strengths.filter { $0 >= minimumStrength }.count
                    guard matched > 0, !requiresEveryWord || matched == words.count else { continue }
                    candidate = (matched == words.count ? 2 : 3, -strengths.reduce(0, +))
                }
                if best == nil || candidate < best! { best = candidate }
            }
            return best
        }

        return ingredients
            .compactMap { ingredient in rank(ingredient).map { (ingredient, $0) } }
            .sorted { first, second in
                if first.1 != second.1 { return first.1 < second.1 }
                if first.0.name.count != second.0.name.count { return first.0.name.count < second.0.name.count }
                return first.0.name < second.0.name
            }
            .prefix(limit)
            .map(\.0)
    }

    private static func words(of text: String) -> [String] {
        text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// How closely one typed word answers one word of a key. The result is
    /// 0 for no match and 3 for an exact one.
    private static func strength(of word: String, against keyWord: String) -> Int {
        if word == keyWord { return 3 }
        if keyWord.hasPrefix(word) { return 2 }
        // A plural ending the key does not write ("Tomaten" / "Tomate"). This
        // is capped at two letters so that "Kokosmilch" does not match Kokos.
        if keyWord.count >= 3, word.hasPrefix(keyWord), word.count - keyWord.count <= 2 { return 2 }
        // A compound ending in the key's word: "Kokosmilch" matches Milch.
        if keyWord.count >= 3, word.hasSuffix(keyWord), word.count - keyWord.count >= 3 { return 1 }
        return 0
    }

    /// The ingredients named in a piece of text that this catalog does not
    /// know — what the editor offers to add, and what a recipe's "unknown
    /// ingredients" review checks against.
    public func unknownIngredients(in text: String) -> [String] {
        var seen = Set<String>()
        return IngredientParser.parse(text, catalog: self).compactMap { ingredient in
            let name = ShoppingItem.displayName(for: ingredient.name)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count >= 2,
                  // A link points at a recipe, not at something to look up.
                  RecipeLink.referencedIDs(in: ingredient.name).isEmpty,
                  self.ingredient(for: name) == nil,
                  seen.insert(Self.normalize(name)).inserted
            else { return nil }
            return name
        }
    }

    /// The form two spellings are compared in: composed (NFC), lowercased,
    /// ß written as ss, hyphens dropped, and whitespace trimmed and
    /// collapsed. So "Rote Bete" and "rote  bete" are one thing, and so are
    /// "Weißwein" and "Weisswein", "Hokkaido-Kürbis" and "Hokkaidokürbis".
    /// Accents stay: "Créme" is a typo of "Crème", not a spelling of it.
    ///
    /// `Scripts/data/compile.py` normalizes the same way when it checks that
    /// no two catalog spellings collide; `Data/normalize-cases.json` holds
    /// the cases both are tested against, so the two cannot drift apart.
    ///
    /// Not what the stores persist: see ``storageKey(_:)``.
    public static func normalize(_ name: String) -> String {
        let folded = name.precomposedStringWithCanonicalMapping
            .lowercased()
            .replacingOccurrences(of: "ß", with: "ss")
            .filter { !hyphens.contains($0) }
        return folded
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Hyphen-minus, hyphen and non-breaking hyphen. Not the dashes: " – "
    /// separates, it does not join.
    private static let hyphens: Set<Character> = ["-", "\u{2010}", "\u{2011}"]

    /// The key the vocabulary and shopping rows are stored under: trimmed
    /// and lowercased, nothing more — what ``normalize(_:)`` was before it
    /// learned to fold ß and hyphens.
    ///
    /// Frozen on purpose. An older app in the same household looks its rows
    /// up by exactly this string, and so does this one when it upserts a row
    /// written before the change: a stored field keeps its meaning (the
    /// schema only grows). Everything read back is compared through
    /// ``normalize(_:)``, which folds this key the same as the name it came
    /// from.
    public static func storageKey(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
