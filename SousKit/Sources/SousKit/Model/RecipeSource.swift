import Foundation

/// Where a recipe came from. `kind` stays meaningful even when the URL is
/// gone, and marks AI-generated recipes as such.
public struct RecipeSource: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case manual
        case web
        case video
        case generated
    }

    public var kind: Kind
    public var url: URL?
    /// Human-readable origin: a site name, a channel, an author.
    public var name: String?

    public init(kind: Kind, url: URL? = nil, name: String? = nil) {
        self.kind = kind
        self.url = url
        self.name = name
    }

    public static let manual = RecipeSource(kind: .manual)
}
