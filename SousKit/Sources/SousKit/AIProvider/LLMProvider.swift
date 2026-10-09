import Foundation

/// Which wire format a provider speaks.
public enum LLMProviderKind: String, Codable, Sendable, CaseIterable {
    /// Anthropic's Messages API (`/messages`).
    case anthropic
    /// The OpenAI chat-completions format (`/chat/completions`), which
    /// OpenAI, Grok, Gemini's compatibility endpoint and local servers such
    /// as Ollama or LM Studio all speak.
    case openAICompatible
}

/// Where a chat model is reached: the format, the endpoint and the model.
///
/// The key is not part of it. A key belongs to a person or a household and
/// is kept elsewhere; the provider only says what to talk to.
public struct LLMProvider: Codable, Hashable, Sendable {
    public var name: String
    public var kind: LLMProviderKind
    /// The base including the version path, without a trailing slash:
    /// `https://api.openai.com/v1`.
    public var baseURL: URL
    public var model: String
    /// How much an Anthropic model spends on thinking: `low`, `medium`,
    /// `high`, `xhigh` or `max`. `nil` leaves the model's own default
    /// (`medium` on Haiku 5.5). Ignored by the other format.
    public var effort: String?
    /// Turns thinking off on an Anthropic model; accepted up to `high` effort.
    public var disablesThinking: Bool?
    /// The entry of the community's catalog this was made from, or `nil` for
    /// a provider the cook entered. What the catalog knows (key page, advised
    /// models, a moved address) is looked up by it, never stored here.
    public var catalogID: String?

    public init(
        name: String, kind: LLMProviderKind, baseURL: URL, model: String,
        effort: String? = nil, disablesThinking: Bool? = nil, catalogID: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.effort = effort
        self.disablesThinking = disablesThinking
        self.catalogID = catalogID
    }

    /// The catalog's entry for this provider.
    public var catalogEntry: AIProviderCatalog.Entry? {
        catalogID.flatMap { AIProviderCatalog.current.entry(id: $0) }
    }

    /// Where the cook makes an API key for this provider, where the catalog
    /// knows it.
    public var keyPage: URL? { catalogEntry?.api?.keyPage }

    /// The providers the community has listed, to pick from. The model is left
    /// empty: the cook picks it from what the provider offers.
    public static var presets: [LLMProvider] {
        AIProviderCatalog.current.asking.compactMap { entry in
            guard let api = entry.api else { return nil }
            return LLMProvider(
                name: entry.name, kind: api.kind, baseURL: api.baseURL, model: "", catalogID: entry.id)
        }
    }
}

/// One turn of a conversation. The system prompt is not a turn; it is passed
/// next to the turns, because Anthropic takes it as a field of its own.
public struct LLMMessage: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public var role: Role
    public var text: String
    /// The start of the message that is the same on every request (rules,
    /// catalog), sent ahead of `text`. Anthropic is told to keep it; the
    /// others recognise a repeated start on their own, if it stays the first
    /// thing they are sent.
    public var cachedPrefix: String?

    public init(_ role: Role, _ text: String, cachedPrefix: String? = nil) {
        self.role = role
        self.text = text
        self.cachedPrefix = cachedPrefix
    }
}

/// A model's answer and what it cost in tokens. The counts are `nil` where
/// the provider did not report them.
public struct LLMReply: Sendable, Equatable {
    public var text: String
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// The model hit its token limit, so the text ends mid-sentence.
    public var wasCutOff: Bool = false
    /// Input tokens the provider took from its cache (at a fraction of the price), and
    /// tokens it wrote to the cache on this request (Anthropic only).
    public var cachedInputTokens: Int?
    public var cacheWriteTokens: Int?
}

/// A model a provider offers, as its model list names it.
public struct LLMModel: Hashable, Sendable, Identifiable {
    public var id: String
    /// What to show: the provider's display name where it has one, else the id.
    public var name: String

    public init(id: String, name: String? = nil) {
        self.id = id
        self.name = name ?? id
    }
}

public enum LLMError: Error, Equatable, Sendable {
    /// The key was refused (HTTP 401 or 403).
    case unauthorized(String?)
    /// The key's limit is used up or the provider asks to slow down (429).
    case rateLimited(String?)
    /// Any other non-2xx answer, with the provider's own message if it sent one.
    case server(status: Int, message: String?)
    /// The model stopped at its token limit; what it wrote ends mid-sentence.
    case cutOff
    /// The answer arrived but holds no text.
    case emptyAnswer
    /// The answer is not in the shape the provider's format promises.
    case malformedAnswer
}

extension LLMError {
    /// Whether another key might get through: this one was refused or is
    /// used up. A busy provider or an unreadable answer is not the key's fault.
    public var isTheKeysFault: Bool {
        switch self {
        case .unauthorized, .rateLimited: true
        default: false
        }
    }
}

extension LLMError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized(let detail):
            "Der Anbieter hat den Schlüssel abgelehnt.\(Self.suffix(detail))"
        case .rateLimited(let detail):
            "Das Limit des Schlüssels ist erreicht oder das Guthaben aufgebraucht.\(Self.suffix(detail))"
        case .server(let status, let detail) where status == 503 || status == 529:
            "Der Anbieter ist gerade überlastet (\(status)). Bitte gleich noch einmal versuchen.\(Self.suffix(detail))"
        case .server(let status, let detail):
            "Der Anbieter meldet einen Fehler (\(status)).\(Self.suffix(detail))"
        case .cutOff:
            "Die Antwort wurde abgeschnitten, weil das Modell sein Limit erreicht hat. Ein anderes Modell hilft meist."
        case .emptyAnswer:
            "Das Modell hat keine Antwort geschrieben."
        case .malformedAnswer:
            "Die Antwort des Anbieters ist nicht lesbar. Stimmen Adresse und Anbieterart?"
        }
    }

    private static func suffix(_ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return "" }
        return " (\(detail))"
    }
}
