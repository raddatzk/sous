import Foundation

/// The link between the two lists: which BLS rows a kitchen word means.
///
/// ``KitchenWords`` is how a cook writes, `bls.json` is how a food table
/// writes, and this says which is which. It is the handwork — the part no
/// name comparison can do for you, because "Zwiebel" and "Speisezwiebel
/// tiefgefroren, geschmort ohne Fett" have no spelling in common worth
/// matching on.
///
/// It is read as it is written and never derived. It used to be derived for
/// 57 of the words, as a by-product of the build's name analysis, which meant
/// the mapping for those words existed nowhere anybody could read or correct
/// it — a re-run could quietly decide differently. Those 57 are written down
/// now, and the build infers nothing.
///
/// The cook extends it, too: assigning a basis to an ingredient
/// (`IngredientCatalogLibrary.setBasis`) is an entry in this same mapping,
/// stored on the cook's side and laid over the shipped one.
public struct IngredientCuration: Sendable {
    /// What one kitchen word means, per preparation state.
    public struct Entry: Codable, Sendable, Hashable {
        /// State → codes, best first. The first code of a state is the basis
        /// — the numbers the app shows; the rest are alternatives the picker
        /// offers.
        public var targets: [String: [String]]
        /// Further rows that could mean the same word. Offered, never
        /// computed with — kept apart from `targets` so that a word left
        /// without values on purpose cannot quietly acquire some.
        public var candidates: [String]
        /// Why this mapping was chosen, in the curator's words. Not read by
        /// the app; it is here so the next person to look knows.
        public var via: String?

        public init(targets: [String: [String]], candidates: [String] = [], via: String? = nil) {
            self.targets = targets
            self.candidates = candidates
            self.via = via
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                targets: try container.decodeIfPresent([String: [String]].self, forKey: .targets) ?? [:],
                candidates: try container.decodeIfPresent([String].self, forKey: .candidates) ?? [],
                via: try container.decodeIfPresent(String.self, forKey: .via)
            )
        }
    }

    private struct File: Decodable {
        var words: [String: Entry]
    }

    public private(set) var words: [String: Entry]

    public init(words: [String: Entry]) {
        self.words = words
    }

    public func entry(for word: String) -> Entry? {
        words[word]
    }

    /// The mapping shipped with the app — `curation.json`, verbatim.
    public static let bundled: IngredientCuration = {
        guard let url = Bundle.module.url(forResource: "curation", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else {
            assertionFailure("The bundled curation is missing or unreadable")
            return IngredientCuration(words: [:])
        }
        return IngredientCuration(words: file.words)
    }()
}
