import Foundation

// Raw-HTTP clients. Swift has no official SDK for these providers, so each
// client speaks the provider's REST API directly via URLSession.

private func postJSON(url: URL, headers: [String: String], body: [String: Any]) async throws -> Data {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    request.timeoutInterval = 120

    let (data, response) = try await URLSession.shared.data(for: request)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw LLMError.httpError(
            status: http.statusCode,
            body: String(decoding: data, as: UTF8.self))
    }
    return data
}

private func parse(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

// MARK: - Gemini

/// Google Gemini via the generateContent REST endpoint (v1beta).
public struct GeminiClient: LLMClient {
    public let kind: ProviderKind = .gemini
    let apiKey: String
    let model: String

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    public func complete(_ request: LLMRequest) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey(.gemini) }
        let url = URL(
            string:
                "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!

        var body: [String: Any] = [
            "contents": request.messages.map { message in
                [
                    "role": message.role == .user ? "user" : "model",
                    "parts": [["text": message.text]],
                ]
            },
            "generationConfig": {
                var config: [String: Any] = ["maxOutputTokens": request.maxTokens]
                if request.jsonMode { config["responseMimeType"] = "application/json" }
                return config
            }(),
        ]
        if let system = request.system {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }

        let data = try await postJSON(url: url, headers: ["x-goog-api-key": apiKey], body: body)
        let json = parse(data)
        guard let candidates = json["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else { throw LLMError.emptyResponse }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw LLMError.emptyResponse }
        return text
    }
}

// MARK: - OpenAI

/// OpenAI via the chat completions REST endpoint.
public struct OpenAIClient: LLMClient {
    public let kind: ProviderKind = .openai
    let apiKey: String
    let model: String

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    public func complete(_ request: LLMRequest) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey(.openai) }
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!

        var messages: [[String: Any]] = []
        if let system = request.system {
            messages.append(["role": "system", "content": system])
        }
        messages += request.messages.map { ["role": $0.role.rawValue, "content": $0.text] }

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_completion_tokens": request.maxTokens,
        ]
        if request.jsonMode {
            body["response_format"] = ["type": "json_object"]
        }

        let data = try await postJSON(
            url: url, headers: ["Authorization": "Bearer \(apiKey)"], body: body)
        let json = parse(data)
        guard let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let text = message["content"] as? String, !text.isEmpty
        else { throw LLMError.emptyResponse }
        return text
    }
}

// MARK: - Anthropic

/// Anthropic via the Messages API (POST /v1/messages).
public struct AnthropicClient: LLMClient {
    public let kind: ProviderKind = .anthropic
    let apiKey: String
    let model: String

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    public func complete(_ request: LLMRequest) async throws -> String {
        guard !apiKey.isEmpty else { throw LLMError.missingAPIKey(.anthropic) }
        let url = URL(string: "https://api.anthropic.com/v1/messages")!

        var body: [String: Any] = [
            "model": model,
            "max_tokens": request.maxTokens,
            "messages": request.messages.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        if let system = request.system {
            body["system"] = system
        }

        let data = try await postJSON(
            url: url,
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
            ], body: body)
        let json = parse(data)
        // Safety classifiers can decline with HTTP 200 + stop_reason "refusal";
        // check before reading content.
        if json["stop_reason"] as? String == "refusal" {
            throw LLMError.refusal
        }
        guard let blocks = json["content"] as? [[String: Any]] else {
            throw LLMError.emptyResponse
        }
        let text =
            blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw LLMError.emptyResponse }
        return text
    }
}
