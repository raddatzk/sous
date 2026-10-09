import Foundation

/// The AI providers the community maintains in `Community/ki/`, as
/// `compile.py` writes them to `ai_providers.json`: how to ask each one
/// directly (`api`), and where a cook who copies the prompt opens a chat
/// (`chat`).
///
/// It travels in the data set, so a model name or a chat link can change
/// without an app update. What a cook has saved does not travel with it: a
/// saved connection keeps the address it was made with, and only the cook
/// can move it (see ``AddressMove``).
public struct AIProviderCatalog: Sendable, Hashable {
    public struct Entry: Codable, Sendable, Hashable, Identifiable {
        public struct API: Codable, Sendable, Hashable {
            public struct Model: Codable, Sendable, Hashable, Identifiable {
                public var id: String
                public var effort: String?
                /// `false` turns thinking off; `nil` leaves the model as it comes.
                public var thinking: Bool?
            }

            /// An address the provider left, with where it said so.
            public struct Move: Codable, Sendable, Hashable {
                public var from: URL
                public var source: URL
                public var reason: String
            }

            public var format: String
            public var baseURL: URL
            public var keyPage: URL
            public var docs: URL
            public var models: [Model]
            public var moved: [Move]

            public init(
                format: String, baseURL: URL, keyPage: URL, docs: URL,
                models: [Model] = [], moved: [Move] = []
            ) {
                self.format = format
                self.baseURL = baseURL
                self.keyPage = keyPage
                self.docs = docs
                self.models = models
                self.moved = moved
            }

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                format = try c.decode(String.self, forKey: .format)
                baseURL = try c.decode(URL.self, forKey: .baseURL)
                keyPage = try c.decode(URL.self, forKey: .keyPage)
                docs = try c.decode(URL.self, forKey: .docs)
                models = try c.decode([Model].self, forKey: .models)
                moved = try c.decodeIfPresent([Move].self, forKey: .moved) ?? []
            }

            public var kind: LLMProviderKind { format == "anthropic" ? .anthropic : .openAICompatible }
        }

        public struct Chat: Codable, Sendable, Hashable {
            /// What the app stores for the cook's choice.
            public var id: String
            public var title: String
            public var url: URL
        }

        public var id: String
        public var name: String
        public var api: API?
        public var chat: Chat?

        public init(id: String, name: String, api: API? = nil, chat: Chat? = nil) {
            self.id = id
            self.name = name
            self.api = api
            self.chat = chat
        }
    }

    public var providers: [Entry]

    public init(providers: [Entry]) {
        self.providers = providers
    }

    init(json: Data) throws {
        struct File: Decodable { var providers: [Entry] }
        providers = try JSONDecoder().decode(File.self, from: json).providers
    }

    public func entry(id: String) -> Entry? { providers.first { $0.id == id } }

    /// The entry whose chat the cook's stored choice names.
    public func entry(chatID: String) -> Entry? { providers.first { $0.chat?.id == chatID } }

    /// The entries one can ask directly, in the data's order.
    public var asking: [Entry] { providers.filter { $0.api != nil } }

    /// The catalog of the data set this process runs on.
    public static var current: AIProviderCatalog { DataSet.current.aiProviders }

    /// The one the app ships. A data set from before the file existed has
    /// none of its own and falls back to this.
    static let bundled: AIProviderCatalog = {
        guard let url = DataSet.bundledURL(of: DataSet.File.aiProviders.fileName),
            let data = try? Data(contentsOf: url), let catalog = try? AIProviderCatalog(json: data)
        else { return AIProviderCatalog(providers: []) }
        return catalog
    }()
}
