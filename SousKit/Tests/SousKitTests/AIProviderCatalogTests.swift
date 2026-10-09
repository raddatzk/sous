import Foundation
import Testing
@testable import SousKit

@Suite("The AI providers of the community")
struct AIProviderCatalogTests {
    private let catalog = AIProviderCatalog.bundled

    @Test("The bundled data set carries the providers, and every one with an api has what a cook needs")
    func bundled() throws {
        #expect(!catalog.providers.isEmpty)
        for entry in catalog.asking {
            let api = try #require(entry.api, "\(entry.id)")
            #expect(api.baseURL.scheme == "https", "\(entry.id)")
            #expect(!api.baseURL.absoluteString.hasSuffix("/"), "\(entry.id)")
            #expect(api.keyPage.scheme == "https")
            #expect(api.docs.scheme == "https")
            #expect(!api.models.isEmpty, "\(entry.id) names no model")
        }
    }

    @Test("The set the process runs on has the same providers as the bundled file")
    func current() {
        #expect(DataSet.current.aiProviders == catalog)
        #expect(!AIProviderCatalog.current.providers.isEmpty)
    }

    @Test("The named providers are the ones the app offered before, now from the data")
    func presets() throws {
        let names = Set(LLMProvider.presets.map(\.name))
        #expect(names.isSuperset(of: ["Anthropic", "OpenAI", "Grok", "Gemini"]))
        let anthropic = try #require(LLMProvider.presets.first { $0.name == "Anthropic" })
        #expect(anthropic.kind == .anthropic)
        #expect(anthropic.baseURL.absoluteString == "https://api.anthropic.com/v1")
        #expect(anthropic.catalogID == "anthropic")
        #expect(anthropic.keyPage?.host == "platform.claude.com")
        let gemini = try #require(LLMProvider.presets.first { $0.name == "Gemini" })
        #expect(gemini.kind == .openAICompatible)
    }

    @Test("A chat id is one the app already stores, so a cook's choice survives the move to data")
    func chatIDs() {
        let stored = ["chatgpt", "claude", "gemini", "grok", "lechat", "copilot"]
        let known = Set(catalog.providers.compactMap(\.chat?.id))
        #expect(known.isSuperset(of: stored))
        #expect(catalog.entry(chatID: "claude")?.id == "anthropic")
        #expect(catalog.entry(chatID: "claude")?.chat?.url.host == "claude.ai")
    }

    @Test("Haiku 5.5 is advised at low effort without thinking, from the data")
    func advice() throws {
        var anthropic = try #require(LLMProvider.presets.first { $0.name == "Anthropic" })
        anthropic.model = "claude-haiku-5-5"
        let tuned = LLMModelAdvice.tuned(anthropic)
        #expect(tuned.effort == "low")
        #expect(tuned.disablesThinking == true)
        // A model the data advises nothing for is asked as it comes.
        anthropic.model = "claude-haiku-4-5-20251001"
        #expect(LLMModelAdvice.tuned(anthropic) == anthropic)
    }

    @Test("A provider the cook entered has no catalog entry, no key page and no advice")
    func custom() {
        let custom = LLMProvider(name: "Ollama", kind: .openAICompatible, baseURL: URL(string: "http://localhost:11434/v1")!, model: "llama3")
        #expect(custom.catalogEntry == nil)
        #expect(custom.keyPage == nil)
        #expect(LLMModelAdvice.suggestions(in: [LLMModel(id: "llama3")], for: custom).isEmpty)
    }

    @Test("A file with moved addresses and a chat-only provider decodes")
    func decoding() throws {
        let json = #"""
        {"providers": [
          {"id": "a", "name": "A", "api": {"format": "openai", "baseURL": "https://api.a.example/v1",
            "keyPage": "https://a.example/keys", "docs": "https://a.example/docs",
            "models": [{"id": "m", "thinking": false}],
            "moved": [{"from": "https://old.a.example/v1", "source": "https://a.example/news", "reason": "Neue Adresse."}]}},
          {"id": "b", "name": "B", "chat": {"id": "b", "title": "B", "url": "https://b.example/"}}
        ]}
        """#
        let decoded = try AIProviderCatalog(json: Data(json.utf8))
        #expect(decoded.asking.map(\.id) == ["a"])
        #expect(decoded.entry(id: "a")?.api?.moved.first?.from.host == "old.a.example")
        #expect(decoded.entry(id: "a")?.api?.models.first?.thinking == false)
        #expect(decoded.entry(id: "b")?.api == nil)
    }
}
