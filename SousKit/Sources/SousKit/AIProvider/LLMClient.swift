import Foundation

/// Talks to one provider with one key: a conversation in, the model's text out.
///
/// It knows the two wire formats and nothing else. What the text means is
/// the business of the readers that check an answer before Sous uses it.
public struct LLMClient: Sendable {
    public let provider: LLMProvider
    private let apiKey: String
    private let session: URLSession
    /// The waits before each new attempt after a busy answer; as many
    /// entries as retries.
    private let retryDelays: [Duration]

    /// Anthropic requires an answer limit. Newer models think before they
    /// answer and the thinking counts against it, so it is well above what a
    /// recipe takes: Haiku 5.5 ran into 8192 and cut its JSON off.
    static let anthropicMaxTokens = 16384
    static let anthropicVersion = "2023-06-01"

    public init(
        provider: LLMProvider, apiKey: String, session: URLSession = .shared,
        retryDelays: [Duration] = [.seconds(1), .seconds(3)]
    ) {
        self.provider = provider
        self.apiKey = apiKey
        self.session = session
        self.retryDelays = retryDelays
    }

    /// Sends a request, and again after a pause where the provider is only
    /// busy (502, 503, 504, 529) or asks to wait (429 with a `Retry-After`).
    /// A 429 without one is a used-up limit, which waiting does not cure.
    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            let (data, response) = try await session.data(for: request)
            guard let wait = Self.pause(after: response, attempt: attempt, delays: retryDelays) else {
                return (data, response)
            }
            try await Task.sleep(for: wait)
            attempt += 1
        }
    }

    static func pause(after response: URLResponse, attempt: Int, delays: [Duration]) -> Duration? {
        guard attempt < delays.count, let http = response as? HTTPURLResponse else { return nil }
        switch http.statusCode {
        case 502, 503, 504, 529:
            return delays[attempt]
        case 429:
            guard let header = http.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(header),
                seconds <= 20
            else { return nil }
            return .seconds(seconds)
        default:
            return nil
        }
    }

    /// The whole answer to `messages`, once the model is done.
    public func reply(to messages: [LLMMessage], system: String? = nil) async throws -> String {
        try await complete(messages, system: system).text
    }

    /// The whole answer with what it cost in tokens, where the provider says.
    public func complete(_ messages: [LLMMessage], system: String? = nil) async throws -> LLMReply {
        let request = try makeRequest(messages, system: system, stream: false)
        let (data, response) = try await perform(request)
        try Self.check(response, body: data)
        let text = try Self.text(in: data, kind: provider.kind)
        guard !text.isEmpty else { throw LLMError.emptyAnswer }
        let usage = Self.usage(in: data, kind: provider.kind)
        return LLMReply(
            text: text, inputTokens: usage.input, outputTokens: usage.output,
            wasCutOff: Self.wasCutOff(data, kind: provider.kind),
            cachedInputTokens: usage.cacheRead, cacheWriteTokens: usage.cacheWrite)
    }

    /// The answer as it is written, piece by piece.
    public func stream(_ messages: [LLMMessage], system: String? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(messages, system: system, stream: true)
                    var attempt = 0
                    var (bytes, response) = try await session.bytes(for: request)
                    while let wait = Self.pause(after: response, attempt: attempt, delays: retryDelays) {
                        try await Task.sleep(for: wait)
                        attempt += 1
                        (bytes, response) = try await session.bytes(for: request)
                    }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        try Self.check(response, body: body)
                    }
                    var wasCutOff = false
                    for try await line in bytes.lines {
                        if let piece = Self.piece(inStreamLine: line, kind: provider.kind) {
                            continuation.yield(piece)
                        }
                        if Self.stopReasonIsLimit(inStreamLine: line, kind: provider.kind) { wasCutOff = true }
                    }
                    // The pieces already delivered stay; the end says the answer is not whole.
                    if wasCutOff { throw LLMError.cutOff }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The models this key may use, as the provider lists them.
    ///
    /// Anthropic lists newest first and Sous keeps that order. The others
    /// list in no order and mix in models that do not chat (embeddings,
    /// speech); those are sorted by id and left for the cook to pick from.
    public func models() async throws -> [LLMModel] {
        var request = URLRequest(url: modelsURL())
        authorize(&request)
        let (data, response) = try await perform(request)
        try Self.check(response, body: data)
        return try Self.models(in: data, kind: provider.kind)
    }

    private func modelsURL() -> URL {
        let url = provider.baseURL.appending(path: "models")
        guard provider.kind == .anthropic else { return url }
        // The default page holds 20; the list is short, ask for all of it.
        return url.appending(queryItems: [URLQueryItem(name: "limit", value: "1000")])
    }

    private func authorize(_ request: inout URLRequest) {
        switch provider.kind {
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        case .openAICompatible:
            // Local servers run without a key; sending an empty bearer would be refused by some.
            if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        }
    }

    static func models(in data: Data, kind: LLMProviderKind) throws -> [LLMModel] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = object["data"] as? [[String: Any]]
        else { throw LLMError.malformedAnswer }
        let models = entries.compactMap { entry -> LLMModel? in
            guard var id = entry["id"] as? String, !id.isEmpty else { return nil }
            // Gemini's compatibility endpoint names models "models/gemini-…", but
            // wants the bare name back.
            if id.hasPrefix("models/") { id.removeFirst("models/".count) }
            return LLMModel(id: id, name: entry["display_name"] as? String)
        }
        return kind == .anthropic ? models : models.sorted { $0.id < $1.id }
    }

    // MARK: Requests

    func makeRequest(_ messages: [LLMMessage], system: String?, stream: Bool) throws -> URLRequest {
        var request: URLRequest
        var body: [String: Any]
        let turns: [[String: Any]] = messages.map { message in
            // Anthropic keeps a marked block for a few minutes and bills a hit at a tenth.
            if provider.kind == .anthropic, let prefix = message.cachedPrefix, !prefix.isEmpty {
                return [
                    "role": message.role.rawValue,
                    "content": [
                        ["type": "text", "text": prefix, "cache_control": ["type": "ephemeral"]],
                        ["type": "text", "text": message.text],
                    ] as [[String: Any]],
                ]
            }
            return ["role": message.role.rawValue, "content": (message.cachedPrefix ?? "") + message.text]
        }

        switch provider.kind {
        case .anthropic:
            request = URLRequest(url: provider.baseURL.appending(path: "messages"))
            body = ["model": provider.model, "max_tokens": Self.anthropicMaxTokens, "messages": turns]
            if let system, !system.isEmpty { body["system"] = system }
            if let effort = provider.effort { body["output_config"] = ["effort": effort] }
            if provider.disablesThinking == true { body["thinking"] = ["type": "disabled"] }
        case .openAICompatible:
            request = URLRequest(url: provider.baseURL.appending(path: "chat/completions"))
            var all: [[String: Any]] = []
            if let system, !system.isEmpty { all.append(["role": "system", "content": system]) }
            body = ["model": provider.model, "messages": all + turns]
        }
        authorize(&request)
        if stream { body["stream"] = true }

        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    // MARK: Answers

    static func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let message = errorMessage(in: body)
        switch http.statusCode {
        case 401, 403: throw LLMError.unauthorized(message)
        case 429: throw LLMError.rateLimited(message)
        default: throw LLMError.server(status: http.statusCode, message: message)
        }
    }

    /// Both formats put it at `error.message`.
    static func errorMessage(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let error = object["error"] as? [String: Any]
        else { return nil }
        return error["message"] as? String
    }

    /// Whether the model stopped at its token limit instead of finishing.
    static func wasCutOff(_ data: Data, kind: LLMProviderKind) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        switch kind {
        case .anthropic:
            return object["stop_reason"] as? String == "max_tokens"
        case .openAICompatible:
            let choices = object["choices"] as? [[String: Any]]
            return choices?.first?["finish_reason"] as? String == "length"
        }
    }

    static func usage(in data: Data, kind: LLMProviderKind)
        -> (input: Int?, output: Int?, cacheRead: Int?, cacheWrite: Int?)
    {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let usage = object["usage"] as? [String: Any]
        else { return (nil, nil, nil, nil) }
        switch kind {
        case .anthropic:
            // Anthropic's `input_tokens` leaves out what came from or went to the cache.
            return (
                usage["input_tokens"] as? Int, usage["output_tokens"] as? Int,
                usage["cache_read_input_tokens"] as? Int, usage["cache_creation_input_tokens"] as? Int)
        case .openAICompatible:
            let details = usage["prompt_tokens_details"] as? [String: Any]
            return (
                usage["prompt_tokens"] as? Int, usage["completion_tokens"] as? Int,
                details?["cached_tokens"] as? Int, nil)
        }
    }

    static func text(in data: Data, kind: LLMProviderKind) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.malformedAnswer
        }
        switch kind {
        case .anthropic:
            guard let blocks = object["content"] as? [[String: Any]] else { throw LLMError.malformedAnswer }
            return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        case .openAICompatible:
            guard let choices = object["choices"] as? [[String: Any]],
                let message = choices.first?["message"] as? [String: Any]
            else { throw LLMError.malformedAnswer }
            return message["content"] as? String ?? ""
        }
    }

    /// Whether a stream line reports that the model stopped at its token limit.
    static func stopReasonIsLimit(inStreamLine line: String, kind: LLMProviderKind) -> Bool {
        guard line.hasPrefix("data:"),
            let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        switch kind {
        case .anthropic:
            return (object["delta"] as? [String: Any])?["stop_reason"] as? String == "max_tokens"
        case .openAICompatible:
            let choices = object["choices"] as? [[String: Any]]
            return choices?.first?["finish_reason"] as? String == "length"
        }
    }

    /// The text carried by one line of a server-sent-event stream, if any.
    /// `event:` lines, keep-alives and the end marker carry none.
    static func piece(inStreamLine line: String, kind: LLMProviderKind) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let data = payload.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        switch kind {
        case .anthropic:
            guard object["type"] as? String == "content_block_delta",
                let delta = object["delta"] as? [String: Any],
                delta["type"] as? String == "text_delta"
            else { return nil }
            return delta["text"] as? String
        case .openAICompatible:
            guard let choices = object["choices"] as? [[String: Any]],
                let delta = choices.first?["delta"] as? [String: Any]
            else { return nil }
            return delta["content"] as? String
        }
    }
}

/// An API answers the optimization prompt as a single request.
extension LLMClient: RecipeOptimizationBackend {
    public func answer(to prompt: String) async throws -> String {
        try await answer(cachedPrefix: "", then: prompt)
    }

    public func answer(cachedPrefix: String, then rest: String) async throws -> String {
        let reply = try await complete([LLMMessage(.user, rest, cachedPrefix: cachedPrefix)])
        // A cut-off answer is never a valid one; say why instead of failing to read it.
        if reply.wasCutOff { throw LLMError.cutOff }
        return reply.text
    }
}
