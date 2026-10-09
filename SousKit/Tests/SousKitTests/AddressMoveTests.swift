import Foundation
import Testing
@testable import SousKit

@Suite("A provider's address moves")
struct AddressMoveTests {
    private func catalog(base: String, moved: [(String, String, String)] = []) -> AIProviderCatalog {
        AIProviderCatalog(providers: [
            .init(
                id: "acme", name: "Acme",
                api: .init(
                    format: "openai", baseURL: URL(string: base)!,
                    keyPage: URL(string: "https://acme.example/keys")!, docs: URL(string: "https://acme.example/docs")!,
                    models: [],
                    moved: moved.map {
                        .init(from: URL(string: $0.0)!, source: URL(string: $0.1)!, reason: $0.2)
                    }))
        ])
    }

    private func connection(_ base: String, catalogID: String? = "acme") -> AIConnection {
        AIConnection(
            provider: LLMProvider(
                name: "Acme", kind: .openAICompatible, baseURL: URL(string: base)!, model: "m", catalogID: catalogID),
            apiKey: "k")
    }

    @Test("The saved address is the catalog's: nothing to decide, whatever the case or a trailing slash")
    func same() {
        let catalog = catalog(base: "https://api.acme.example/v1")
        #expect(connection("https://api.acme.example/v1").pendingMove(in: catalog) == nil)
        #expect(connection("https://API.acme.example/v1/").pendingMove(in: catalog) == nil)
    }

    @Test("A different address is a move, with where it was announced where the catalog says")
    func moved() throws {
        let catalog = catalog(
            base: "https://api.new.example/v1",
            moved: [("https://api.old.example/v1", "https://acme.example/news", "Neue Adresse.")])
        let move = try #require(connection("https://api.old.example/v1").pendingMove(in: catalog))
        #expect(move.fromHost == "api.old.example")
        #expect(move.toHost == "api.new.example")
        #expect(move.source?.absoluteString == "https://acme.example/news")
        #expect(move.reason == "Neue Adresse.")
        #expect(move.docs.host == "acme.example")
    }

    @Test("A move nobody announced is still a move, without a source")
    func unannounced() throws {
        let move = try #require(connection("https://api.old.example/v1")
            .pendingMove(in: catalog(base: "https://api.new.example/v1")))
        #expect(move.source == nil)
        #expect(move.reason == nil)
    }

    @Test("Accepting follows the move, keeps the key and notes when")
    func following() throws {
        let catalog = catalog(base: "https://api.new.example/v1")
        let old = connection("https://api.old.example/v1")
        let move = try #require(old.pendingMove(in: catalog))
        let date = Date(timeIntervalSince1970: 1_000_000)
        let followed = old.following(move, at: date)
        #expect(followed.provider.baseURL.host == "api.new.example")
        #expect(followed.apiKey == "k")
        #expect(followed.addressConfirmedAt == date)
        #expect(followed.pendingMove(in: catalog) == nil)
    }

    @Test("A connection saved before ids is found by the address it holds, current or recorded as left")
    func beforeIDs() throws {
        let catalog = catalog(
            base: "https://api.new.example/v1",
            moved: [("https://api.old.example/v1", "https://acme.example/news", "Neue Adresse.")])
        // By a recorded earlier address.
        #expect(connection("https://api.old.example/v1", catalogID: nil).pendingMove(in: catalog) != nil)
        // By the current one: nothing to decide.
        #expect(connection("https://api.new.example/v1", catalogID: nil).pendingMove(in: catalog) == nil)
    }

    @Test("A cook's own server is never taken for a provider, whatever it is called")
    func customServer() {
        let catalog = catalog(base: "https://api.new.example/v1")
        #expect(connection("http://localhost:11434/v1", catalogID: nil).pendingMove(in: catalog) == nil)
        #expect(connection("https://my.server.example/v1", catalogID: nil).pendingMove(in: catalog) == nil)
    }

    @Test("A provider the catalog no longer lists leaves the connection alone")
    func vanished() {
        #expect(connection("https://api.old.example/v1", catalogID: "gone").pendingMove(in: catalog(base: "https://x.example/v1")) == nil)
    }

    @Test("The host a key goes to reads off the connection")
    func host() {
        #expect(connection("https://api.acme.example/v1").host == "api.acme.example")
    }
}
