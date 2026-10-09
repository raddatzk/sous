import CoreData
import Foundation
import Testing
@testable import SousKit

@Suite("A household's AI connection")
struct HouseholdAIConnectionTests {
    private let connection = AIConnection(
        provider: LLMProvider(
            name: "Anthropic", kind: .anthropic, baseURL: URL(string: "https://api.anthropic.com/v1")!,
            model: "claude-haiku-5-5", effort: "low", disablesThinking: true),
        apiKey: "sk-test")

    @Test("Core Data keeps one per household, replaces it on save and forgets it on delete")
    func store() async throws {
        let container = try SousPersistentContainer.make(inMemory: true)
        let store = CoreDataAIConnectionStore(container: container)
        #expect(try await store.load() == nil)

        try await store.save(connection)
        #expect(try await store.load() == connection)

        var other = connection
        other.provider.model = "claude-sonnet-5-5"
        other.apiKey = "sk-other"
        try await store.save(other)
        #expect(try await store.load() == other)

        // Replaced, not added: one row.
        let context = container.viewContext
        let count = try await context.perform {
            try context.count(for: CDAIConnection.fetchRequest())
        }
        #expect(count == 1)

        try await store.delete()
        #expect(try await store.load() == nil)
    }

    @Test("A provider that is not set up for effort or thinking comes back without them")
    func plain() async throws {
        let container = try SousPersistentContainer.make(inMemory: true)
        let store = CoreDataAIConnectionStore(container: container)
        let plain = AIConnection(
            provider: LLMProvider(name: "Grok", kind: .openAICompatible, baseURL: URL(string: "https://api.x.ai/v1")!, model: "m"),
            apiKey: "k")
        try await store.save(plain)
        #expect(try await store.load() == plain)
    }

    @Test("Only the key is stored encrypted in CloudKit, and the row is walked with the household's other members")
    func encryption() throws {
        let model = SousManagedObjectModel.shared
        let entity = try #require(model.entitiesByName[SousManagedObjectModel.aiConnectionEntityName])
        let encrypted = entity.properties.compactMap { $0 as? NSAttributeDescription }.filter(\.allowsCloudEncryption).map(\.name)
        #expect(encrypted == ["apiKey"])
        #expect(SousManagedObjectModel.memberEntityNames.contains(SousManagedObjectModel.aiConnectionEntityName))
        #expect(entity.relationshipsByName["household"] != nil)
    }

    @Test("A store from before the connection opens, keeps its recipes, and takes one")
    func oldStore() async throws {
        let url = try ScratchStore.makeURL()
        defer { ScratchStore.remove(url) }
        let old = SousManagedObjectModel.makeModel(includingRetiredEntities: true, includingAIConnections: false)
        #expect(old.entitiesByName[SousManagedObjectModel.aiConnectionEntityName] == nil)

        let before = try ScratchStore.open(url, with: old)
        let saved = try await CoreDataRecipeStore(container: before)
            .save(Recipe(title: "Brot", servings: 4, ingredientsText: "500 g Mehl"))
        try ScratchStore.close(before)

        let after = try ScratchStore.open(url, with: SousManagedObjectModel.shared)
        #expect(try await CoreDataRecipeStore(container: after).recipe(id: saved.id)?.title == "Brot")
        let store = CoreDataAIConnectionStore(container: after)
        try await store.save(connection)
        #expect(try await store.load() == connection)
        try ScratchStore.close(after)
    }

    @Test("A refused or used-up key may try another; a busy provider may not")
    func keysFault() {
        #expect(LLMError.unauthorized(nil).isTheKeysFault)
        #expect(LLMError.rateLimited("no credits").isTheKeysFault)
        #expect(!LLMError.server(status: 503, message: nil).isTheKeysFault)
        #expect(!LLMError.cutOff.isTheKeysFault)
    }
}

extension StubbedNetwork {
    @MainActor
    @Suite("Trying another key in a chat")
    struct RecipeEditChatRetryTests {
        private let provider = LLMProvider(
            name: "T", kind: .openAICompatible, baseURL: URL(string: "https://t.example/v1")!, model: "m")

        private func client(key: String) -> LLMClient {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubURLProtocol.self]
            return LLMClient(
                provider: provider, apiKey: key, session: URLSession(configuration: configuration), retryDelays: [])
        }

        @Test("The refused question is asked again through the other key, once")
        func retry() async {
            nonisolated(unsafe) var keys: [String] = []
            StubURLProtocol.handler = { request in
                let key = request.value(forHTTPHeaderField: "Authorization") ?? ""
                keys.append(key)
                if key == "Bearer personal" { return (401, Data(#"{"error":{"message":"bad key"}}"#.utf8)) }
                let chunk = #"data: {"choices":[{"delta":{"content":"Ok. ```json\n{\"title\":\"T\",\"ingredients\":[\"1 Ei\"],\"steps\":[\"Braten.\"]}\n```"}}]}"#
                return (200, Data((chunk + "\n\ndata: [DONE]\n\n").utf8))
            }
            let chat = RecipeEditChat(client: client(key: "personal"))
            chat.start(prompt: "PROMPT", shown: "Vegan")
            while chat.isAnswering { await Task.yield() }

            #expect((chat.failureError as? LLMError)?.isTheKeysFault == true)
            #expect(chat.proposal == nil)

            chat.retry(using: client(key: "household"))
            while chat.isAnswering { await Task.yield() }

            #expect(keys == ["Bearer personal", "Bearer household"])
            #expect(chat.failure == nil)
            #expect(chat.proposal?.title == "T")
            // The cook asked once.
            #expect(chat.turns.filter { $0.kind == .cook }.count == 1)
        }

        @Test("Nothing to retry, nothing happens")
        func nothingToRetry() async {
            let chat = RecipeEditChat(client: client(key: "k"))
            chat.retry(using: client(key: "other"))
            #expect(!chat.isAnswering)
            #expect(chat.turns.isEmpty)
        }
    }
}
