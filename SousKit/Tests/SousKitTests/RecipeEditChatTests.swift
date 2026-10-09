import Foundation
import Testing
@testable import SousKit

extension StubbedNetwork {
@MainActor
@Suite("Talking to a chat model about a recipe")
struct RecipeEditChatTests {
    private let provider = LLMProvider(
        name: "T", kind: .openAICompatible, baseURL: URL(string: "https://t.example/v1")!, model: "m")

    private func chat() -> RecipeEditChat {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return RecipeEditChat(client: LLMClient(
            provider: provider, apiKey: "k", session: URLSession(configuration: configuration), retryDelays: []))
    }

    private func sse(_ pieces: [String], finish: String? = nil) -> Data {
        var text = ""
        for piece in pieces {
            let json = String(data: try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": piece]]]]), encoding: .utf8)!
            text += "data: \(json)\n\n"
        }
        if let finish {
            text += "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"\(finish)\"}]}\n\n"
        }
        return Data((text + "data: [DONE]\n\n").utf8)
    }

    private let block = """
        ```json
        {"title": "Vegane Suppe", "ingredients": ["250 g rote Linsen"], "steps": ["Kochen."]}
        ```
        """

    private func waitUntilDone(_ chat: RecipeEditChat) async {
        while chat.isAnswering { await Task.yield() }
    }

    private func userMessages(_ request: URLRequest) -> [String] {
        let data = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        }
        guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let messages = json["messages"] as? [[String: String]]
        else { return [] }
        return messages.compactMap { $0["role"] == "user" ? $0["content"] : nil }
    }

    @Test("The answer streams in and its JSON block becomes the proposal")
    func proposal() async {
        StubURLProtocol.handler = { _ in (200, self.sse(["Hier die Suppe.\n\n", self.block])) }
        let chat = chat()
        chat.start(prompt: "PROMPT mit Katalog", shown: "Vegan machen")
        await waitUntilDone(chat)

        #expect(chat.turns.map(\.kind) == [.cook, .model])
        #expect(chat.turns[0].text == "Vegan machen")
        #expect(chat.proposal?.title == "Vegane Suppe")
        #expect(chat.failure == nil)
    }

    @Test("A first answer without the block is asked for it once")
    func asksOnceForTheBlock() async {
        nonisolated(unsafe) var requests: [URLRequest] = []
        StubURLProtocol.handler = { request in
            requests.append(request)
            return (200, requests.count == 1 ? self.sse(["Nur Text, kein Rezeptstand."]) : self.sse([self.block]))
        }
        let chat = chat()
        chat.start(prompt: "PROMPT", shown: "Vegan")
        await waitUntilDone(chat)

        #expect(chat.proposal?.title == "Vegane Suppe")
        #expect(requests.count == 2)
        #expect(userMessages(requests[1]) == ["PROMPT", RecipeEditChat.askForTheBlock])
        #expect(chat.turns.map(\.kind) == [.cook, .model, .note, .model])
    }

    @Test("A model that never gives the block is asked only the once")
    func doesNotAskTwice() async {
        nonisolated(unsafe) var count = 0
        StubURLProtocol.handler = { _ in count += 1; return (200, self.sse(["Kein Block."])) }
        let chat = chat()
        chat.start(prompt: "PROMPT", shown: "Vegan")
        await waitUntilDone(chat)

        #expect(count == 2)
        #expect(chat.proposal == nil)
    }

    @Test("A follow-up that is only talk leaves the proposal standing")
    func talkKeepsTheProposal() async {
        nonisolated(unsafe) var count = 0
        StubURLProtocol.handler = { _ in
            count += 1
            return (200, count == 1 ? self.sse([self.block]) : self.sse(["Das dauert etwa 20 Minuten."]))
        }
        let chat = chat()
        chat.start(prompt: "PROMPT", shown: "Vegan")
        await waitUntilDone(chat)
        chat.send("Wie lange dauert das?")
        await waitUntilDone(chat)

        #expect(count == 2)
        #expect(chat.proposal?.title == "Vegane Suppe")
        #expect(chat.turns.count == 4)
    }

    @Test("An answer cut off at the limit keeps its text and says so")
    func cutOff() async {
        StubURLProtocol.handler = { _ in (200, self.sse(["Hier die Suppe, die lei"], finish: "length")) }
        let chat = chat()
        chat.start(prompt: "PROMPT", shown: "Vegan")
        await waitUntilDone(chat)

        #expect(chat.turns.last?.text == "Hier die Suppe, die lei")
        #expect(chat.failure == LLMError.cutOff.errorDescription)
        #expect(chat.proposal == nil)
    }

    @Test("The transcript hides the JSON block")
    func visible() {
        let shown = RecipeEditChat.visible("Hier das Rezept.\n\n" + block)
        #expect(shown.text == "Hier das Rezept.")
        #expect(shown.showsRecipe)
        #expect(!RecipeEditChat.visible("Nur Text.").showsRecipe)
    }
}
}
