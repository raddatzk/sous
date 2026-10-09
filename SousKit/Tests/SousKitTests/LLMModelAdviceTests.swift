import Foundation
import Testing
@testable import SousKit

@Suite("Choosing among a provider's models")
struct LLMModelAdviceTests {
    private func models(_ ids: String...) -> [LLMModel] { ids.map { LLMModel(id: $0) } }

    @Test("Models that do not write text are left out of the list")
    func filter() {
        let all = models(
            "gpt-5.4-mini", "text-embedding-3-small", "whisper-1", "gpt-image-2", "gpt-realtime",
            "gpt-4o-mini-tts", "omni-moderation-latest", "sora-2", "gemini-3.5-flash", "veo-3.1-generate-preview",
            "grok-imagine-video", "claude-haiku-5-5", "brand-new-model")
        #expect(LLMModelAdvice.chatModels(all).map(\.id) == [
            "gpt-5.4-mini", "gemini-3.5-flash", "claude-haiku-5-5", "brand-new-model",
        ])
    }

    @Test("A suggestion counts only if the provider still lists it")
    func suggestions() throws {
        let anthropic = try #require(LLMProvider.presets.first { $0.name == "Anthropic" })
        let listed = models("claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-5")
        #expect(LLMModelAdvice.suggestions(in: listed, for: anthropic).map(\.id) == [
            "claude-haiku-5-5", "claude-sonnet-5-5",
        ])
        #expect(LLMModelAdvice.suggestions(in: models("claude-opus-5"), for: anthropic).isEmpty)
    }

    @Test("Haiku 5.5 is asked with low effort and no thinking; others are left alone")
    func tuning() throws {
        var anthropic = try #require(LLMProvider.presets.first { $0.name == "Anthropic" })
        anthropic.model = "claude-haiku-5-5"
        let tuned = LLMModelAdvice.tuned(anthropic)
        #expect(tuned.effort == "low")
        #expect(tuned.disablesThinking == true)

        anthropic.model = "claude-haiku-4-5-20251001"
        #expect(LLMModelAdvice.tuned(anthropic) == anthropic)

        anthropic.model = "claude-haiku-5-5"
        anthropic.effort = "high"
        #expect(LLMModelAdvice.tuned(anthropic) == anthropic)
    }

    @Test("A custom provider has no suggestions")
    func custom() {
        let custom = LLMProvider(name: "Ollama", kind: .openAICompatible, baseURL: URL(string: "http://localhost:11434/v1")!, model: "")
        #expect(LLMModelAdvice.suggestions(in: models("llama3"), for: custom).isEmpty)
    }
}

@Suite("Where to get a key")
struct LLMKeyPageTests {
    @Test("Every provider Sous names has a page to make a key, a custom one has none")
    func keyPages() {
        for preset in LLMProvider.presets {
            #expect(preset.keyPage?.scheme == "https", "\(preset.name)")
        }
        let custom = LLMProvider(name: "Ollama", kind: .openAICompatible, baseURL: URL(string: "http://localhost:11434/v1")!, model: "")
        #expect(custom.keyPage == nil)
    }
}

@Suite("A connection to a provider")
struct AIConnectionTests {
    private let anthropic = LLMProvider.presets[0]

    @Test("It needs a model and a key, except on a local server")
    func usable() {
        var connection = AIConnection(provider: anthropic, apiKey: "")
        #expect(!connection.isUsable)
        connection.provider.model = "m"
        #expect(!connection.isUsable)
        connection.apiKey = "k"
        #expect(connection.isUsable)

        let local = LLMProvider(name: "Ollama", kind: .openAICompatible, baseURL: URL(string: "http://localhost:11434/v1")!, model: "llama3")
        #expect(local.isLocal)
        #expect(AIConnection(provider: local, apiKey: "").isUsable)
        #expect(!anthropic.isLocal)
    }

    @Test("The store keeps what it was given and forgets it on delete")
    func store() throws {
        let store = InMemoryAIConnectionStore()
        #expect(try store.load() == nil)
        let connection = AIConnection(provider: anthropic, apiKey: "k")
        try store.save(connection)
        #expect(try store.load() == connection)
        try store.delete()
        #expect(try store.load() == nil)
    }

    @Test("A connection survives being encoded for the keychain")
    func coding() throws {
        let connection = AIConnection(provider: anthropic, apiKey: "k")
        let decoded = try JSONDecoder().decode(AIConnection.self, from: JSONEncoder().encode(connection))
        #expect(decoded == connection)
    }
}
