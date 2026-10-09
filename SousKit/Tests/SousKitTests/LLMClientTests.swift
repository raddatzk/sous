import Foundation
import Testing
@testable import SousKit

/// Answers requests from a closure instead of the network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, data) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Every suite that answers from `StubURLProtocol` runs inside this one, one
/// test at a time: the stub's handler is a single shared closure.
@Suite("Stubbed network", .serialized)
enum StubbedNetwork {}

extension StubbedNetwork {
@Suite("Talking to a chat provider")
struct LLMClientTests {
    private let anthropic = LLMProvider(
        name: "Anthropic", kind: .anthropic, baseURL: URL(string: "https://api.anthropic.com/v1")!, model: "m")
    private let openAI = LLMProvider(
        name: "OpenAI", kind: .openAICompatible, baseURL: URL(string: "https://api.openai.com/v1")!, model: "m")

    private func client(_ provider: LLMProvider, key: String = "k") -> LLMClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return LLMClient(provider: provider, apiKey: key, session: URLSession(configuration: configuration))
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        })
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Anthropic: key and version in headers, system as its own field")
    func anthropicRequest() async throws {
        nonisolated(unsafe) var seen: URLRequest?
        StubURLProtocol.handler = { request in
            seen = request
            return (200, Data(#"{"content":[{"type":"text","text":"Hallo "},{"type":"text","text":"Welt"}]}"#.utf8))
        }
        let text = try await client(anthropic, key: "sk-ant").reply(to: [LLMMessage(.user, "Hi")], system: "Sei kurz.")
        #expect(text == "Hallo Welt")

        let request = try #require(seen)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let json = try body(request)
        #expect(json["system"] as? String == "Sei kurz.")
        #expect(json["max_tokens"] as? Int == 16384)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "Hi"]])
    }

    @Test("Anthropic: effort and switched-off thinking go into the request, and only there")
    func effort() async throws {
        nonisolated(unsafe) var bodies: [[String: Any]] = []
        StubURLProtocol.handler = { request in
            bodies.append((try? self.body(request)) ?? [:])
            return (200, Data(#"{"content":[{"type":"text","text":"ok"}]}"#.utf8))
        }
        var quick = anthropic
        quick.effort = "low"
        quick.disablesThinking = true
        _ = try await client(quick).reply(to: [LLMMessage(.user, "Hi")])
        _ = try await client(anthropic).reply(to: [LLMMessage(.user, "Hi")])

        #expect((bodies[0]["output_config"] as? [String: String]) == ["effort": "low"])
        #expect((bodies[0]["thinking"] as? [String: String]) == ["type": "disabled"])
        #expect(bodies[1]["output_config"] == nil)
        #expect(bodies[1]["thinking"] == nil)

        var other = openAI
        other.effort = "low"
        StubURLProtocol.handler = { request in
            bodies.append((try? self.body(request)) ?? [:])
            return (200, Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8))
        }
        _ = try await client(other).reply(to: [LLMMessage(.user, "Hi")])
        #expect(bodies[2]["output_config"] == nil)
    }

    @Test("A fixed start of the message is marked for the cache at Anthropic and plain text elsewhere")
    func cachedPrefix() async throws {
        nonisolated(unsafe) var bodies: [[String: Any]] = []
        StubURLProtocol.handler = { request in
            bodies.append((try? self.body(request)) ?? [:])
            return (200, Data(#"""
                {"content":[{"type":"text","text":"ok"}],
                 "choices":[{"message":{"content":"ok"}}],
                 "usage":{"input_tokens":12,"output_tokens":3,"cache_read_input_tokens":9000,"cache_creation_input_tokens":0,
                          "prompt_tokens":9012,"completion_tokens":3,"prompt_tokens_details":{"cached_tokens":8960}}}
                """#.utf8))
        }
        let message = LLMMessage(.user, "Rezept", cachedPrefix: "Regeln und Katalog\n\n")

        let reply = try await client(anthropic).complete([message])
        let content = try #require((bodies[0]["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        #expect(content.count == 2)
        #expect(content[0]["text"] as? String == "Regeln und Katalog\n\n")
        #expect((content[0]["cache_control"] as? [String: String]) == ["type": "ephemeral"])
        #expect(content[1]["text"] as? String == "Rezept")
        #expect(content[1]["cache_control"] == nil)
        #expect(reply.cachedInputTokens == 9000)
        #expect(reply.cacheWriteTokens == 0)

        let other = try await client(openAI).complete([message])
        let plain = try #require((bodies[1]["messages"] as? [[String: Any]])?.last?["content"] as? String)
        #expect(plain == "Regeln und Katalog\n\nRezept")
        #expect(other.cachedInputTokens == 8960)

        // No prefix: the old shape, a plain string.
        _ = try await client(anthropic).complete([LLMMessage(.user, "Hi")])
        #expect((bodies[2]["messages"] as? [[String: Any]])?.first?["content"] as? String == "Hi")
    }

    @Test("OpenAI format: bearer header, system as the first message")
    func openAIRequest() async throws {
        nonisolated(unsafe) var seen: URLRequest?
        StubURLProtocol.handler = { request in
            seen = request
            return (200, Data(#"{"choices":[{"message":{"content":"Servus"}}]}"#.utf8))
        }
        let text = try await client(openAI, key: "sk-oa").reply(to: [LLMMessage(.user, "Hi")], system: "Sei kurz.")
        #expect(text == "Servus")

        let request = try #require(seen)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-oa")
        let messages = try #require(try body(request)["messages"] as? [[String: String]])
        #expect(messages.first == ["role": "system", "content": "Sei kurz."])
        #expect(messages.last == ["role": "user", "content": "Hi"])
    }

    @Test("A local server without a key gets no Authorization header")
    func noKey() async throws {
        nonisolated(unsafe) var seen: URLRequest?
        StubURLProtocol.handler = { request in
            seen = request
            return (200, Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8))
        }
        _ = try await client(openAI, key: "").reply(to: [LLMMessage(.user, "Hi")])
        #expect(seen?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("A busy provider is asked again after a pause, and a used-up limit is not")
    func retries() async throws {
        nonisolated(unsafe) var count = 0
        StubURLProtocol.handler = { _ in
            count += 1
            return count < 3
                ? (503, Data(#"{"error":{"message":"overloaded"}}"#.utf8))
                : (200, Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let patient = LLMClient(
            provider: openAI, apiKey: "k", session: URLSession(configuration: configuration),
            retryDelays: [.milliseconds(1), .milliseconds(1)])
        #expect(try await patient.reply(to: [LLMMessage(.user, "Hi")]) == "ok")
        #expect(count == 3)

        // Out of retries: the last busy answer is the error.
        count = -10
        await #expect(throws: LLMError.server(status: 503, message: "overloaded")) {
            try await patient.reply(to: [LLMMessage(.user, "Hi")])
        }

        // 429 without Retry-After is no reason to wait.
        count = 0
        StubURLProtocol.handler = { _ in count += 1; return (429, Data(#"{"error":{"message":"no credits"}}"#.utf8)) }
        await #expect(throws: LLMError.rateLimited("no credits")) {
            try await patient.reply(to: [LLMMessage(.user, "Hi")])
        }
        #expect(count == 1)
    }

    @Test("Refused keys, limits and other failures are told apart")
    func errors() async throws {
        let message = Data(#"{"error":{"message":"nope"}}"#.utf8)
        for (status, expected) in [
            (401, LLMError.unauthorized("nope")),
            (403, .unauthorized("nope")),
            (429, .rateLimited("nope")),
            (500, .server(status: 500, message: "nope")),
        ] {
            StubURLProtocol.handler = { _ in (status, message) }
            await #expect(throws: expected) {
                try await client(anthropic).reply(to: [LLMMessage(.user, "Hi")])
            }
        }
    }

    @Test("An answer that stopped at the token limit says so")
    func cutOff() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"content":[{"type":"text","text":"{\"title\": "}],"stop_reason":"max_tokens","usage":{"input_tokens":5,"output_tokens":9}}"#.utf8))
        }
        let reply = try await client(anthropic).complete([LLMMessage(.user, "Hi")])
        #expect(reply.wasCutOff)
        #expect(reply.outputTokens == 9)

        StubURLProtocol.handler = { _ in
            (200, Data(#"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"#.utf8))
        }
        #expect(try await client(openAI).complete([LLMMessage(.user, "Hi")]).wasCutOff == false)
    }

    @Test("An answer without text is an error, not an empty string")
    func emptyAnswer() async {
        StubURLProtocol.handler = { _ in (200, Data(#"{"content":[]}"#.utf8)) }
        await #expect(throws: LLMError.emptyAnswer) {
            try await client(anthropic).reply(to: [LLMMessage(.user, "Hi")])
        }
        StubURLProtocol.handler = { _ in (200, Data("not json".utf8)) }
        await #expect(throws: LLMError.malformedAnswer) {
            try await client(openAI).reply(to: [LLMMessage(.user, "Hi")])
        }
    }

    @Test("Stream lines yield only text deltas")
    func streamLines() {
        let a = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hal"}}"#
        #expect(LLMClient.piece(inStreamLine: a, kind: .anthropic) == "Hal")
        #expect(LLMClient.piece(inStreamLine: "event: content_block_delta", kind: .anthropic) == nil)
        #expect(LLMClient.piece(inStreamLine: #"data: {"type":"message_stop"}"#, kind: .anthropic) == nil)

        let o = #"data: {"choices":[{"delta":{"content":"lo"}}]}"#
        #expect(LLMClient.piece(inStreamLine: o, kind: .openAICompatible) == "lo")
        #expect(LLMClient.piece(inStreamLine: "data: [DONE]", kind: .openAICompatible) == nil)
        #expect(LLMClient.piece(inStreamLine: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#, kind: .openAICompatible) == nil)
    }

    @Test("Streaming delivers the pieces in order")
    func streaming() async throws {
        let sse = """
            data: {"choices":[{"delta":{"content":"Ein "}}]}

            data: {"choices":[{"delta":{"content":"Rezept"}}]}

            data: [DONE]

            """
        StubURLProtocol.handler = { _ in (200, Data(sse.utf8)) }
        var pieces: [String] = []
        for try await piece in client(openAI).stream([LLMMessage(.user, "Hi")]) { pieces.append(piece) }
        #expect(pieces == ["Ein ", "Rezept"])
    }

    @Test("A failing stream throws the classified error")
    func streamingFailure() async {
        StubURLProtocol.handler = { _ in (429, Data(#"{"error":{"message":"slow down"}}"#.utf8)) }
        await #expect(throws: LLMError.rateLimited("slow down")) {
            for try await _ in client(anthropic).stream([LLMMessage(.user, "Hi")]) {}
        }
    }

    @Test("Anthropic's model list keeps its order and display names, and asks for all of it")
    func anthropicModels() async throws {
        nonisolated(unsafe) var seen: URLRequest?
        StubURLProtocol.handler = { request in
            seen = request
            return (200, Data(#"""
                {"data":[{"id":"claude-b","display_name":"Claude B","type":"model"},
                         {"id":"claude-a","display_name":"Claude A","type":"model"}],"has_more":false}
                """#.utf8))
        }
        let models = try await client(anthropic, key: "sk-ant").models()
        #expect(models == [LLMModel(id: "claude-b", name: "Claude B"), LLMModel(id: "claude-a", name: "Claude A")])
        let request = try #require(seen)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1000")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    }

    @Test("The OpenAI format's list is sorted, and Gemini's models/ prefix is dropped")
    func openAIModels() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"data":[{"id":"models/gemini-b"},{"id":"models/gemini-a"},{"id":""}]}"#.utf8))
        }
        let models = try await client(openAI).models()
        #expect(models.map(\.id) == ["gemini-a", "gemini-b"])
    }

    @Test("A refused key fails the model list the same way")
    func modelsRefused() async {
        StubURLProtocol.handler = { _ in (401, Data(#"{"error":{"message":"bad key"}}"#.utf8)) }
        await #expect(throws: LLMError.unauthorized("bad key")) { try await client(openAI).models() }
    }
}
}
